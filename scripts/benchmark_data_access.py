#!/usr/bin/env python3
"""Small reproducible real HTTP/PostgreSQL experiment; isolated synthetic data only."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import statistics
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend.tests.pg_fixture import Database, RustServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--users', type=int, default=10000)
    args = parser.parse_args()
    if not 100 <= args.users <= 100000:
        parser.error('users must be 100..100000')
    db = Database()
    server = None
    try:
        server = RustServer(db, lambda: datetime(2026, 11, 14, 10, tzinfo=timezone.utc), binary=args.binary)
        token = 'A' * 43
        digest = hashlib.sha256(token.encode()).hexdigest()
        db.execute("INSERT INTO users(id,token_hash,nickname,sharing_enabled,consent_revision,created_at) SELECT lpad(i::text,32,'0'),md5(i::text)||md5(i::text),'规模用户',1,2,'2026-11-14' FROM generate_series(1,?) i", (args.users,))
        db.execute('UPDATE users SET token_hash=? WHERE id=lpad(\'1\',32,\'0\')', (digest,))
        db.execute('INSERT INTO circle_participation(user_id,enabled) SELECT id,1 FROM users')
        db.execute("INSERT INTO daily_steps(user_id,date,steps,updated_at) SELECT id,'2026-11-14',500,'2026-11-14' FROM users")
        db.execute('ANALYZE')
        def request(path, method='GET', body=None):
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=8)
            start = time.perf_counter()
            try:
                connection.request(method, path, body=json.dumps(body).encode() if body is not None else None,
                                   headers={'Authorization': 'Bearer '+token, 'Content-Type':'application/json'})
                response = connection.getresponse()
                result = json.loads(response.read())
                assert response.status == 200, (response.status, result)
                return (time.perf_counter()-start)*1000, result
            finally:
                connection.close()
        measurements = {}
        for path in ['/v1/leaderboard?limit=20', '/v1/circles/current/members?limit=20']:
            times = []
            for _ in range(12):
                elapsed, page = request(path)
                assert page['total'] == args.users and len(page['items']) == 20
                times.append(elapsed)
            measurements[path] = {'requests': len(times), 'median_ms':round(statistics.median(times),3), 'max_ms':round(max(times),3)}
        with ThreadPoolExecutor(max_workers=8) as pool:
            times = list(pool.map(lambda _: request('/v1/leaderboard?limit=20')[0], range(32)))
        measurements['concurrent_read'] = {'workers':8,'requests':32,'median_ms':round(statistics.median(times),3),'max_ms':round(max(times),3)}
        # Holding the public revision row must no longer block unrelated no-op/private writes.
        with ThreadPoolExecutor(max_workers=1) as pool:
            with db.write_lock():
                future = pool.submit(request, '/v1/me', 'PATCH', {'nickname':'规模用户'})
                time.sleep(.35)
                completed = future.done()
            elapsed, _ = future.result()
        rss = next(line.strip() for line in Path(f'/proc/{server.process.pid}/status').read_text().splitlines() if line.startswith('VmRSS:'))
        connections = db.execute("SELECT count(*) FROM pg_stat_activity WHERE application_name=?", (db.schema,)).fetchone()[0]
        binary = Path(f'/proc/{server.process.pid}/exe').resolve()
        print(json.dumps({'users':args.users,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'measurements':measurements,
                          'noop_write_during_revision_lock_completed_within_350ms':completed,'noop_write_ms':round(elapsed,3),
                          'server_rss_after_workload':rss,'idle_database_connections':connections,
                          'limits':'debug binary; same host; synthetic equal steps; no throughput claim; RSS includes allocator retention'},ensure_ascii=False,indent=2))
    finally:
        if server:
            server.close()
        db.close()

if __name__ == '__main__':
    main()
