"""Real Rust/PostgreSQL/loopback SMTP lifecycle; no external email or fake DB."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from backend.tests.pg_fixture import Database, ROOT, RustServer
from scripts.smtp_capture import Capture

PASSWORD = 'a private passphrase 123'
NEW_PASSWORD = 'a new private passphrase 456'


class EmailAuthTests(unittest.TestCase):
    def setUp(self):
        (ROOT / '.runtime').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='auth-mail-', dir=ROOT / '.runtime')
        self.addCleanup(self.temporary.cleanup)
        self.capture = Capture(Path(self.temporary.name) / 'capture')
        self.addCleanup(self.capture.close)
        self.database = Database()
        self.addCleanup(self.database.close)
        self.now = datetime(2026, 11, 14, 10, 30, tzinfo=timezone.utc)
        self.start()
        self.addCleanup(lambda: self.server.close())

    def start(self, *, email_only=True, environment=None):
        self.server = RustServer(self.database, lambda: self.now, email_only=email_only,
                                 mail_environment=self.capture.environment if environment is None else environment)

    def request(self, method, path, body=None, token=None):
        self.server.set_time(self.now)
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=15)
        try:
            connection.request(method, path, json.dumps(body).encode() if body is not None else None, headers)
            response = connection.getresponse()
            self.assertEqual(response.getheader('Cache-Control'), 'no-store')
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def post(self, action, body, token=None):
        return self.request('POST', '/v1/auth/' + action, body, token)

    def error(self, response, status, code):
        self.assertEqual(response[0], status)
        self.assertEqual(response[1].get('error', {}).get('code'), code)

    def register(self, email='walker@example.test', password=PASSWORD):
        status, result = self.post('register', {'email': email, 'password': password, 'nickname': '小楼'})
        self.assertEqual(status, 202)
        self.assertNotIn('token', result)
        return self.capture.token()

    def login(self, email='walker@example.test', password=PASSWORD):
        status, session = self.post('login', {'email': email, 'password': password})
        self.assertEqual(status, 200)
        self.assertEqual(len(session['token']), 43)
        self.assertEqual(len(session['refresh_token']), 43)
        self.assertNotIn('email', session['user'])
        return session

    def verified(self, email='walker@example.test'):
        proof = self.register(email)
        self.assertEqual(self.post('verify', {'token': proof, 'password': PASSWORD})[0], 200)
        return self.login(email)

    def test_registration_verification_and_independent_consent(self):
        self.error(self.request('POST', '/v1/users', {'nickname': 'anonymous'}), 403, 'email_registration_required')
        proof = self.register()
        self.error(self.post('login', {'email': 'walker@example.test', 'password': PASSWORD}), 401, 'authentication_failed')
        self.error(self.post('verify', {'token': proof, 'password': NEW_PASSWORD}), 400, 'invalid_credential')
        self.assertEqual(self.post('verify', {'token': proof, 'password': PASSWORD})[0], 200)
        self.error(self.post('verify', {'token': proof, 'password': PASSWORD}), 400, 'invalid_credential')
        session = self.login()
        self.assertFalse(session['user']['sharing_enabled'])
        self.assertEqual(session['user']['nickname'], '小楼')
        token = session['token']
        self.error(self.request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 101, 'expected_revision': 0}, token), 403, 'sharing_required')
        self.assertFalse(self.request('GET', '/v1/me/circle-participation', token=token)[1]['participating'])
        account = self.request('GET', '/v1/auth/account', token=token)
        self.assertEqual(account[0], 200)
        self.assertEqual(account[1]['email'], 'walker@example.test')
        self.error(self.request('GET', '/v1/auth/account'), 401, 'unauthorized')

    def test_duplicate_unknown_and_known_mail_responses_are_uniform(self):
        self.verified()
        for action in ['register', 'resend', 'forgot-password']:
            payload = {'password': PASSWORD, 'nickname': '重复昵称'} if action == 'register' else {}
            known = self.post(action, dict(payload, email='walker@example.test'))
            unknown = self.post(action, dict(payload, email='unknown@example.test'))
            self.assertEqual(known[0], 202)
            self.assertEqual(known, unknown)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM email_accounts').fetchone()[0], 2)
        self.assertEqual(self.database.execute("SELECT nickname FROM users JOIN email_accounts ON user_id=id WHERE email='walker@example.test'").fetchone()[0], '小楼')

    def test_pending_registration_can_be_recovered_by_mailbox_owner(self):
        old_proof = self.register(password=NEW_PASSWORD)
        self.assertEqual(self.post('forgot-password', {'email': 'walker@example.test'})[0], 202)
        reset = self.capture.token()
        self.assertEqual(self.post('reset-password', {'token': reset, 'password': PASSWORD})[0], 200)
        self.error(self.post('verify', {'token': old_proof, 'password': NEW_PASSWORD}), 400, 'invalid_credential')
        self.login()

    def test_resend_invalidates_old_proof_and_expiry_is_authoritative(self):
        old = self.register()
        self.assertEqual(self.post('resend', {'email': 'walker@example.test'})[0], 202)
        current = self.capture.token()
        self.error(self.post('verify', {'token': old, 'password': PASSWORD}), 400, 'invalid_credential')
        self.now += timedelta(seconds=900)
        self.error(self.post('verify', {'token': current, 'password': PASSWORD}), 400, 'invalid_credential')
        self.assertEqual(self.post('resend', {'email': 'walker@example.test'})[0], 202)
        self.assertEqual(self.post('verify', {'token': self.capture.token(), 'password': PASSWORD})[0], 200)

    def test_wrong_unknown_and_unverified_logins_have_same_error(self):
        self.register()
        a = self.post('login', {'email': 'walker@example.test', 'password': PASSWORD})
        b = self.post('login', {'email': 'unknown@example.test', 'password': PASSWORD})
        c = self.post('login', {'email': 'walker@example.test', 'password': NEW_PASSWORD})
        self.error(a, 401, 'authentication_failed')
        self.assertEqual(a, b)
        self.assertEqual(a, c)

    def test_validation_and_identity_fields_cannot_be_smuggled(self):
        for i, invalid in enumerate(['', 'x', 'a..b@example.test', 'a@-x.test', 'a\r\n@example.test', '中文@example.test']):
            self.error(self.post('register', {'email': invalid, 'password': PASSWORD, 'nickname': '楼'}), 422, 'invalid_email')
        for value in ['', 'short', 'x' * 129, 'a private\npassword']:
            self.error(self.post('register', {'email': 'valid@example.test', 'password': value, 'nickname': '楼'}), 422, 'invalid_password')
        self.error(self.post('register', {'email': 'valid@example.test', 'password': PASSWORD, 'nickname': '楼', 'user_id': 'other'}), 422, 'invalid_fields')
        self.error(self.post('register', {'email': 'valid@example.test', 'password': PASSWORD, 'nickname': ''}), 422, 'invalid_nickname')
        self.error(self.request('POST', '/v1/auth/verify?token=secret', {'token': 'x', 'password': PASSWORD}), 400, 'invalid_query')

    def test_salted_passwords_and_hashed_proofs_sessions_no_secret_logs(self):
        proof = self.register()
        self.register('other@example.test')
        rows = self.database.execute('SELECT password_hash FROM email_accounts').fetchall()
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(row[0].startswith('$argon2id$v=19$m=19456,t=2,p=1$') for row in rows))
        self.assertNotEqual(rows[0][0], rows[1][0])
        hashes = self.database.execute('SELECT digest FROM email_credentials').fetchall()
        self.assertIn((hashlib.sha256(proof.encode()).hexdigest(),), hashes)
        self.assertEqual(self.post('verify', {'token': proof, 'password': PASSWORD})[0], 200)
        session = self.login()
        row = self.database.execute('SELECT access_hash,refresh_hash FROM sessions').fetchone()
        self.assertEqual(row[0], hashlib.sha256(session['token'].encode()).hexdigest())
        self.assertEqual(row[1], hashlib.sha256(session['refresh_token'].encode()).hexdigest())
        for secret in [PASSWORD, 'walker@example.test', proof, session['token'], session['refresh_token']]:
            self.assertNotIn(secret, self.server.log_path.read_text())
        self.assertTrue(all(p.stat().st_mode & 0o077 == 0 for p in self.capture.directory.glob('*.eml')))

    def test_refresh_rotation_access_expiry_and_replay(self):
        first = self.verified()
        self.now += timedelta(seconds=900)
        self.error(self.request('GET', '/v1/me', token=first['token']), 401, 'unauthorized')
        status, second = self.post('refresh', {'refresh_token': first['refresh_token']})
        self.assertEqual(status, 200)
        self.error(self.post('refresh', {'refresh_token': first['refresh_token']}), 401, 'authentication_failed')
        self.assertEqual(self.request('GET', '/v1/me', token=second['token'])[0], 200)
        self.now += timedelta(days=30)
        self.error(self.post('refresh', {'refresh_token': second['refresh_token']}), 401, 'authentication_failed')

    def test_concurrent_refresh_has_one_winner(self):
        first = self.verified()
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda _: self.post('refresh', {'refresh_token': first['refresh_token']}), range(2)))
        self.assertEqual(sorted(r[0] for r in responses), [200, 401])
        self.error(self.request('GET', '/v1/me', token=first['token']), 401, 'unauthorized')

    def test_logout_and_logout_all_revoke_persistent_sessions(self):
        first = self.verified()
        second = self.login()
        self.assertEqual(self.post('logout', {}, first['token'])[0], 200)
        self.error(self.post('refresh', {'refresh_token': first['refresh_token']}), 401, 'authentication_failed')
        self.assertEqual(self.request('GET', '/v1/me', token=second['token'])[0], 200)
        third = self.login()
        self.assertEqual(self.post('logout-all', {}, second['token'])[0], 200)
        for session in [second, third]:
            self.error(self.request('GET', '/v1/me', token=session['token']), 401, 'unauthorized')
            self.error(self.post('refresh', {'refresh_token': session['refresh_token']}), 401, 'authentication_failed')

    def test_reset_is_once_only_and_revokes_all_sessions_after_restart(self):
        first = self.verified()
        second = self.login()
        self.assertEqual(self.post('forgot-password', {'email': 'walker@example.test'})[0], 202)
        reset = self.capture.token()
        self.assertEqual(self.post('reset-password', {'token': reset, 'password': NEW_PASSWORD})[0], 200)
        self.error(self.post('reset-password', {'token': reset, 'password': PASSWORD}), 400, 'invalid_credential')
        self.server.close()
        self.start()
        for session in [first, second]:
            self.error(self.request('GET', '/v1/me', token=session['token']), 401, 'unauthorized')
            self.error(self.post('refresh', {'refresh_token': session['refresh_token']}), 401, 'authentication_failed')
        self.error(self.post('login', {'email': 'walker@example.test', 'password': PASSWORD}), 401, 'authentication_failed')
        self.login(password=NEW_PASSWORD)

    def test_limits_commit_on_failure_survive_restart_and_expire(self):
        for _ in range(5):
            self.error(self.post('login', {'email': 'unknown@example.test', 'password': PASSWORD}), 401, 'authentication_failed')
        self.server.close()
        self.start()
        self.error(self.post('login', {'email': 'UNKNOWN@EXAMPLE.TEST', 'password': PASSWORD}), 429, 'rate_limited')
        self.now += timedelta(seconds=300)
        self.error(self.post('login', {'email': 'unknown@example.test', 'password': PASSWORD}), 401, 'authentication_failed')

    def test_source_limit_stops_random_credential_guessing(self):
        for i in range(30):
            token = str(i).zfill(43)
            self.error(self.post('verify', {'token': token, 'password': PASSWORD}), 400, 'invalid_credential')
        self.error(self.post('verify', {'token': 'x'*43, 'password': PASSWORD}), 429, 'rate_limited')

    def test_mail_failure_missing_config_and_retry_do_not_fake_delivery(self):
        self.capture.reject = True
        for email in ['walker@example.test', 'unknown@example.test']:
            self.error(self.post('register', {'email': email, 'password': PASSWORD, 'nickname': '小楼'}), 503, 'mail_unavailable')
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 0)
        self.capture.reject = False
        self.register()
        proof = self.capture.token()
        self.capture.reject = True
        self.error(self.post('resend', {'email': 'walker@example.test'}), 503, 'mail_unavailable')
        self.assertEqual(self.post('verify', {'token': proof, 'password': PASSWORD})[0], 200)
        self.server.close()
        self.start(environment={})
        self.error(self.post('forgot-password', {'email': 'walker@example.test'}), 503, 'mail_unavailable')
        self.error(self.post('forgot-password', {'email': 'unknown@example.test'}), 503, 'mail_unavailable')

    def test_starttls_does_not_fall_back_to_plaintext_capture(self):
        self.server.close()
        environment = dict(self.capture.environment, SMTP_MODE='starttls', SMTP_USERNAME='test', SMTP_PASSWORD='test')
        self.start(environment=environment)
        self.error(self.post('register', {'email': 'walker@example.test', 'password': PASSWORD, 'nickname': '小楼'}), 503, 'mail_unavailable')
        self.assertEqual(len(self.capture.messages), 0)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM email_accounts').fetchone()[0], 0)

    def test_legacy_binding_requires_old_device_and_mailbox_preserves_history(self):
        self.server.close()
        self.start(email_only=False)
        status, legacy = self.request('POST', '/v1/users', {'nickname': '原身份'})
        self.assertEqual(status, 201)
        old_token = legacy['token']
        uid = legacy['user']['id']
        self.request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, old_token)
        self.request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 999, 'expected_revision': 1}, old_token)
        self.server.close()
        self.start()
        self.error(self.request('GET', '/v1/leaderboard', token=old_token), 401, 'unauthorized')
        self.error(self.post('bind', {'email': 'walker@example.test', 'password': PASSWORD}), 401, 'unauthorized')
        self.error(self.post('bind', {'email': 'walker@example.test', 'password': PASSWORD, 'user_id': uid}, old_token), 422, 'invalid_fields')
        self.assertEqual(self.post('bind', {'email': 'walker@example.test', 'password': PASSWORD}, old_token)[0], 202)
        proof = self.capture.token()
        self.error(self.post('verify', {'token': proof, 'password': PASSWORD}), 401, 'unauthorized')
        self.error(self.post('verify', {'token': proof, 'password': PASSWORD}, 'x'*43), 401, 'unauthorized')
        self.assertEqual(self.post('verify', {'token': proof, 'password': PASSWORD}, old_token)[0], 200)
        session = self.login()
        self.assertEqual(session['user']['id'], uid)
        self.assertEqual(session['user']['nickname'], '原身份')
        self.assertTrue(session['user']['sharing_enabled'])
        self.assertEqual(self.request('GET', '/v1/me/steps', token=session['token'])[1]['progress']['steps'], 999)
        self.error(self.request('GET', '/v1/me', token=old_token), 401, 'unauthorized')

    def test_two_users_public_models_privacy_barriers_and_account_deletion(self):
        a = self.verified()
        b = self.verified('other@example.test')
        for session in [a, b]:
            token = session['token']
            self.assertEqual(self.request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)[0], 200)
            self.assertEqual(self.request('PUT', '/v1/me/circle-participation', {'enabled': True, 'expected_revision': 1}, token)[0], 200)
            self.assertEqual(self.request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 101, 'expected_revision': 2}, token)[0], 200)
        for path in ['/v1/leaderboard', '/v1/circles/current/members']:
            status, result = self.request('GET', path, token=a['token'])
            self.assertEqual(status, 200)
            self.assertEqual(len(result['items']), 2)
            for item in result['items']:
                self.assertFalse({'email', 'password_hash', 'token', 'refresh_token', 'digest'} & item.keys())
        self.assertEqual(self.request('PUT', '/v1/me/sharing', {'enabled': False, 'expected_revision': 2}, a['token'])[0], 200)
        self.error(self.request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 200, 'expected_revision': 2}, a['token']), 409, 'consent_changed')
        self.assertEqual(self.request('DELETE', '/v1/me', {'expected_revision': 3}, a['token'])[0], 200)
        self.error(self.post('refresh', {'refresh_token': a['refresh_token']}), 401, 'authentication_failed')
        for table in ['email_accounts', 'sessions', 'users']:
            self.assertEqual(self.database.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0], 1)
        self.assertEqual(self.request('GET', '/v1/me', token=b['token'])[0], 200)
        self.assertEqual(self.request('GET', '/v1/leaderboard', token=b['token'])[1]['total'], 1)

    def test_waiting_write_rechecks_session_after_logout(self):
        session = self.verified()
        token = session['token']
        # Revoke while a request is blocked on the real metadata write barrier.
        with ThreadPoolExecutor(max_workers=1) as pool:
            with self.database.write_lock():
                future = pool.submit(self.request, 'PATCH', '/v1/me', {'nickname': '不应写入'}, token)
                self.database.wait_for_blocked_writer()
                self.database.execute('DELETE FROM sessions')
            self.error(future.result(), 401, 'unauthorized')
        self.assertEqual(self.database.execute('SELECT nickname FROM users').fetchone()[0], '小楼')

    def test_production_binary_disables_legacy_and_external_http_listener(self):
        self.server.close()
        self.server = RustServer(self.database, lambda: self.now, production=True,
                                 mail_environment=self.capture.environment)
        self.error(self.request('POST', '/v1/users', {'nickname': 'anonymous'}), 403, 'email_registration_required')
        proof = self.register()
        self.assertEqual(self.post('verify', {'token': proof, 'password': PASSWORD})[0], 200)
        self.login()
        # Fail before opening a public listener; process diagnostics contain no configuration.
        for args in [['--host', '0.0.0.0', '--port', '0'], ['--email-only', 'true']]:
            result = subprocess.run([str(ROOT/'backend/target/debug/stairclimb-server'), *args],
                                    env=dict({k:v for k,v in os.environ.items() if not k.startswith('STAIRCLIMB_TLS_')}, DATABASE_URL=self.database.url),
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(self.database.url, result.stderr)

    def test_binding_cannot_merge_existing_email_or_claim_another_identity(self):
        registered = self.verified()
        self.server.close()
        self.start(email_only=False)
        _, first = self.request('POST', '/v1/users', {'nickname': '原甲'})
        _, second = self.request('POST', '/v1/users', {'nickname': '原乙'})
        self.server.close()
        self.start()
        # An existing email produces the same accepted response but never merges IDs.
        self.assertEqual(self.post('bind', {'email': 'walker@example.test', 'password': PASSWORD}, first['token'])[0], 202)
        invalid = self.capture.token()
        self.error(self.post('verify', {'token': invalid, 'password': PASSWORD}, first['token']), 400, 'invalid_credential')
        self.assertEqual(self.post('bind', {'email': 'bound@example.test', 'password': PASSWORD}, first['token'])[0], 202)
        proof = self.capture.token()
        self.error(self.post('verify', {'token': proof, 'password': PASSWORD}, second['token']), 401, 'unauthorized')
        self.assertEqual(self.post('verify', {'token': proof, 'password': PASSWORD}, first['token'])[0], 200)
        bound = self.login('bound@example.test')
        self.assertEqual(bound['user']['id'], first['user']['id'])
        self.assertNotEqual(bound['user']['id'], registered['user']['id'])
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 3)
        self.assertEqual(self.request('GET', '/v1/me', token=second['token'])[1]['user']['nickname'], '原乙')

    def pending_legacy_binding(self, email='owner@example.test'):
        self.server.close()
        self.start(email_only=False)
        status, legacy = self.request('POST', '/v1/users', {'nickname': '原身份A'})
        self.assertEqual(status, 201)
        token = legacy['token']
        self.assertEqual(self.request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)[0], 200)
        self.assertEqual(self.request('PUT', '/v1/me/circle-participation', {'enabled': True, 'expected_revision': 1}, token)[0], 200)
        for day, steps in [(0, 999), (-1, 1234)]:
            self.now += timedelta(days=day)
            self.assertEqual(self.request('PUT', '/v1/me/steps', {
                'date': self.now.astimezone(timezone(timedelta(hours=8))).date().isoformat(),
                'steps': steps, 'expected_revision': 2}, token)[0], 200)
            self.now -= timedelta(days=day)
        self.server.close()
        self.start()
        self.assertEqual(self.post('bind', {'email': email, 'password': PASSWORD}, token)[0], 202)
        return legacy, self.capture.token()

    def legacy_snapshot(self, uid):
        return (
            self.database.execute('SELECT id,token_hash,nickname,sharing_enabled,consent_revision,created_at FROM users WHERE id=?', (uid,)).fetchall(),
            self.database.execute('SELECT date,steps,updated_at FROM daily_steps WHERE user_id=? ORDER BY date', (uid,)).fetchall(),
            self.database.execute('SELECT enabled FROM circle_participation WHERE user_id=?', (uid,)).fetchall(),
        )

    def test_mailbox_owner_can_register_independently_of_unverified_legacy_binding(self):
        legacy, binding_proof = self.pending_legacy_binding()
        before = self.legacy_snapshot(legacy['user']['id'])
        # This is the reviewed failure path: ordinary registration cannot own A's identity.
        placeholder = self.register('owner@example.test', NEW_PASSWORD)
        self.error(self.post('verify', {'token': placeholder, 'password': NEW_PASSWORD}), 400, 'invalid_credential')
        self.assertEqual(self.post('forgot-password', {'email': 'owner@example.test'})[0], 202)
        reset = self.capture.token()
        self.error(self.post('reset-password', {'token': reset, 'password': NEW_PASSWORD}), 401, 'unauthorized')
        # Mailbox proof may create an independent identity; it never grants access to A.
        self.assertEqual(self.post('register-independent', {
            'token': reset, 'password': NEW_PASSWORD, 'nickname': '邮箱主人B'})[0], 200)
        owner = self.login('owner@example.test', NEW_PASSWORD)
        self.assertNotEqual(owner['user']['id'], legacy['user']['id'])
        self.assertEqual(owner['user']['nickname'], '邮箱主人B')
        self.assertFalse(owner['user']['sharing_enabled'])
        self.assertEqual(owner['user']['consent_revision'], 0)
        self.assertFalse(self.request('GET', '/v1/me/circle-participation', token=owner['token'])[1]['participating'])
        self.assertEqual(self.request('GET', '/v1/me/steps', token=owner['token'])[1]['progress']['steps'], 0)
        self.assertEqual(self.legacy_snapshot(legacy['user']['id']), before)
        self.assertEqual(self.request('GET', '/v1/me', token=legacy['token'])[0], 200)
        self.error(self.post('verify', {'token': binding_proof, 'password': PASSWORD}, legacy['token']), 400, 'invalid_credential')
        self.error(self.post('register-independent', {'token': reset, 'password': PASSWORD, 'nickname': '重放'}), 400, 'invalid_credential')
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 2)

    def test_independent_registration_expiry_restart_and_binding_replay(self):
        legacy, old_binding = self.pending_legacy_binding()
        before = self.legacy_snapshot(legacy['user']['id'])
        self.assertEqual(self.post('forgot-password', {'email': 'owner@example.test'})[0], 202)
        expired = self.capture.token()
        self.now += timedelta(seconds=900)
        self.server.close()
        self.start()
        self.error(self.post('register-independent', {'token': expired, 'password': NEW_PASSWORD, 'nickname': 'B'}), 400, 'invalid_credential')
        self.assertEqual(self.legacy_snapshot(legacy['user']['id']), before)
        self.assertEqual(self.post('forgot-password', {'email': 'owner@example.test'})[0], 202)
        fresh = self.capture.token()
        # The claim can be arbitrarily old; a fresh mailbox proof always recovers a safe path.
        self.assertEqual(self.post('register-independent', {'token': fresh, 'password': NEW_PASSWORD, 'nickname': 'B'})[0], 200)
        self.server.close()
        self.start()
        owner = self.login('owner@example.test', NEW_PASSWORD)
        self.assertNotEqual(owner['user']['id'], legacy['user']['id'])
        self.assertEqual(self.legacy_snapshot(legacy['user']['id']), before)
        self.error(self.post('verify', {'token': old_binding, 'password': PASSWORD}, legacy['token']), 400, 'invalid_credential')
        self.error(self.post('reset-password', {'token': fresh, 'password': PASSWORD}, legacy['token']), 400, 'invalid_credential')
        self.assertEqual(self.request('GET', '/v1/me', token=legacy['token'])[0], 200)

    def test_independent_registration_cannot_unbind_verified_or_nonlegacy_account(self):
        verified = self.verified()
        pending = self.register('pending@example.test')
        for email in ['walker@example.test', 'pending@example.test']:
            self.assertEqual(self.post('forgot-password', {'email': email})[0], 202)
            reset = self.capture.token()
            self.error(self.post('register-independent', {'token': reset, 'password': NEW_PASSWORD, 'nickname': '别的身份'}), 400, 'invalid_credential')
        self.assertEqual(self.request('GET', '/v1/me', token=verified['token'])[0], 200)
        self.assertEqual(self.post('verify', {'token': pending, 'password': PASSWORD})[0], 200)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 2)

    def test_concurrent_independent_registration_consumes_proof_once(self):
        legacy, binding_proof = self.pending_legacy_binding()
        before = self.legacy_snapshot(legacy['user']['id'])
        self.assertEqual(self.post('forgot-password', {'email': 'owner@example.test'})[0], 202)
        reset = self.capture.token()
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda _: self.post('register-independent', {
                'token': reset, 'password': NEW_PASSWORD, 'nickname': 'B'}), range(2)))
        self.assertEqual(sorted(r[0] for r in responses), [200, 400])
        self.assertEqual(self.legacy_snapshot(legacy['user']['id']), before)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 2)
        self.error(self.post('verify', {'token': binding_proof, 'password': PASSWORD}, legacy['token']), 400, 'invalid_credential')

    def test_independent_registration_invalid_requests_preserve_pending_claim(self):
        legacy, binding_proof = self.pending_legacy_binding()
        before = self.legacy_snapshot(legacy['user']['id'])
        self.error(self.post('register-independent', {'token': binding_proof, 'password': NEW_PASSWORD, 'nickname': 'B'}), 400, 'invalid_credential')
        self.assertEqual(self.post('forgot-password', {'email': 'owner@example.test'})[0], 202)
        reset = self.capture.token()
        self.error(self.post('register-independent', {'token': reset, 'password': 'short', 'nickname': 'B'}), 422, 'invalid_password')
        self.error(self.post('register-independent', {'token': reset, 'password': NEW_PASSWORD, 'nickname': ''}), 422, 'invalid_nickname')
        self.error(self.post('register-independent', {'token': reset, 'password': NEW_PASSWORD, 'nickname': 'B', 'user_id': legacy['user']['id']}), 422, 'invalid_fields')
        self.error(self.post('register-independent', {'token': 'x'*43, 'password': NEW_PASSWORD, 'nickname': 'B'}), 400, 'invalid_credential')
        self.assertEqual(self.legacy_snapshot(legacy['user']['id']), before)
        # Failed attempts do not consume a valid proof or weaken original dual ownership checks.
        self.assertEqual(self.post('verify', {'token': binding_proof, 'password': PASSWORD}, legacy['token'])[0], 200)
        self.assertEqual(self.login('owner@example.test')['user']['id'], legacy['user']['id'])


if __name__ == '__main__':
    unittest.main()
