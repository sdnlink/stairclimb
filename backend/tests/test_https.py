"""Real native Rust TLS + PostgreSQL + isolated SMTP, with normal certificate verification."""
from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time
import unittest

from backend.tests.pg_fixture import Database, ROOT, RustServer
from scripts.dev_tls import initialize, openssl
from scripts.smtp_capture import Capture


class HTTPSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / '.runtime').mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix='https-test-', dir=ROOT / '.runtime')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.certificates = initialize(cls.directory / 'certificates')
        cls.other_ca = initialize(cls.directory / 'other-ca', 'other.local')
        # An actually expired certificate signed by the trusted CA; no clock changes.
        openssl(cls.certificates, 'x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem',
                '-CAkey', 'ca-key.pem', '-CAcreateserial', '-days', '-1', '-sha256',
                '-extfile', 'server.ext', '-out', 'expired.pem')

    def setUp(self):
        self.database = Database()
        self.addCleanup(self.database.close)
        self.capture = Capture(self.directory / ('mail-' + self.database.schema))
        self.addCleanup(self.capture.close)
        self.now = datetime(2026, 11, 14, 10, 30, tzinfo=timezone.utc)
        self.server = self.start()
        self.addCleanup(lambda: self.server.close())

    def start(self, certificate='server.pem', production=False):
        return RustServer(self.database, lambda: self.now, email_only=True,
                          production=production,
                          tls_environment={'STAIRCLIMB_TLS_CERT': str(self.certificates / certificate),
                                           'STAIRCLIMB_TLS_KEY': str(self.certificates / 'server-key.pem')},
                          mail_environment=self.capture.environment)

    def context(self, ca=None):
        context = ssl.create_default_context(cafile=str(ca or self.certificates / 'ca.pem'))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        return context

    def request(self, method='GET', path='/health', body=None, token=None, context=None):
        self.server.set_time(self.now)
        connection = http.client.HTTPSConnection('127.0.0.1', self.server.server_port,
                                                context=context or self.context(), timeout=10)
        try:
            connection.connect()
            self.assertIn(connection.sock.version(), ['TLSv1.2', 'TLSv1.3'])
            headers = {'Content-Type': 'application/json'}
            if token:
                headers['Authorization'] = 'Bearer ' + token
            connection.request(method, path, json.dumps(body).encode() if body is not None else None, headers)
            response = connection.getresponse()
            self.assertEqual(response.getheader('Cache-Control'), 'no-store')
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_trusted_ca_tls12_and_tls13_health(self):
        self.server.close()
        self.server = self.start(production=True)
        for version in [ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3]:
            with self.subTest(version=version):
                context = self.context()
                context.minimum_version = context.maximum_version = version
                status, body = self.request(context=context)
                self.assertEqual(status, 200)
                self.assertEqual(body['status'], 'ok')
                self.assertEqual(body['timezone'], 'Asia/Shanghai')
        self.assertIn('transport=HTTPS', self.server.log_path.read_text())

    def test_unknown_and_wrong_ca_are_rejected(self):
        for context in [ssl.create_default_context(), self.context(self.other_ca / 'ca.pem')]:
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.request(context=context)
        self.assertEqual(self.request()[0], 200)

    def test_hostname_is_verified(self):
        with socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5) as raw:
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.context().wrap_socket(raw, server_hostname='wrong.example.test')

    def test_expired_certificate_is_rejected(self):
        self.server.close()
        self.server = self.start('expired.pem')
        with self.assertRaises(ssl.SSLCertVerificationError) as failure:
            self.request()
        self.assertIn('expired', failure.exception.verify_message.lower())

    def test_plaintext_is_rejected_and_handshake_failure_releases_capacity(self):
        for _ in range(70):
            with socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5) as connection:
                connection.sendall(b'GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n')
                try:
                    response = connection.recv(4096)
                except ConnectionResetError:
                    response = b''
                self.assertNotIn(b'HTTP/1.', response)
                self.assertNotIn(b'"ok"', response)
        self.assertEqual(self.request()[0], 200)

    def test_tls10_and_tls11_are_not_supported(self):
        for version in [ssl.TLSVersion.TLSv1, ssl.TLSVersion.TLSv1_1]:
            with self.subTest(version=version):
                context = self.context()
                context.minimum_version = context.maximum_version = version
                context.set_ciphers('ALL:@SECLEVEL=0')
                with self.assertRaises(ssl.SSLError):
                    self.request(context=context)

    def test_busy_tls_listener_never_replies_with_plaintext_http(self):
        held = []
        try:
            for _ in range(64):
                held.append(socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5))
            time.sleep(.1)  # Let the accept loop count the deliberately incomplete handshakes.
            with socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5) as extra:
                try:
                    response = extra.recv(4096)
                except ConnectionResetError:
                    response = b''
                self.assertEqual(response, b'')
        finally:
            for connection in held:
                connection.close()
        for _ in range(30):
            try:
                self.assertEqual(self.request()[0], 200)
                break
            except (OSError, ssl.SSLError):
                time.sleep(.02)
        else:
            self.fail('TLS handshake capacity was not returned')

    def test_invalid_partial_or_mismatched_configuration_fails_without_fallback(self):
        invalid = self.directory / 'invalid.pem'
        invalid.write_text('not a certificate')
        cases = [
            {'STAIRCLIMB_TLS_CERT': str(self.certificates / 'server.pem')},
            {'STAIRCLIMB_TLS_KEY': str(self.certificates / 'server-key.pem')},
            {'STAIRCLIMB_TLS_CERT': str(invalid), 'STAIRCLIMB_TLS_KEY': str(self.certificates / 'server-key.pem')},
            {'STAIRCLIMB_TLS_CERT': str(self.certificates / 'server.pem'), 'STAIRCLIMB_TLS_KEY': str(self.other_ca / 'server-key.pem')},
        ]
        for options in cases:
            environment = {k: v for k, v in os.environ.items() if not k.startswith('STAIRCLIMB_TLS_')}
            environment.update(options, DATABASE_URL=self.database.url)
            process = subprocess.run([str(ROOT/'backend/target/debug/stairclimb-server'), '--port', '0'],
                                     env=environment, capture_output=True, text=True, timeout=5)
            self.assertEqual(process.returncode, 1)
            self.assertNotIn('listening on', process.stdout)
            self.assertNotIn(self.database.url, process.stderr)

    def test_tls_errors_and_body_limits_keep_json_contract(self):
        status, body = self.request('GET', '/v1/me')
        self.assertEqual(status, 401)
        self.assertEqual(body['error']['code'], 'unauthorized')
        status, body = self.request('POST', '/v1/auth/register', {'extra': 'x'*4097})
        self.assertEqual(status, 413)
        self.assertEqual(body['error']['code'], 'body_too_large')

    def test_two_email_users_consent_steps_leaderboard_and_circles_over_https(self):
        password = 'private HTTPS test passphrase'
        users = []
        for name, email in [('小楼', 'tls-a@example.test'), ('同行者', 'tls-b@example.test')]:
            self.assertEqual(self.request('POST', '/v1/auth/register', {'nickname': name, 'email': email, 'password': password})[0], 202)
            self.assertEqual(self.request('POST', '/v1/auth/verify', {'token': self.capture.token(), 'password': password})[0], 200)
            status, session = self.request('POST', '/v1/auth/login', {'email': email, 'password': password})
            self.assertEqual(status, 200)
            self.assertFalse(session['user']['sharing_enabled'])
            users.append(session)
            token = session['token']
            self.assertEqual(self.request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)[0], 200)
            self.assertEqual(self.request('PUT', '/v1/me/circle-participation', {'enabled': True, 'expected_revision': 1}, token)[0], 200)
            self.assertEqual(self.request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 101, 'expected_revision': 2}, token)[0], 200)
        token = users[0]['token']
        for path in ['/v1/leaderboard', '/v1/circles/current/members']:
            status, result = self.request('GET', path, token=token)
            self.assertEqual(status, 200)
            self.assertEqual(result['total'], 2)
            self.assertEqual(len(result['items']), 2)
            self.assertEqual(sum(item['is_me'] for item in result['items']), 1)
            for item in result['items']:
                self.assertNotIn('email', item)
                self.assertEqual(item['floor'], 1)
        for user in users:
            self.assertNotIn(user['token'], self.server.log_path.read_text())

    def test_development_ca_reuse_permissions_and_overwrite_guard(self):
        before = (self.certificates / 'ca.pem').read_bytes()
        self.assertEqual(initialize(self.certificates), self.certificates)
        self.assertEqual((self.certificates / 'ca.pem').read_bytes(), before)
        with self.assertRaises(ValueError):
            initialize(self.certificates, 'different.local')
        self.assertEqual(self.certificates.stat().st_mode & 0o077, 0)
        for file in ['ca-key.pem', 'server-key.pem']:
            self.assertEqual((self.certificates / file).stat().st_mode & 0o077, 0)
        command = subprocess.run(['python3', str(ROOT/'scripts/dev_tls.py'), '--directory', str(self.certificates)],
                                 check=True, capture_output=True, text=True, timeout=5)
        self.assertFalse(json.loads(command.stdout)['trust_installed'])
        loaded = subprocess.run(['sh', '-c', '. "$1"; exec "$2" -c "$3"', 'tls-env-test',
                                 str(self.certificates/'server.env'), os.sys.executable,
                                 'import json,os; print(json.dumps({k:os.environ[k] for k in ["STAIRCLIMB_TLS_CERT","STAIRCLIMB_TLS_KEY"]}))'],
                                check=True, capture_output=True, text=True, timeout=5)
        paths = json.loads(loaded.stdout)
        self.assertEqual(paths['STAIRCLIMB_TLS_CERT'], str(self.certificates/'server.pem'))
        self.assertEqual(paths['STAIRCLIMB_TLS_KEY'], str(self.certificates/'server-key.pem'))


if __name__ == '__main__':
    unittest.main()
