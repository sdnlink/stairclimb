#!/usr/bin/env python3
"""Real HTTP contract probe for the iOS integration; no Swift execution claim."""
from datetime import datetime, timedelta, timezone
import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend.tests.pg_fixture import Database, RustServer


def verify():
    with tempfile.TemporaryDirectory(prefix='stairclimb-ios-api-') as temporary:
        database = Database()
        current = [datetime(2026, 11, 14, 15, 59, 59, tzinfo=timezone.utc)]
        server = RustServer(database, clock=lambda: current[0])

        def request(method, path, body=None, token=None, status=200, code=None):
            server.set_time(current[0])
            headers = {'Content-Type': 'application/json'}
            if token is not None:
                headers['Authorization'] = 'Bearer '+token
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            try:
                connection.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=headers)
                response = connection.getresponse()
                payload = json.loads(response.read())
                assert response.status == status, (method, path, response.status, status)
                assert response.getheader('Cache-Control') == 'no-store'
                if code is not None:
                    assert payload['error']['code'] == code
                if 'date' in payload:
                    assert payload['timezone'] == 'Asia/Shanghai'
                    assert payload['steps_per_floor'] == 100 and payload['circle_band_steps'] == 1000
                    assert payload['max_steps'] == 1_000_000
                return payload
            finally:
                connection.close()

        try:
            request('GET', '/health')
            users = [request('POST', '/v1/users', {'nickname': name}, status=201) for name in ['甲', '乙', '丙']]
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
            print('PASS real HTTP: 3 independent users, explicit consent, cumulative/idempotent upload, 3-page traversal, non-first-page me, rename/invalidation, no-record zero, identity tampering')

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
            print('PASS real HTTP: Shanghai midnight, new-day zero, old-date rejection, revoke barrier, delayed enable/upload refusal')

            deleted = request('DELETE', '/v1/me/steps', {'expected_revision': 1}, b)
            assert deleted['deleted_days'] == 1 and not deleted['user']['sharing_enabled']
            request('DELETE', '/v1/me/steps', {'expected_revision': 1}, b, 409, 'consent_changed')
            request('DELETE', '/v1/me', {'expected_revision': 1}, c)
            request('GET', '/v1/me', token=c, status=401, code='unauthorized')
            server.close()
            server = RustServer(database, clock=lambda: current[0])
            assert request('GET', '/v1/me', token=a)['user']['nickname'] == '新甲'
            assert not request('GET', '/v1/me', token=b)['user']['sharing_enabled']
            assert not request('GET', '/v1/me/steps', token=b)['progress']['synced']
            request('GET', '/v1/me', token=c, status=401, code='unauthorized')
            print('PASS real HTTP: delete all shared days, close sharing, stale-delete refusal, delete account/credential invalidation, restart persistence')

            with database.outage():
                request('GET', '/v1/me', token=a, status=503, code='storage_unavailable')
            print('PASS real HTTP: service storage outage returns 503; no success fabrication')
        finally:
            server.close()
            database.close()
    print('CLEANUP: ephemeral server ports closed and isolated PostgreSQL schema removed; no tokens printed or saved')
    print('LIMIT: verifies real server contracts used by iOS; does not execute URLSession, SwiftUI, Swift tests, or HealthKit')


if __name__ == '__main__':
    verify()
