"""Circle delivery probe against production Rust, real PG, TLS and captured mail."""
import json
import stat
import unittest
from unittest.mock import patch

from backend.tests import test_delivery as delivery
from scripts.local_service import ServiceError


class CircleDeliveryTests(unittest.TestCase):
    setUp = delivery.DeliveryTests.setUp
    stop = delivery.DeliveryTests.stop
    start = delivery.DeliveryTests.start
    request = delivery.DeliveryTests.request
    account = delivery.DeliveryTests.account

    def test_active_circle_probe_preserves_other_users_and_removes_only_probe_accounts(self):
        self.start()
        control = self.account()
        token = control['token']
        date = self.request('GET', '/health')['date']
        self.request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)
        self.request('PUT', '/v1/me/circle-participation', {'enabled': True, 'expected_revision': 1}, token)
        self.request('PUT', '/v1/me/steps', {'date': date, 'steps': 750, 'expected_revision': 2}, token)
        before = self.request('GET', '/v1/me', token=token)
        progress = self.request('GET', '/v1/me/steps', token=token)['progress']
        result = self.service.check_circles()
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['accounts_deleted'], 3)
        self.assertEqual(result['circle_members_traversed'], 4)
        self.assertEqual(result['circles']['circle']['id'], date + ':0-999')
        self.assertEqual(result['me']['entry']['position'], 4)
        self.assertEqual(result['me']['entry']['steps'], 101)
        self.assertEqual(result['migrated']['circle']['id'], date + ':1000-1999')
        self.assertEqual(result['migrated']['items'][0]['steps'], 1000)
        self.assertEqual(result['remaining']['total'], 2)
        self.assertEqual(self.request('GET', '/v1/me', token=token), before)
        self.assertEqual(self.request('GET', '/v1/me/steps', token=token)['progress'], progress)
        self.assertEqual(self.request('GET', '/v1/circles/current', token=token)['total'], 1)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 1)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM email_accounts').fetchone()[0], 1)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM daily_steps').fetchone()[0], 1)
        receipt = self.service.directory / 'circle-probe.json'
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
        self.assertEqual(json.loads(receipt.read_text()), result)
        for forbidden in ['@example.test', token, control['refresh_token'], 'password', 'refresh_token', self.database.url]:
            self.assertNotIn(forbidden, receipt.read_text())

    def test_lost_migration_response_saves_failure_and_cleans_all_active_probe_members(self):
        self.start()
        request = self.service.request
        migrated = []

        def lose_response(state, method, path, body=None, *args, **kwargs):
            value = request(state, method, path, body, *args, **kwargs)
            if method == 'PUT' and path == '/v1/me/steps' and body['steps'] == 1000:
                migrated.append(self.database.execute('SELECT COUNT(*) FROM daily_steps WHERE steps=1000').fetchone()[0])
                raise ServiceError('intentional lost migration response')
            return value

        # A previous success must never survive a failed rerun.
        (self.service.directory / 'circle-probe.json').write_text('{"status":"passed"}')
        with patch.object(self.service, 'request', side_effect=lose_response):
            with self.assertRaisesRegex(ServiceError, 'intentional lost migration response'):
                self.service.check_circles()
        receipt = json.loads((self.service.directory / 'circle-probe.json').read_text())
        self.assertEqual(migrated, [1])
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['accounts_deleted'], 3)
        for table in ['users', 'email_accounts', 'daily_steps', 'circle_participation']:
            self.assertEqual(self.database.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0], 0)
        self.assertEqual(self.request('GET', '/health')['status'], 'ok')


if __name__ == '__main__':
    unittest.main()
