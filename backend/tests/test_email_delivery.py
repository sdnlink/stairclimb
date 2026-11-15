"""Persistent-production email probe: real Rust, PG, trusted HTTPS and local SMTP."""
import json
import re
import stat
import unittest
from unittest.mock import patch

from backend.tests import test_delivery as delivery
from scripts.local_service import ServiceError


class EmailDeliveryTests(unittest.TestCase):
    setUp = delivery.DeliveryTests.setUp
    stop = delivery.DeliveryTests.stop
    start = delivery.DeliveryTests.start
    request = delivery.DeliveryTests.request
    account = delivery.DeliveryTests.account

    def assert_probe_accounts_removed(self, retained=0):
        for table in ['users', 'email_accounts', 'sessions', 'email_credentials', 'daily_steps', 'circle_participation']:
            expected = retained if table in ['users', 'email_accounts', 'sessions', 'daily_steps', 'circle_participation'] else 0
            self.assertEqual(self.database.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0], expected, table)

    def test_complete_email_probe_preserves_existing_data_and_keeps_all_secrets_private(self):
        self.start()
        control = self.account()
        token = control['token']
        date = self.request('GET', '/health')['date']
        self.request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)
        self.request('PUT', '/v1/me/circle-participation', {'enabled': True, 'expected_revision': 1}, token)
        self.request('PUT', '/v1/me/steps', {'date': date, 'steps': 750, 'expected_revision': 2}, token)
        before = self.request('GET', '/v1/me', token=token)
        progress = self.request('GET', '/v1/me/steps', token=token)
        result = self.service.check_email_auth()
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['accounts_deleted'], 2)
        self.assertEqual(len(result['completed']), 4)
        self.assertEqual(result['circles']['total'], 3)
        self.assertEqual(result['me']['entry']['steps'], 101)
        self.assertEqual(self.request('GET', '/v1/me', token=token), before)
        self.assertEqual(self.request('GET', '/v1/me/steps', token=token), progress)
        self.assertEqual(self.request('GET', '/v1/circles/current', token=token)['total'], 1)
        self.assert_probe_accounts_removed(retained=1)
        receipt = self.service.directory / 'email-probe.json'
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
        self.assertEqual(json.loads(receipt.read_text()), result)
        public = receipt.read_text() + self.service.state_file.read_text()
        public += (self.service.directory / 'server.log').read_text() + (self.service.directory / 'smtp.log').read_text()
        for forbidden in ['@example.test', token, control['refresh_token'], self.database.url,
                          '"password"', '"token"', '"email"', '"refresh_token"', '$argon2id$']:
            self.assertNotIn(forbidden, public)
        # All captured verification/reset proofs also stay out of public evidence.
        for mail in (self.service.directory / 'mail').glob('*.eml'):
            self.assertEqual(stat.S_IMODE(mail.stat().st_mode), 0o600)
            for proof in re.findall(r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])', mail.read_text()):
                self.assertNotIn(proof, public)

    def test_lost_reset_response_recovers_with_new_password_and_saves_failure(self):
        self.start()
        request = self.service.request
        reset_committed = []

        def lose_response(state, method, path, body=None, *args, **kwargs):
            value = request(state, method, path, body, *args, **kwargs)
            if method == 'POST' and path == '/v1/auth/reset-password' and value.get('completed'):
                reset_committed.append(self.database.execute('SELECT COUNT(*) FROM sessions').fetchone()[0])
                raise ServiceError('intentional lost reset response')
            return value

        (self.service.directory / 'email-probe.json').write_text('{"status":"passed"}')
        with patch.object(self.service, 'request', side_effect=lose_response):
            with self.assertRaisesRegex(ServiceError, 'intentional lost reset response'):
                self.service.check_email_auth()
        receipt = json.loads((self.service.directory / 'email-probe.json').read_text())
        self.assertEqual(reset_committed, [1])  # A was revoked; B remained logged in.
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['accounts_deleted'], 2)
        self.assert_probe_accounts_removed()
        self.assertEqual(self.request('GET', '/health')['status'], 'ok')

    def test_lost_resend_response_uses_latest_mail_to_clean_pending_registration(self):
        self.start()
        request = self.service.request

        def lose_response(state, method, path, *args, **kwargs):
            value = request(state, method, path, *args, **kwargs)
            if method == 'POST' and path == '/v1/auth/resend':
                raise ServiceError('intentional lost resend response')
            return value

        with patch.object(self.service, 'request', side_effect=lose_response):
            with self.assertRaisesRegex(ServiceError, 'intentional lost resend response'):
                self.service.check_email_auth()
        receipt = json.loads((self.service.directory / 'email-probe.json').read_text())
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['accounts_deleted'], 1)
        self.assert_probe_accounts_removed()

    def test_cleanup_failure_never_leaves_a_success_receipt(self):
        self.start()
        request = self.service.request

        def fail_delete(state, method, path, *args, **kwargs):
            if method == 'DELETE' and path == '/v1/me':
                raise ServiceError('intentional delete failure')
            return request(state, method, path, *args, **kwargs)

        with patch.object(self.service, 'request', side_effect=fail_delete):
            with self.assertRaisesRegex(ServiceError, 'cleanup failed'):
                self.service.check_email_auth()
        receipt = json.loads((self.service.directory / 'email-probe.json').read_text())
        self.assertEqual(receipt['status'], 'failed_cleanup')
        self.assertEqual(receipt['accounts_deleted'], 0)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 2)
        self.assertEqual(self.request('GET', '/health')['status'], 'ok')
        # The fixture stops its processes and drops its own isolated schema, including these accounts.


if __name__ == '__main__':
    unittest.main()
