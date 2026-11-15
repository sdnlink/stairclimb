"""Actual production Rust/PG/TLS/SMTP lifecycle; each test owns its schema and ports."""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import tempfile
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo

from backend.tests.pg_fixture import Database, ROOT
from scripts.local_service import LocalService, ServiceError, identity, save


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.database = Database()
        self.addCleanup(self.database.close)
        temporary = tempfile.TemporaryDirectory(prefix='delivery-test-', dir=ROOT / '.runtime')
        self.addCleanup(temporary.cleanup)
        self.service = LocalService(Path(temporary.name))
        self.addCleanup(self.stop)

    def stop(self):
        if self.service.state_file.exists():
            self.service.stop()

    def start(self, port=0):
        return self.service.start(port, database_url=self.database.url)

    def request(self, method, path, body=None, token=None, expected=200):
        return self.service.request(self.service.status(), method, path, body, token, expected)

    def account(self):
        email, password = 'persistence@example.test', 'private lifecycle password'
        self.request('POST', '/v1/auth/register', {'email': email, 'password': password, 'nickname': '持久身份'}, expected=202)
        self.request('POST', '/v1/auth/verify', {'token': self.service.mail_token(email), 'password': password})
        return self.request('POST', '/v1/auth/login', {'email': email, 'password': password})

    def test_production_https_captured_mail_probe_cleanup_and_private_artifacts(self):
        with patch.dict(os.environ, {'SMTP_MODE': 'starttls', 'SMTP_HOST': 'must-not-connect.example',
                                     'SMTP_PASSWORD': 'inherited secret', 'STAIRCLIMB_TEST_CLOCK': 'must-not-use'}):
            state = self.start()
        result = self.service.check()
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['accounts_deleted'], 2)
        self.assertEqual(result['leaderboard_traversed'], 2)
        self.assertEqual(result['leaderboard']['items'][0]['steps'], 999)
        self.assertEqual(result['leaderboard']['items'][0]['floor'], 9)
        self.assertEqual(result['me']['entry']['steps'], 101)
        self.assertFalse(result['circles']['participating'])
        self.assertEqual(result['health']['date'], datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat())
        self.assertEqual(state['migrations'], [1, 2, 3])
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 0)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM email_accounts').fetchone()[0], 0)
        executable = Path(f'/proc/{state["processes"]["rust"]["pid"]}/exe')
        self.assertEqual(executable.resolve().name, 'stairclimb-server')
        self.assertEqual(hashlib.sha256(executable.read_bytes()).hexdigest(), state['binary_sha256'])
        self.assertNotIn('--clock-file', state['processes']['rust']['argv'])
        messages = list((self.service.directory / 'mail').glob('*.eml'))
        self.assertEqual(len(messages), 2)
        for path in [self.service.state_file, self.service.directory / 'probe.json', *messages,
                     self.service.directory / 'server.log', self.service.directory / 'smtp.log']:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        public = json.dumps(result) + self.service.state_file.read_text() + (self.service.directory / 'server.log').read_text()
        for forbidden in ['@example.test', 'inherited secret', self.database.url, 'refresh_token', 'password_hash']:
            self.assertNotIn(forbidden, public)

    def test_occupied_port_is_preserved_and_restart_keeps_session_and_snapshot(self):
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0))
            occupied.listen()
            preferred = occupied.getsockname()[1]
            state = self.start(preferred)
            self.assertNotEqual(state['port'], preferred)
            session = self.account()
            token = session['token']
            user = self.request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)['user']
            self.request('PUT', '/v1/me/steps', {'date': state['health']['date'], 'steps': 101,
                                              'expected_revision': user['consent_revision']}, token)
            previous_pid = state['processes']['rust']['pid']
            self.service.stop()
            self.assertIsNone(identity(previous_pid))
            restarted = self.start(preferred)
            self.assertNotEqual(restarted['port'], preferred)
            self.assertNotEqual(restarted['processes']['rust']['pid'], previous_pid)
            self.assertEqual(self.request('GET', '/v1/me', token=token)['user']['id'], user['id'])
            self.assertEqual(self.request('GET', '/v1/me/steps', token=token)['progress']['steps'], 101)
            with socket.create_connection(('127.0.0.1', preferred), timeout=1):
                pass  # The unrelated listener still owns its socket.

    def test_changed_process_identity_refuses_to_signal_either_child(self):
        state = self.start()
        tampered = json.loads(json.dumps(state))
        tampered['processes']['rust']['start_ticks'] = '0'
        save(self.service.state_file, tampered)
        try:
            with self.assertRaisesRegex(ServiceError, 'ownership changed'):
                self.service.stop()
            with self.assertRaises(ServiceError):
                self.start()
            for record in state['processes'].values():
                self.assertEqual(identity(record['pid']), record)
        finally:
            save(self.service.state_file, state)

    def test_failed_readiness_stops_only_spawned_children_and_keeps_database(self):
        with patch.object(self.service, 'request', side_effect=ServiceError('intentional readiness failure')):
            with self.assertRaisesRegex(ServiceError, 'intentional readiness failure'):
                self.start()
        state = self.service.read()
        self.assertEqual(state['state'], 'stopped')
        for record in state['processes'].values():
            self.assertIsNone(identity(record['pid']))
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM schema_migrations').fetchone()[0], 3)

    def test_failed_probe_keeps_failure_receipt_and_deletes_its_accounts(self):
        self.start()
        request = self.service.request
        def fail_leaderboard(state, method, path, *args, **kwargs):
            if path.startswith('/v1/leaderboard'):
                raise ServiceError('intentional probe failure')
            return request(state, method, path, *args, **kwargs)
        with patch.object(self.service, 'request', side_effect=fail_leaderboard):
            with self.assertRaisesRegex(ServiceError, 'intentional probe failure'):
                self.service.check()
        receipt = json.loads((self.service.directory / 'probe.json').read_text())
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['accounts_deleted'], 2)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 0)
        self.assertEqual(self.request('GET', '/health')['status'], 'ok')

    def test_unavailable_safe_stop_fails_before_spawning_or_writing_state(self):
        with patch('scripts.local_service.open_pidfd', side_effect=OSError('unsupported kernel')), patch.object(self.service, 'spawn') as spawn:
            with self.assertRaises(OSError):
                self.start()
            spawn.assert_not_called()
        self.assertFalse(self.service.state_file.exists())


if __name__ == '__main__':
    unittest.main()
