#!/usr/bin/env python3
"""Real HTTPS/email contract probe for iOS; never claims Swift execution."""
from datetime import datetime, timedelta, timezone
import http.client
import json
from pathlib import Path
import sys
import tempfile
import ssl

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend.tests.pg_fixture import Database, RustServer, ROOT
from scripts.dev_tls import initialize
from scripts.smtp_capture import Capture


def verify():
    (ROOT / '.runtime').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ios-email-https-', dir=ROOT / '.runtime') as temporary:
        database = Database()
        current = [datetime(2026, 11, 14, 15, 59, 59, tzinfo=timezone.utc)]
        certificates = initialize(Path(temporary) / 'certificates')
        context = ssl.create_default_context(cafile=str(certificates / 'ca.pem'))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        capture = Capture(Path(temporary) / 'mail')
        def start():
            return RustServer(database, clock=lambda: current[0], email_only=True,
                              tls_environment={'STAIRCLIMB_TLS_CERT': str(certificates / 'server.pem'),
                                               'STAIRCLIMB_TLS_KEY': str(certificates / 'server-key.pem')},
                              mail_environment=capture.environment)
        server = start()

        def request(method, path, body=None, token=None, status=200, code=None):
            server.set_time(current[0])
            headers = {'Content-Type': 'application/json'}
            if token is not None:
                headers['Authorization'] = 'Bearer '+token
            connection = http.client.HTTPSConnection('127.0.0.1', server.server_port, context=context, timeout=10)
            try:
                connection.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=headers)
                response = connection.getresponse()
                payload = json.loads(response.read())
                assert response.status == status, (method, path, response.status, status)
                assert response.getheader('Cache-Control') == 'no-store'
                if code is not None:
                    assert payload['error']['code'] == code, (method, path, payload['error']['code'], code)
                if 'date' in payload:
                    assert payload['timezone'] == 'Asia/Shanghai'
                    assert payload['steps_per_floor'] == 100 and payload['circle_band_steps'] == 1000
                    assert payload['max_steps'] == 1_000_000
                return payload
            finally:
                connection.close()

        try:
            request('GET', '/health')
            password = 'private iOS contract password'
            users = []
            emails = ['ios-a@example.test', 'ios-b@example.test', 'ios-c@example.test']
            request('POST', '/v1/users', {'nickname': '不得绕过邮箱'}, status=403, code='email_registration_required')
            for name, email in zip(['甲', '乙', '丙'], emails):
                request('POST', '/v1/auth/register', {'email': email, 'password': password, 'nickname': name}, status=202)
                request('POST', '/v1/auth/login', {'email': email, 'password': password}, status=401, code='authentication_failed')
                request('POST', '/v1/auth/verify', {'token': capture.token(), 'password': password})
                request('POST', '/v1/auth/verify', {'token': capture.token(), 'password': password}, status=400, code='invalid_credential')
                user = request('POST', '/v1/auth/login', {'email': email, 'password': password})
                assert not user['user']['sharing_enabled'] and user['user']['consent_revision'] == 0
                assert 'email' not in user['user'] and user['expires_in'] == 900
                assert request('GET', '/v1/auth/account', token=user['token'])['email'] == email
                users.append(user)
            print('PASS verified HTTPS: 3 real email registrations, captured SMTP proofs, verification/replay, login, private account email, no implicit sharing, anonymous bypass rejected')
            tokens = [user['token'] for user in users]
            a, b, c = tokens
            request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 101, 'expected_revision': 0}, a, 403, 'sharing_required')
            for token in tokens:
                request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 0}, token)
            for token, steps in [(a, 101), (b, 999)]:
                request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': steps, 'expected_revision': 1}, token)
            first = request('GET', '/v1/leaderboard?limit=1', token=a)
            request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 101, 'expected_revision': 1}, a)
            assert request('GET', '/v1/leaderboard?limit=1', token=a)['snapshot'] == first['snapshot']
            location = request('GET', '/v1/leaderboard/me?limit=1', token=a)
            assert location['entry']['position'] == 2 and location['entry']['is_me']
            from urllib.parse import urlencode
            mypage = request('GET', '/v1/leaderboard?'+urlencode({'limit': 1, 'cursor': location['page_cursor']}), token=a)
            assert mypage['items'][0]['is_me']
            found = list(first['items'])
            cursor = first['next_cursor']
            while cursor:
                page = request('GET', '/v1/leaderboard?'+urlencode({'limit': 1, 'cursor': cursor}), token=a)
                found.extend(page['items'])
                cursor = page['next_cursor']
            assert len(found) == 3 and len({entry['user_id'] for entry in found}) == 3
            assert found[-1]['steps'] == 0 and found[-1]['floor'] == 0
            renamed = request('PATCH', '/v1/me', {'nickname': '新甲'}, a)
            assert renamed['user']['nickname'] == '新甲'
            request('GET', '/v1/leaderboard?'+urlencode({'limit': 1, 'cursor': first['next_cursor']}), token=a, status=409, code='leaderboard_changed')
            request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 1, 'expected_revision': 1, 'user_id': users[1]['user']['id']}, a, 422, 'invalid_fields')
            print('PASS verified HTTPS: 3 independent users, explicit consent, cumulative/idempotent upload, 3-page traversal, non-first-page me, rename/invalidation, no-record zero, identity tampering')

            current[0] += timedelta(seconds=1)
            newday = request('GET', '/v1/leaderboard?limit=20', token=a)
            assert newday['date'] == '2026-11-15' and all(item['steps'] == 0 for item in newday['items'])
            request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 101, 'expected_revision': 1}, a, 409, 'day_changed')
            request('PUT', '/v1/me/steps', {'date': '2026-11-15', 'steps': 5, 'expected_revision': 1}, a)
            revoked = request('PUT', '/v1/me/sharing', {'enabled': False, 'expected_revision': 1}, a)
            request('PUT', '/v1/me/steps', {'date': '2026-11-15', 'steps': 6, 'expected_revision': 1}, a, 409, 'consent_changed')
            request('PUT', '/v1/me/sharing', {'enabled': True, 'expected_revision': 1}, a, 409, 'consent_changed')
            assert not any(item['is_me'] for item in request('GET', '/v1/leaderboard', token=a)['items'])
            assert request('GET', '/v1/me', token=a)['user'] == revoked['user']
            print('PASS verified HTTPS: Shanghai midnight, new-day zero, old-date rejection, revoke barrier, delayed enable/upload refusal')

            deleted = request('DELETE', '/v1/me/steps', {'expected_revision': 1}, b)
            assert deleted['deleted_days'] == 1 and not deleted['user']['sharing_enabled']
            request('DELETE', '/v1/me/steps', {'expected_revision': 1}, b, 409, 'consent_changed')
            request('DELETE', '/v1/me', {'expected_revision': 1}, c)
            request('GET', '/v1/me', token=c, status=401, code='unauthorized')
            server.close()
            server = start()
            assert request('GET', '/v1/me', token=a)['user']['nickname'] == '新甲'
            assert not request('GET', '/v1/me', token=b)['user']['sharing_enabled']
            assert not request('GET', '/v1/me/steps', token=b)['progress']['synced']
            request('GET', '/v1/me', token=c, status=401, code='unauthorized')
            print('PASS verified HTTPS: delete all shared days, close sharing, stale-delete refusal, delete account/credential invalidation, restart persistence')

            with database.outage():
                request('GET', '/v1/me', token=a, status=503, code='storage_unavailable')
            print('PASS verified HTTPS: service storage outage returns 503; no success fabrication')

            rotated = request('POST', '/v1/auth/refresh', {'refresh_token': users[0]['refresh_token']})
            request('GET', '/v1/me', token=a, status=401, code='unauthorized')
            request('POST', '/v1/auth/refresh', {'refresh_token': users[0]['refresh_token']}, status=401, code='authentication_failed')
            a = rotated['token']
            request('POST', '/v1/auth/forgot-password', {'email': emails[0]}, status=202)
            new_password = 'new private iOS contract password'
            request('POST', '/v1/auth/reset-password', {'token': capture.token(), 'password': new_password})
            request('GET', '/v1/me', token=a, status=401, code='unauthorized')
            request('POST', '/v1/auth/refresh', {'refresh_token': rotated['refresh_token']}, status=401, code='authentication_failed')
            request('POST', '/v1/auth/reset-password', {'token': capture.token(), 'password': new_password}, status=400, code='invalid_credential')
            current_session = request('POST', '/v1/auth/login', {'email': emails[0], 'password': new_password})
            a = current_session['token']
            assert not request('GET', '/v1/me', token=a)['user']['sharing_enabled']
            request('POST', '/v1/auth/logout-all', {}, a)
            request('GET', '/v1/me', token=a, status=401, code='unauthorized')
            request('POST', '/v1/auth/refresh', {'refresh_token': current_session['refresh_token']}, status=401, code='authentication_failed')
            current_session = request('POST', '/v1/auth/login', {'email': emails[0], 'password': new_password})
            a = current_session['token']
            request('DELETE', '/v1/me', {'expected_revision': revoked['user']['consent_revision']}, a)
            request('GET', '/v1/me', token=a, status=401, code='unauthorized')
            assert database.execute('SELECT COUNT(*) FROM email_accounts WHERE email=?', (emails[0],)).fetchone()[0] == 0
            print('PASS verified HTTPS: refresh rotation/replay, reset from captured mail, old sessions invalid, reset replay, re-login without sharing, logout-all/revocation, account/email deletion')
            capture.reject = True
            request('POST', '/v1/auth/resend', {'email': 'failure@example.test'}, status=503, code='mail_unavailable')
            print('PASS verified HTTPS: SMTP failure is an error, no fake delivery or verification')
        finally:
            server.close()
            capture.close()
            database.close()
    print('CLEANUP: ephemeral TLS/SMTP ports closed, temporary private mail/certificates and isolated PostgreSQL schema removed; no secrets printed')
    print('LIMIT: verifies real server contracts used by iOS; does not execute URLSession, SwiftUI, Swift tests, or HealthKit')


if __name__ == '__main__':
    verify()
