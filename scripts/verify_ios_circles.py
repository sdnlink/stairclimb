#!/usr/bin/env python3
"""Exercise the iOS circle contract over verified TLS, real Rust/PG and captured mail.

This probe runs no Swift code and sends mail only to its isolated loopback capture.
"""
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
import http.client
import json
from pathlib import Path
import ssl
import sys
import tempfile
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend.tests.pg_fixture import Database, ROOT, RustServer
from scripts.dev_tls import initialize
from scripts.smtp_capture import Capture


def verify():
    (ROOT / '.runtime').mkdir(exist_ok=True)
    with ExitStack() as cleanup:
        temporary = Path(cleanup.enter_context(tempfile.TemporaryDirectory(
            prefix='ios-circles-', dir=ROOT / '.runtime')))
        database = Database()
        cleanup.callback(database.close)
        certificates = initialize(temporary / 'certificates')
        context = ssl.create_default_context(cafile=str(certificates / 'ca.pem'))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        capture = Capture(temporary / 'mail')
        cleanup.callback(capture.close)
        current = datetime(2026, 11, 14, 15, 59, 59, tzinfo=timezone.utc)

        def start():
            return RustServer(database, clock=lambda: current, email_only=True,
                              tls_environment={'STAIRCLIMB_TLS_CERT': str(certificates / 'server.pem'),
                                               'STAIRCLIMB_TLS_KEY': str(certificates / 'server-key.pem')},
                              mail_environment=capture.environment)

        server = start()
        cleanup.callback(lambda: server.close())

        def request(method, path, body=None, token=None, status=200, code=None):
            server.set_time(current)
            connection = http.client.HTTPSConnection('127.0.0.1', server.server_port,
                                                     context=context, timeout=10)
            headers = {'Content-Type': 'application/json'}
            if token:
                headers['Authorization'] = 'Bearer ' + token
            try:
                connection.request(method, path, json.dumps(body).encode() if body is not None else None, headers)
                response = connection.getresponse()
                value = json.loads(response.read())
                assert response.status == status, (method, path.split('?')[0], response.status, status)
                assert response.getheader('Cache-Control') == 'no-store'
                if code:
                    assert value['error']['code'] == code
                if status == 200:
                    assert value['timezone'] == 'Asia/Shanghai' and value['circle_band_steps'] == 1000
                return value
            finally:
                connection.close()

        tokens, revisions = [], [0, 0, 0]
        password = 'private circle contract password'
        for index in range(3):
            email = f'circle-{index}@example.test'
            request('POST', '/v1/auth/register', {'email': email, 'password': password,
                                                'nickname': f'圈友{index}'}, status=202)
            request('POST', '/v1/auth/verify', {'token': capture.token(), 'password': password})
            session = request('POST', '/v1/auth/login', {'email': email, 'password': password})
            tokens.append(session['token'])

        def update(index, path, body=None, method='PUT'):
            value = request(method, path, dict(body or {}, expected_revision=revisions[index]), tokens[index])
            if 'user' in value:
                revisions[index] = value['user']['consent_revision']
            return value

        def sync(index, steps, date='2026-11-14'):
            return update(index, '/v1/me/steps', {'date': date, 'steps': steps})

        def page(index, suffix='/members', **query):
            value = request('GET', '/v1/circles/current' + suffix + ('?' + urlencode(query) if query else ''),
                            token=tokens[index])
            # Circle models expose only public identifiers, nicknames and daily summaries.
            for entry in value.get('items', []) + ([value['entry']] if value.get('entry') else []):
                assert set(entry) == {'user_id', 'nickname', 'steps', 'floor', 'remaining_steps', 'position', 'is_me'}
                assert entry['floor'] == entry['steps'] // 100
            return value

        for index in range(3):
            assert not page(index)['participating']
            update(index, '/v1/me/sharing', {'enabled': True})
            assert not page(index)['participating']
            sync(index, 999 if index < 2 else 1000)
            update(index, '/v1/me/circle-participation', {'enabled': True})
        a, b, c = (page(index) for index in range(3))
        assert a['circle'] == b['circle'] and a['total'] == b['total'] == 2
        assert a['circle']['id'] == '2026-11-14:0-999'
        assert c['circle']['id'] == '2026-11-14:1000-1999' and c['total'] == 1
        print('PASS HTTPS circles: 3 verified email users, independent sharing/participation consent, exact steps, 999/1000 separation, real small circles, public fields only')

        first = page(0, limit=1)
        last = page(0, limit=1, cursor=first['next_cursor'])
        assert len({first['items'][0]['user_id'], last['items'][0]['user_id']}) == 2
        assert last['next_cursor'] is None
        viewer = 0 if last['items'][0]['is_me'] else 1
        location = page(viewer, '/me', limit=1)
        assert location['entry']['position'] == 2 and location['entry']['is_me']
        located = page(viewer, limit=1, cursor=location['page_cursor'])
        assert located['items'][0]['is_me']
        sync(0, 1000)
        assert page(0)['circle'] == page(2)['circle'] and page(2)['total'] == 2
        assert page(1)['total'] == 1
        stable = page(0)
        sync(0, 1000)
        assert page(0) == stable
        request('GET', '/v1/circles/current/members?' + urlencode({'limit': 1, 'cursor': first['next_cursor']}),
                token=tokens[0], status=409, code='circle_changed')
        sync(0, 999)
        assert page(0)['total'] == 2 and page(2)['total'] == 1
        print('PASS HTTPS circles: complete pagination, non-first-page me, bidirectional migration, old cursor refusal, duplicate snapshot idempotence')

        old_revision = revisions[0]
        update(0, '/v1/me/sharing', {'enabled': False})
        assert not page(0)['participating'] and page(1)['total'] == 1
        request('PUT', '/v1/me/circle-participation', {'enabled': True, 'expected_revision': old_revision},
                tokens[0], status=409, code='consent_changed')
        update(0, '/v1/me/sharing', {'enabled': True})
        assert not page(0)['participating']
        update(0, '/v1/me/circle-participation', {'enabled': True})
        deleted = update(0, '/v1/me/steps', method='DELETE')
        assert deleted['deleted_days'] == 1 and not deleted['user']['sharing_enabled']
        assert not page(0)['participating'] and page(1)['total'] == 1
        update(1, '/v1/me', method='DELETE')
        request('GET', '/v1/circles/current/members', token=tokens[1], status=401, code='unauthorized')
        assert page(2)['total'] == 1
        server.close()
        server = start()
        assert not page(0)['participating'] and page(2)['total'] == 1
        print('PASS HTTPS circles: revoke/version barrier, no implicit rejoin, delete all steps closes participation, account deletion, restart persistence, other member retained')

        old_location = page(2, '/me', limit=1)
        current += timedelta(seconds=1)
        fresh = page(2)
        assert fresh['date'] == '2026-11-15' and fresh['circle']['id'] == '2026-11-15:0-999'
        assert fresh['items'][0]['steps'] == fresh['items'][0]['floor'] == 0
        request('GET', '/v1/circles/current/members?' + urlencode({'limit': 1, 'cursor': old_location['page_cursor']}),
                token=tokens[2], status=409, code='circle_changed')
        request('PUT', '/v1/me/steps', {'date': '2026-11-14', 'steps': 2000,
                                     'expected_revision': revisions[2]}, tokens[2], status=409, code='day_changed')
        assert database.execute("SELECT steps FROM daily_steps WHERE date='2026-11-14'").fetchall() == [(1000,)]
        update(0, '/v1/me/sharing', {'enabled': True})
        update(0, '/v1/me/circle-participation', {'enabled': True})
        assert page(0)['total'] == page(2)['total'] == 2
        with database.outage():
            request('GET', '/v1/circles/current/members', token=tokens[0], status=503, code='storage_unavailable')
        assert page(0)['total'] == 2
        print('PASS HTTPS circles: Shanghai midnight zero/regroup, yesterday cursor/upload refused, history retained, no-record zero member, actual database outage returns 503 and recovers')
    print('CLEANUP: temporary Rust/TLS/SMTP ports, private mail/certificates and isolated PostgreSQL schema removed')
    print('LIMIT: server contract verification only; Swift build, XCTest, device trust, HealthKit and UI remain unexecuted on Linux')


if __name__ == '__main__':
    verify()
