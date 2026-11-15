#!/usr/bin/env python3
"""Run the task's persistent loopback HTTPS service and local-only SMTP sink."""
from contextlib import contextmanager
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
import fcntl
import ctypes
import hashlib
import http.client
import json
import os
import platform
from pathlib import Path
import re
import secrets
import select
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts import postgres_dev as pg
from scripts.dev_tls import initialize
from scripts.smtp_capture import Capture

DEFAULT = ROOT / '.runtime/delivery'
BINARY = ROOT / 'backend/target/debug/stairclimb-server'


class ServiceError(RuntimeError):
    pass


def now():
    return datetime.now(timezone.utc).isoformat()


def save(path, value):
    temporary = path.with_suffix('.new')
    pg.private_write(temporary, json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def identity(pid):
    """Start ticks plus argv identify an owned process; a zombie has already stopped."""
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        if fields[0] == 'Z':
            return None
        return {'pid': pid, 'start_ticks': fields[19],
                'argv': Path(f'/proc/{pid}/cmdline').read_bytes().decode().rstrip('\0').split('\0')}
    except FileNotFoundError:
        return None


def pidfd_call(number, *arguments):
    # Some Python/libc builds omit wrappers even on a supported Linux kernel.
    # These numbers are shared by Linux x86_64 and asm-generic aarch64 headers.
    if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'aarch64'):
        raise ServiceError('This lifecycle entry requires Linux x86_64/aarch64 with pidfd support')
    library = ctypes.CDLL(None, use_errno=True)
    library.syscall.restype = ctypes.c_long
    result = library.syscall(ctypes.c_long(number), *arguments)
    if result < 0:
        raise OSError(ctypes.get_errno(), 'Linux pidfd operation failed')
    return result


def open_pidfd(pid):
    if hasattr(os, 'pidfd_open'):
        return os.pidfd_open(pid)
    return pidfd_call(434, ctypes.c_int(pid), ctypes.c_uint(0))


def send_pidfd(descriptor, number):
    if hasattr(signal, 'pidfd_send_signal'):
        signal.pidfd_send_signal(descriptor, number)
    else:
        pidfd_call(424, ctypes.c_int(descriptor), ctypes.c_int(number), ctypes.c_void_p(0), ctypes.c_uint(0))


def stop_process(record):
    """Use pidfd so even PID reuse between checking and signalling is harmless."""
    try:
        descriptor = open_pidfd(record['pid'])
    except ProcessLookupError:
        return
    try:
        actual = identity(record['pid'])
        if actual is None:
            return
        if actual != record:
            raise ServiceError('Process ownership changed; refusing to signal it')
        send_pidfd(descriptor, signal.SIGTERM)
        if not select.select([descriptor], [], [], 5)[0]:
            send_pidfd(descriptor, signal.SIGKILL)
            if not select.select([descriptor], [], [], 5)[0]:
                raise ServiceError('Owned process did not stop')
    finally:
        os.close(descriptor)


def wait_until(process, predicate, description):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise ServiceError(description + ' exited; inspect its private log')
        result = predicate()
        if result:
            return result
        time.sleep(.025)
    raise ServiceError(description + ' readiness timed out')


