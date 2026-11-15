"""Real HTTP and PostgreSQL bounds, independent writers, SQL pages and privacy waits."""
from concurrent.futures import ThreadPoolExecutor
import time
from urllib.parse import urlencode
import unittest

from backend.tests.pg_fixture import RustServer
from backend.tests import test_social as social


class DataAccessTests(unittest.TestCase):
    setUp = social.SocialHTTPTests.setUp
    tearDown = social.SocialHTTPTests.tearDown
    start_server = social.SocialHTTPTests.start_server
    stop_server = social.SocialHTTPTests.stop_server
    request = social.SocialHTTPTests.request
    register = social.SocialHTTPTests.register
    assert_error = social.SocialHTTPTests.assert_error
    share = social.SocialHTTPTests.share
    sync = social.SocialHTTPTests.sync
    board = social.SocialHTTPTests.board
    locate = social.SocialHTTPTests.locate
    today = social.SocialHTTPTests.today

    def test_pool_exhaustion_is_bounded_http_error_and_leases_return(self):
        a, b = self.register('甲'), self.register('乙')
        self.stop_server()
        self.server = RustServer(self.database, lambda: self.now, pool_environment={
            'STAIRCLIMB_DB_POOL_MAX':'2', 'STAIRCLIMB_DB_POOL_TIMEOUT_MS':'180'})
        self.port = self.server.server_port
        with ThreadPoolExecutor(max_workers=2) as executor:
            with self.database.write_lock():
                futures = [executor.submit(self.request, 'PATCH', '/v1/me', {'nickname':'新'+str(i)}, u['token']) for i, u in enumerate([a,b])]
                deadline = time.monotonic()+2
                while True:
                    waiting = self.database.execute("SELECT count(*) FROM pg_stat_activity WHERE application_name=? AND wait_event_type='Lock'", (self.database.schema,)).fetchone()[0]
                    if waiting == 2:
                        break
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.01)
                start = time.monotonic()
                self.assert_error(self.request('GET','/v1/me',token=a['token']), 503,'database_busy')
                self.assertLess(time.monotonic()-start, 1)
                self.assertEqual(self.database.execute('SELECT count(*) FROM pg_stat_activity WHERE application_name=?', (self.database.schema,)).fetchone()[0], 2)
            for result in futures:
                self.assertEqual(result.result(timeout=2)[0], 200)
        self.assertEqual(self.request('GET','/v1/me',token=a['token'])[0],200)
        self.assertEqual(self.database.execute('SELECT count(*) FROM pg_stat_activity WHERE application_name=?', (self.database.schema,)).fetchone()[0], 2)

    def test_waiting_user_does_not_block_other_user_and_revocation_blocks_replay(self):
        a, b = self.register('甲'), self.register('乙')
        self.share(a)
        with ThreadPoolExecutor(max_workers=1) as executor:
            with self.database.write_lock(a['user']['id']):
                waiting = executor.submit(self.sync, a, 100, 1)
                self.database.wait_for_blocked_writer()
                # Another user's real public write progresses while A is locked.
                self.assertEqual(self.request('PATCH','/v1/me', {'nickname':'乙的新昵称'}, b['token'])[0],200)
            self.assertEqual(waiting.result()[0],200)
        self.assertEqual(self.request('PUT','/v1/me/sharing',{'enabled':False,'expected_revision':1},a['token'])[0],200)
        self.assert_error(self.sync(a,101,1),409,'consent_changed')
        self.assertEqual(self.today(a)['progress']['steps'],100)

    def test_queued_upload_rereads_consent_after_user_row_is_granted(self):
        a = self.register('甲')
        self.share(a)
        self.assertEqual(self.sync(a,100,1)[0],200)
        with ThreadPoolExecutor(max_workers=1) as executor:
            with self.database.write_lock(a['user']['id']) as blocker:
                waiting = executor.submit(self.sync,a,200,1)
                self.database.wait_for_blocked_writer()
                blocker.stdin.write("UPDATE users SET sharing_enabled=0,consent_revision=2 WHERE id='" + a['user']['id'] + "'; UPDATE metadata SET value=value+1;\n")
                blocker.stdin.flush()
            self.assert_error(waiting.result(),409,'consent_changed')
        self.assertEqual(self.today(a)['progress']['steps'],100)
        self.assertEqual(self.board(a)['total'],0)

    def test_noop_write_does_not_take_public_revision_lock(self):
        a = self.register('甲')
        with self.database.write_lock():
            self.assertEqual(self.request('PATCH','/v1/me',{'nickname':'甲'}, a['token'])[0],200)

    def test_scaled_sql_pages_ties_zero_values_own_location_and_snapshot_invalidation(self):
        user = self.register('我')
        self.share(user)
        self.assertEqual(self.request('PUT','/v1/me/circle-participation',{'enabled':True,'expected_revision':1}, user['token'])[0],200)
        self.database.execute("INSERT INTO users(id,token_hash,nickname,sharing_enabled,consent_revision,created_at) SELECT lpad(i::text,32,'0'),md5(i::text)||md5(i::text),'分页',1,2,'2026-11-14' FROM generate_series(1,256) i")
        self.database.execute('INSERT INTO circle_participation(user_id,enabled) SELECT id,1 FROM users ON CONFLICT DO NOTHING')
        # No daily rows: all 257 visible users must still be included as zero.
        for path in ['/v1/leaderboard','/v1/circles/current/members']:
            ids, cursor = [], None
            for _ in range(40):
                query = {'limit':7}
                if cursor: query['cursor'] = cursor
                status, page = self.request('GET',path+'?'+urlencode(query), token=user['token'])
                self.assertEqual(status,200)
                self.assertEqual(page['total'],257)
                self.assertLessEqual(len(page['items']),7)
                for item in page['items']:
                    self.assertEqual(item['steps'],0)
                    self.assertEqual(item['position'],len(ids)+1)
                    if path == '/v1/leaderboard': self.assertEqual(item['rank'],1)
                    ids.append(item['user_id'])
                cursor = page['next_cursor']
                if cursor is None: break
            self.assertIsNone(cursor)
            self.assertEqual(len(set(ids)),257)
            self.assertEqual(ids, sorted(ids))
        own = self.locate(user,limit=7)
        self.assertEqual(own['entry']['position'],257)
        status, page = self.request('GET','/v1/leaderboard?'+urlencode({'limit':7,'cursor':own['page_cursor']}),token=user['token'])
        self.assertEqual(status,200)
        self.assertTrue(page['items'][-1]['is_me'])
        self.assertEqual(self.sync(user,100,2)[0],200)
        self.assert_error(self.request('GET','/v1/leaderboard?'+urlencode({'limit':7,'cursor':own['page_cursor']}),token=user['token']),409,'leaderboard_changed')
        indexes = self.database.execute("SELECT count(*) FROM pg_indexes WHERE schemaname=? AND indexname IN ('daily_steps_date_steps_user','users_shared_id','circle_enabled_user')",(self.database.schema,)).fetchone()[0]
        self.assertEqual(indexes,3)

if __name__ == '__main__':
    unittest.main()