class LocalService:
    def __init__(self, directory=DEFAULT):
        self.directory = Path(directory).resolve()
        if not self.directory.is_relative_to((ROOT / '.runtime').resolve()):
            raise ServiceError('Runtime files must stay under ignored .runtime')
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.directory.chmod(0o700)
        self.state_file = self.directory / 'service.json'
        self.children = []

    @contextmanager
    def locked(self):
        with (self.directory / 'control.lock').open('a') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def read(self):
        value = json.loads(self.state_file.read_text())
        if value['root'] != str(ROOT):
            raise ServiceError('Runtime belongs to another workspace')
        return value

    def status(self):
        state = self.read()
        if state['state'] != 'running':
            raise ServiceError('Local service is stopped')
        if any(identity(record['pid']) != record for record in state['processes'].values()):
            raise ServiceError('A recorded process stopped or changed; run stop before restarting')
        return state

    def request(self, state, method, path, body=None, token=None, expected=200):
        context = ssl.create_default_context(cafile=state['ca_certificate'])
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        connection = http.client.HTTPSConnection('127.0.0.1', state['port'], context=context, timeout=10)
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        try:
            connection.request(method, path, json.dumps(body).encode() if body is not None else None, headers)
            response = connection.getresponse()
            payload = json.loads(response.read())
            if response.status != expected or response.getheader('Cache-Control') != 'no-store':
                raise ServiceError(f'{method} {path.split("?")[0]} returned unexpected HTTP status {response.status}')
            return payload
        finally:
            connection.close()

    def start(self, port=8787, *, database_url=None):
        with self.locked():
            if self.state_file.exists() and self.read()['state'] != 'stopped':
                return self.status()
            # Verify safe stopping is available before creating any resources.
            descriptor = open_pidfd(os.getpid())
            try:
                send_pidfd(descriptor, 0)
            finally:
                os.close(descriptor)
            database_url = database_url or pg.ensure()
            options = parse_qs(urlsplit(database_url).query).get('options', ['-csearch_path=public'])[0]
            match = re.fullmatch(r'-csearch_path=(public|test_[0-9a-f]{32})', options)
            if not match:
                raise ServiceError('Only task public or isolated test schemas are supported')
            schema = match[1]
            state = {'root': str(ROOT), 'state': 'starting', 'started_at': now(), 'processes': {},
                     'database': dict(json.loads((pg.RUNTIME / 'postgres.json').read_text()), schema=schema),
                     'directory': str(self.directory), 'smtp_directory': str(self.directory / 'mail'),
                     'server_log': str(self.directory / 'server.log'), 'smtp_log': str(self.directory / 'smtp.log'),
                     'build_log': str(self.directory / 'build.log')}
            with self.private_log('build.log', 'wb') as log:
                result = subprocess.run(['cargo', 'build', '--locked', '--manifest-path', str(ROOT / 'backend/Cargo.toml'),
                                         '--bin', 'stairclimb-server'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise ServiceError('Rust build failed; inspect the private build log')
            certificates = initialize(self.directory / 'tls')
            state['ca_certificate'] = str(certificates / 'ca.pem')
            state['tls_certificate'] = str(certificates / 'server.pem')
            state['tls_key'] = str(certificates / 'server-key.pem')
            state['binary'] = str(BINARY)
            state['binary_sha256'] = hashlib.sha256(BINARY.read_bytes()).hexdigest()
            state['source_version'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
            inputs = [ROOT / 'backend/Cargo.toml', ROOT / 'backend/Cargo.lock',
                      *sorted((ROOT / 'backend/src').rglob('*.rs')), *sorted((ROOT / 'backend/migrations').glob('*.sql'))]
            state['backend_sources'] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
            save(self.state_file, state)
            children = []
            try:
                ready = self.directory / 'smtp-ready.json'
                ready.unlink(missing_ok=True)
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith(('SMTP_', 'STAIRCLIMB_')) and key != 'DATABASE_URL'}
                mail = self.spawn([sys.executable, str(Path(__file__).resolve()), '_capture', '--directory',
                                   str(self.directory)], environment, 'smtp.log')
                children.append(mail)
                self.children.append(mail)
                state['processes']['smtp'] = identity(mail.pid)
                save(self.state_file, state)
                mail_state = wait_until(mail, lambda: json.loads(ready.read_text()) if ready.exists() else None, 'SMTP capture')
                state['smtp_port'] = mail_state['port']
                # The sink can never forward mail, even if the caller has production SMTP env vars.
                environment.update(DATABASE_URL=database_url, SMTP_MODE='local-capture', SMTP_HOST='127.0.0.1',
                                   SMTP_PORT=str(state['smtp_port']), SMTP_FROM='noreply@stairclimb.test',
                                   STAIRCLIMB_TLS_CERT=state['tls_certificate'], STAIRCLIMB_TLS_KEY=state['tls_key'])
                with socket.socket() as probe:
                    try:
                        probe.bind(('127.0.0.1', port))
                    except OSError:
                        port = 0  # Let the OS allocate, preserving whoever owns the preferred port.
                offset = (self.directory / 'server.log').stat().st_size if (self.directory / 'server.log').exists() else 0
                server = self.spawn([str(BINARY), '--host', '127.0.0.1', '--port', str(port)], environment, 'server.log')
                children.append(server)
                self.children.append(server)
                state['processes']['rust'] = identity(server.pid)
                save(self.state_file, state)
                listener = wait_until(server, lambda: re.search(r'listening on 127\.0\.0\.1:(\d+);',
                                      (self.directory / 'server.log').read_text()[offset:]), 'Rust HTTPS server')
                state['port'] = int(listener[1])
                state['address'] = f'https://127.0.0.1:{state["port"]}'
                executable = Path(f'/proc/{server.pid}/exe')
                if hashlib.sha256(executable.read_bytes()).hexdigest() != state['binary_sha256']:
                    raise ServiceError('Running executable differs from the built Rust server')
                health = self.request(state, 'GET', '/health')
                if health['status'] != 'ok' or health['timezone'] != 'Asia/Shanghai':
                    raise ServiceError('Unexpected health response')
                state['migrations'] = json.loads(pg.sql('SET search_path TO ' + schema + '; SELECT json_agg(version ORDER BY version) FROM schema_migrations;'))
                if state['migrations'] != [1, 2, 3]:
                    raise ServiceError('Unexpected database migrations')
                state['state'] = 'running'
                state['health'] = health
                save(self.state_file, state)
                return state
            except BaseException:
                for child in reversed(children):
                    if child.poll() is None:
                        stop_process(identity(child.pid))
                    child.wait(timeout=5)
                state['state'] = 'stopped'
                save(self.state_file, state)
                raise

    def private_log(self, name, mode='ab'):
        path = self.directory / name
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | (os.O_TRUNC if mode == 'wb' else os.O_APPEND), 0o600)
        os.chmod(path, 0o600)
        return os.fdopen(descriptor, mode)

    def spawn(self, command, environment, name):
        with self.private_log(name) as log:
            return subprocess.Popen(command, cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)

    def stop(self):
        with self.locked():
            state = self.read()
            # Validate every live identity before stopping either task process.
            for record in state['processes'].values():
                actual = identity(record['pid'])
                if actual is not None and actual != record:
                    raise ServiceError('Process ownership changed; refusing to signal it')
            for record in reversed(list(state['processes'].values())):
                stop_process(record)
            for child in self.children:
                child.wait(timeout=5)
            self.children.clear()
            state.update(state='stopped', stopped_at=now())
            save(self.state_file, state)
            return {'state': 'stopped', 'database_retained': True, 'logs_retained': True}

    def mail_token(self, email):
        for path in (self.directory / 'mail').glob('*.eml'):
            mail = BytesParser(policy=policy.default).parsebytes(path.read_bytes())
            if str(mail['To']) == email:
                tokens = re.findall(r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])', mail.get_content())
                if len(tokens) == 1:
                    return tokens[0]
        raise ServiceError('Verification proof not found in local captured mail')

    def check(self):
        """Two disposable accounts exercise the actual persistent production process."""
        with self.locked():
            (self.directory / 'probe.json').unlink(missing_ok=True)
            state = self.status()
            request = lambda method, path, body=None, token=None, expected=200: self.request(state, method, path, body, token, expected)
            result = {'status': 'failed', 'checked_at': now(), 'address': state['address'], 'rust_pid': state['processes']['rust']['pid'],
                      'binary_sha256': state['binary_sha256'], 'source_version': state['source_version'],
                      'test_data': 'Two disposable, synthetic task accounts; removed in finally. No HealthKit data.',
                      'health': request('GET', '/health')}
            sessions = []
            cleanup_ok = True
            try:
                if request('POST', '/v1/users', {'nickname': '不能绕过邮箱'}, expected=403)['error']['code'] != 'email_registration_required':
                    raise ServiceError('Anonymous registration bypass was not rejected')
                for index, steps in enumerate([101, 999]):
                    email = 'delivery-' + secrets.token_hex(12) + '@example.test'
                    password = secrets.token_urlsafe(32)
                    request('POST', '/v1/auth/register', {'email': email, 'password': password, 'nickname': f'交付自检{index + 1}'}, expected=202)
                    request('POST', '/v1/auth/verify', {'token': self.mail_token(email), 'password': password})
                    login = request('POST', '/v1/auth/login', {'email': email, 'password': password})
                    token = login['token']
                    sessions.append(token)
                    if login['user']['sharing_enabled']:
                        raise ServiceError('Registration unexpectedly enabled sharing')
                    date = request('GET', '/health')['date']
                    if request('PUT', '/v1/me/steps', {'date': date, 'steps': steps, 'expected_revision': 0}, token, 403)['error']['code'] != 'sharing_required':
                        raise ServiceError('Missing health sharing consent was not rejected')
                    user = request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)['user']
                    body = {'date': date, 'steps': steps, 'expected_revision': user['consent_revision']}
                    first = request('PUT', '/v1/me/steps', body, token)
                    second = request('PUT', '/v1/me/steps', body, token)
                    if first['progress'] != second['progress'] or first['progress']['floor'] != steps // 100:
                        raise ServiceError('Cumulative upload was not idempotent')
                result['leaderboard'] = request('GET', '/v1/leaderboard?limit=1', token=sessions[0])
                items = list(result['leaderboard']['items'])
                cursor = result['leaderboard']['next_cursor']
                seen = set()
                while cursor:
                    if cursor in seen:
                        raise ServiceError('Repeated leaderboard cursor')
                    seen.add(cursor)
                    page = request('GET', '/v1/leaderboard?' + urlencode({'limit': 1, 'cursor': cursor}), token=sessions[0])
                    items.extend(page['items'])
                    cursor = page['next_cursor']
                ids = {request('GET', '/v1/me', token=token)['user']['id'] for token in sessions}
                if len(items) != len({item['user_id'] for item in items}) or not ids.issubset({item['user_id'] for item in items}):
                    raise ServiceError('Leaderboard traversal lost or duplicated users')
                result['leaderboard_traversed'] = len(items)
                result['me'] = request('GET', '/v1/leaderboard/me?limit=1', token=sessions[0])
                own_page = request('GET', '/v1/leaderboard?' + urlencode({'limit': 1, 'cursor': result['me']['page_cursor']}), token=sessions[0])
                result['circles'] = request('GET', '/v1/circles/current', token=sessions[0])
                if not result['me']['entry']['is_me'] or not own_page['items'][0]['is_me'] or result['circles']['participating']:
                    raise ServiceError('Unexpected self marker or implicit circle consent')
                result['status'] = 'passed'
            except BaseException:
                result['status'] = 'failed'
                raise
            finally:
                for token in sessions:
                    try:
                        user = request('GET', '/v1/me', token=token)['user']
                        request('DELETE', '/v1/me', {'expected_revision': user['consent_revision']}, token)
                        request('GET', '/v1/me', token=token, expected=401)
                    except Exception:
                        cleanup_ok = False
                result['accounts_deleted'] = len(sessions) if cleanup_ok else None
                if not cleanup_ok:
                    result['status'] = 'failed_cleanup'
                save(self.directory / 'probe.json', result)
            if not cleanup_ok:
                raise ServiceError('Probe account cleanup failed; inspect private runtime state')
            return result

    def check_email_auth(self):
        """Full authentication lifecycle on the persistent production HTTPS process."""
        with self.locked():
            receipt = self.directory / 'email-probe.json'
            receipt.unlink(missing_ok=True)
            state = self.status()
            request = lambda method, path, body=None, token=None, expected=200: self.request(state, method, path, body, token, expected)
            result = {'status': 'failed', 'checked_at': now(), 'address': state['address'],
                      'rust_pid': state['processes']['rust']['pid'], 'binary_sha256': state['binary_sha256'],
                      'backend_build_source_version': state['source_version'],
                      'source_version': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                      'probe_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      'test_data': 'Two disposable synthetic email accounts; removed in finally. No HealthKit data.',
                      'completed': []}
            accounts = []  # Password candidates and sessions stay in memory, including after a lost response.

            def require(condition, message):
                if not condition:
                    raise ServiceError(message)

            def proof(account):
                # UUID filenames are unordered. Resend/reset must use the newest captured message.
                paths = sorted((self.directory / 'mail').glob('*.eml'), key=lambda path: path.stat().st_mtime_ns, reverse=True)
                for path in paths:
                    mail = BytesParser(policy=policy.default).parsebytes(path.read_bytes())
                    if str(mail['To']) == account['email']:
                        tokens = re.findall(r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])', mail.get_content())
                        require(len(tokens) == 1, 'Captured email did not contain one proof')
                        return tokens[0]
                raise ServiceError('Proof not found in the private local capture')

            def login(account, password):
                session = request('POST', '/v1/auth/login', {'email': account['email'], 'password': password})
                account.update(token=session['token'], refresh=session['refresh_token'], id=session['user']['id'])
                return session

            def refused(method, path, body=None, token=None, expected=401, code='unauthorized'):
                require(request(method, path, body, token, expected)['error']['code'] == code,
                        'Authentication or privacy failure returned an unexpected error')

            def public_page(path, token, fields):
                page = request('GET', path, token=token)
                require(all(set(item) == fields for item in page['items']), 'Public model exposed unexpected fields')
                return page

            def recover_session(account):
                if account.get('token'):
                    try:
                        return request('GET', '/v1/me', token=account['token'])['user']
                    except Exception:
                        pass  # A refresh, reset or logout may have committed before its response was lost.
                for password in account['passwords']:
                    try:
                        return login(account, password)['user']
                    except Exception:
                        pass
                # Registration or verification may have lost its response before the first login.
                request('POST', '/v1/auth/verify', {'token': proof(account), 'password': account['passwords'][-1]})
                return login(account, account['passwords'][-1])['user']

            try:
                require(all(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == digest
                            for path, digest in state['backend_sources'].items()), 'Running backend sources changed; restart before checking')
                require(hashlib.sha256(Path(f'/proc/{result["rust_pid"]}/exe').read_bytes()).hexdigest() == state['binary_sha256'],
                        'Running executable differs from the recorded Rust build')
                result['health'] = request('GET', '/health')
                date = result['health']['date']
                for index in range(2):
                    account = {'email': 'email-delivery-' + secrets.token_hex(12) + '@example.test',
                               'passwords': [secrets.token_urlsafe(32)]}
                    accounts.append(account)
                    password = account['passwords'][0]
                    request('POST', '/v1/auth/register', {'email': account['email'], 'password': password,
                                                         'nickname': f'邮箱交付自检{index + 1}'}, expected=202)
                    original = proof(account)
                    refused('POST', '/v1/auth/login', {'email': account['email'], 'password': password},
                            code='authentication_failed')
                    if index == 0:
                        request('POST', '/v1/auth/resend', {'email': account['email']}, expected=202)
                        require(proof(account) != original, 'Resend did not issue a new captured proof')
                        refused('POST', '/v1/auth/verify', {'token': original, 'password': password},
                                expected=400, code='invalid_credential')
                    current = proof(account)
                    require(request('POST', '/v1/auth/verify', {'token': current, 'password': password})['completed'],
                            'Email verification was not confirmed')
                    refused('POST', '/v1/auth/verify', {'token': current, 'password': password},
                            expected=400, code='invalid_credential')
                    session = login(account, password)
                    require(not session['user']['sharing_enabled'] and 'email' not in session['user'],
                            'Email activation changed health consent or exposed email')
                    require(request('GET', '/v1/auth/account', token=account['token'])['email'] == account['email'],
                            'Private account email did not match')
                    require(not request('GET', '/v1/circles/current', token=account['token'])['participating'],
                            'Email activation implicitly joined a circle')
                    refused('PUT', '/v1/me/steps', {'date': date, 'steps': 101, 'expected_revision': 0}, account['token'],
                            403, 'sharing_required')
                    request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, account['token'])
                    request('PUT', '/v1/me/circle-participation', {'enabled': True, 'expected_revision': 1}, account['token'])
                    request('PUT', '/v1/me/steps', {'date': date, 'steps': [101, 999][index], 'expected_revision': 2}, account['token'])
                result['completed'].append('two verified email accounts, resend invalidation, proof replay, separate health and circle consent')
                a, b = accounts
                fields = {'user_id', 'nickname', 'steps', 'floor', 'remaining_steps', 'position', 'is_me'}
                result['leaderboard'] = public_page('/v1/leaderboard?limit=100', a['token'], fields | {'rank'})
                result['circles'] = public_page('/v1/circles/current/members?limit=100', a['token'], fields)
                result['me'] = request('GET', '/v1/leaderboard/me?limit=1', token=a['token'])
                require(result['me']['entry']['is_me'] and result['me']['entry']['steps'] == 101
                        and result['circles']['circle']['id'] == date + ':0-999', 'Unexpected real leaderboard or circle')
                request('PUT', '/v1/me/sharing', {'enabled': False, 'expected_revision': 2}, a['token'])
                result['completed'].append('HTTPS health, public field allowlists, real leaderboard, self and active circle; sharing withdrawn')

                old_token, old_refresh = a['token'], a['refresh']
                rotated = request('POST', '/v1/auth/refresh', {'refresh_token': old_refresh})
                a.update(token=rotated['token'], refresh=rotated['refresh_token'])
                refused('GET', '/v1/me', token=old_token)
                refused('POST', '/v1/auth/refresh', {'refresh_token': old_refresh}, code='authentication_failed')
                request('POST', '/v1/auth/forgot-password', {'email': a['email']}, expected=202)
                reset_proof = proof(a)
                # Retain both possibilities before sending: reset can commit even if its response is lost.
                a['passwords'].insert(0, secrets.token_urlsafe(32))
                require(request('POST', '/v1/auth/reset-password', {'token': reset_proof, 'password': a['passwords'][0]})['completed'],
                        'Password reset was not confirmed')
                refused('GET', '/v1/me', token=a['token'])
                refused('POST', '/v1/auth/refresh', {'refresh_token': a['refresh']}, code='authentication_failed')
                refused('POST', '/v1/auth/reset-password', {'token': reset_proof, 'password': a['passwords'][0]},
                        expected=400, code='invalid_credential')
                session = login(a, a['passwords'][0])
                require(not session['user']['sharing_enabled']
                        and not request('GET', '/v1/circles/current', token=a['token'])['participating'],
                        'Password recovery reopened sharing or circle participation')
                require(request('GET', '/v1/me', token=b['token'])['user']['id'] == b['id'],
                        'Password reset changed another account')
                result['completed'].append('refresh rotation/replay, captured password reset/replay, old access/refresh invalid, consent remains withdrawn')

                request('POST', '/v1/auth/logout', {}, a['token'])
                refused('GET', '/v1/me', token=a['token'])
                refused('POST', '/v1/auth/refresh', {'refresh_token': a['refresh']}, code='authentication_failed')
                login(a, a['passwords'][0])
                result['completed'].append('logout revokes access/refresh; new password re-login works; other account retained')
                result['status'] = 'passed'
            finally:
                deleted = 0
                for account in accounts:
                    try:
                        user = recover_session(account)
                        request('DELETE', '/v1/me', {'expected_revision': user['consent_revision']}, account['token'])
                        refused('GET', '/v1/me', token=account['token'])
                        refused('POST', '/v1/auth/refresh', {'refresh_token': account['refresh']}, code='authentication_failed')
                        deleted += 1
                    except Exception:
                        result['status'] = 'failed_cleanup'
                result['accounts_deleted'] = deleted
                save(receipt, result)
            require(deleted == len(accounts), 'Email probe account cleanup failed; inspect private runtime state')
            return result

    def check_circles(self):
        """Exercise active circles without changing any pre-existing user's data."""
        with self.locked():
            receipt = self.directory / 'circle-probe.json'
            receipt.unlink(missing_ok=True)
            state = self.status()
            request = lambda method, path, body=None, token=None, expected=200: self.request(state, method, path, body, token, expected)
            result = {'status': 'failed', 'checked_at': now(), 'address': state['address'],
                      'rust_pid': state['processes']['rust']['pid'], 'source_version': state['source_version'],
                      'binary_sha256': state['binary_sha256'],
                      'probe_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      'test_data': 'Three disposable synthetic circle accounts; removed in finally. No HealthKit data.',
                      'health': request('GET', '/health')}
            accounts = []  # Credentials stay in memory and are never copied to the receipt.

            def require(condition, message):
                if not condition:
                    raise ServiceError(message)

            def update(index, path, body=None, method='PUT', expected=200):
                account = accounts[index]
                value = request(method, path, dict(body or {}, expected_revision=account['revision']), account['token'], expected)
                if 'user' in value:
                    account['revision'] = value['user']['consent_revision']
                return value

            def members(index):
                first, items, seen = None, [], set()
                cursor = None
                while True:
                    query = {'limit': 1, **({'cursor': cursor} if cursor else {})}
                    page = request('GET', '/v1/circles/current/members?' + urlencode(query), token=accounts[index]['token'])
                    first = first or page
                    require(page['participating'] and page['circle'] == first['circle']
                            and page['snapshot'] == first['snapshot'] and page['total'] == first['total'],
                            'Circle traversal mixed channels or snapshots')
                    for entry in page['items']:
                        require(set(entry) == {'user_id', 'nickname', 'steps', 'floor', 'remaining_steps', 'position', 'is_me'}
                                and entry['floor'] == entry['steps'] // 100
                                and entry['remaining_steps'] == 100 - entry['steps'] % 100
                                and entry['is_me'] == (entry['user_id'] == accounts[index]['id']),
                                'Unexpected public circle fields or self marker')
                    items.extend(page['items'])
                    cursor = page['next_cursor']
                    if not cursor:
                        break
                    require(cursor not in seen, 'Repeated circle cursor')
                    seen.add(cursor)
                require(len(items) == first['total'] == len({entry['user_id'] for entry in items})
                        and [entry['position'] for entry in items] == list(range(1, len(items) + 1)),
                        'Circle traversal lost or duplicated members')
                return first, items

            try:
                date = result['health']['date']
                for index, steps in enumerate([101, 999, 999]):
                    account = {'email': 'circle-delivery-' + secrets.token_hex(12) + '@example.test',
                               'password': secrets.token_urlsafe(32), 'revision': 0, 'deleted': False}
                    accounts.append(account)
                    request('POST', '/v1/auth/register', {'email': account['email'], 'password': account['password'],
                                                         'nickname': f'圈子交付自检{index + 1}'}, expected=202)
                    request('POST', '/v1/auth/verify', {'token': self.mail_token(account['email']), 'password': account['password']})
                    login = request('POST', '/v1/auth/login', {'email': account['email'], 'password': account['password']})
                    account.update(token=login['token'], id=login['user']['id'])
                    require(not login['user']['sharing_enabled'], 'Registration unexpectedly enabled sharing')
                    update(index, '/v1/me/sharing', {'enabled': True})
                    require(not request('GET', '/v1/circles/current', token=account['token'])['participating'],
                            'Sharing unexpectedly enabled circle participation')
                    update(index, '/v1/me/steps', {'date': date, 'steps': steps})
                    update(index, '/v1/me/circle-participation', {'enabled': True})

                first, items = members(0)
                ids = {account['id'] for account in accounts}
                require(first['circle']['id'] == date + ':0-999' and ids.issubset({item['user_id'] for item in items}),
                        'Active circle omitted a probe account')
                result.update(circles=first, circle_members_traversed=len(items),
                              leaderboard=request('GET', '/v1/leaderboard?limit=1', token=accounts[0]['token']))
                location = request('GET', '/v1/circles/current/me?limit=1', token=accounts[0]['token'])
                own_page = request('GET', '/v1/circles/current/members?' + urlencode({'limit': 1, 'cursor': location['page_cursor']}),
                                   token=accounts[0]['token'])
                require(location['entry']['is_me'] and location['entry']['position'] >= 3
                        and own_page['items'] == [location['entry']], 'Circle self location missed a non-first page')
                result['me'] = location
                update(0, '/v1/me/steps', {'date': date, 'steps': 101})
                require(members(0)[0]['snapshot'] == first['snapshot'], 'Repeated cumulative snapshot changed the circle')
                update(0, '/v1/me/steps', {'date': date, 'steps': 1000})
                migrated, moved_items = members(0)
                low, low_items = members(1)
                require(migrated['circle']['id'] == date + ':1000-1999'
                        and accounts[0]['id'] in {item['user_id'] for item in moved_items}
                        and accounts[0]['id'] not in {item['user_id'] for item in low_items}
                        and low['total'] == first['total'] - 1, 'Migration left inconsistent circle membership')
                stale = request('GET', '/v1/circles/current/members?' + urlencode({'limit': 1, 'cursor': first['next_cursor']}),
                                token=accounts[0]['token'], expected=409)
                require(stale['error']['code'] == 'circle_changed', 'Old circle cursor was not rejected')
                result['migrated'] = migrated
                update(0, '/v1/me/steps', {'date': date, 'steps': 101})
                require(members(0)[0]['total'] == first['total'], 'Return migration changed membership count')

                old_revision = accounts[0]['revision']
                exited = update(0, '/v1/me/circle-participation', {'enabled': False})
                require(not exited['participating'] and not exited['user']['sharing_enabled'], 'Circle exit did not close sharing')
                for path, body in [('/v1/me/circle-participation', {'enabled': True}),
                                   ('/v1/me/steps', {'date': date, 'steps': 101})]:
                    refused = request('PUT', path, dict(body, expected_revision=old_revision), accounts[0]['token'], 409)
                    require(refused['error']['code'] == 'consent_changed', 'Old request bypassed circle exit')
                update(0, '/v1/me/sharing', {'enabled': True})
                require(not request('GET', '/v1/circles/current', token=accounts[0]['token'])['participating'],
                        'Sharing silently rejoined the circle')
                update(0, '/v1/me/circle-participation', {'enabled': True})
                removed = update(0, '/v1/me/steps', method='DELETE')
                require(removed['deleted_days'] == 1 and not removed['user']['sharing_enabled']
                        and not request('GET', '/v1/circles/current', token=accounts[0]['token'])['participating'],
                        'Step deletion did not close circle membership')
                update(1, '/v1/me', method='DELETE')
                accounts[1]['deleted'] = True
                request('GET', '/v1/circles/current', token=accounts[1]['token'], expected=401)
                remaining, remaining_items = members(2)
                require(remaining['total'] == first['total'] - 2
                        and not ({accounts[0]['id'], accounts[1]['id']} & {item['user_id'] for item in remaining_items}),
                        'Privacy removal left public circle members')
                result.update(remaining=remaining, privacy_barriers='exit, delayed join/upload, step deletion, account deletion verified',
                              status='passed')
            finally:
                deleted = 0
                for account in accounts:
                    try:
                        if not account.get('token'):
                            request('POST', '/v1/auth/verify', {'token': self.mail_token(account['email']),
                                                              'password': account['password']})
                            account['token'] = request('POST', '/v1/auth/login', {'email': account['email'],
                                                                                'password': account['password']})['token']
                        if not account['deleted']:
                            user = request('GET', '/v1/me', token=account['token'])['user']
                            request('DELETE', '/v1/me', {'expected_revision': user['consent_revision']}, account['token'])
                        request('GET', '/v1/me', token=account['token'], expected=401)
                        deleted += 1
                    except Exception:
                        result['status'] = 'failed_cleanup'
                result['accounts_deleted'] = deleted
                save(receipt, result)
            require(deleted == len(accounts), 'Circle probe account cleanup failed; inspect private runtime state')
            return result


def capture(directory):
    service = LocalService(directory)
    sink = Capture(service.directory / 'mail')
    stopped = threading.Event()
    for number in (signal.SIGTERM, signal.SIGINT):
        signal.signal(number, lambda *_: stopped.set())
    save(service.directory / 'smtp-ready.json', {'host': '127.0.0.1', 'port': sink.server_address[1], 'external_delivery': False})
    try:
        stopped.wait()
    finally:
        sink.close()


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'status', 'check', 'check-circles', 'check-email-auth', 'stop', '_capture'])
    parser.add_argument('--directory', type=Path, default=DEFAULT)
    parser.add_argument('--port', type=int, default=8787)
    args = parser.parse_args()
    try:
        if args.action == '_capture':
            capture(args.directory)
            return
        if not 0 <= args.port <= 65535:
            raise ServiceError('Port must be in 0..65535')
        service = LocalService(args.directory)
        value = service.start(args.port) if args.action == 'start' else getattr(service, args.action.replace('-', '_'))()
        print(json.dumps(value, ensure_ascii=False, indent=2))
    except Exception as error:
        # Never emit exception text from TLS, database, email or authentication helpers.
        print(str(error) if isinstance(error, ServiceError) else 'Local service command failed; inspect task runtime logs', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
