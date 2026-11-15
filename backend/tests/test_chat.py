"""Real Rust + PostgreSQL + verified email accounts; no fake chat server."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from urllib.parse import urlencode
import unittest
import uuid
from backend.tests import test_email_auth as auth

PATH = '/v1/circles/current/messages'
CIRCLE = '2026-11-14:0-999'

class CircleChatTests(unittest.TestCase):
    setUp = auth.EmailAuthTests.setUp
    def start(self, *, email_only=True, environment=None):
        from backend.tests.pg_fixture import RustServer
        self.server = RustServer(self.database, lambda: self.now, email_only=email_only,
            mail_environment=self.capture.environment if environment is None else environment,
            pool_environment={'STAIRCLIMB_TEST_CHAT':'1'})
    request = auth.EmailAuthTests.request
    post = auth.EmailAuthTests.post
    register = auth.EmailAuthTests.register
    login = auth.EmailAuthTests.login
    verified = auth.EmailAuthTests.verified
    error = auth.EmailAuthTests.error

    def member(self, name):
        session = self.verified(name+'@example.test')
        token = session['token']
        self.assertEqual(self.request('PUT','/v1/me/sharing',{'enabled':True,'expected_revision':0},token)[0],200)
        self.assertEqual(self.request('PUT','/v1/me/circle-participation',{'enabled':True,'expected_revision':1},token)[0],200)
        return session

    def send(self, session, text='一起加油！', reply=None, client=None, circle=CIRCLE):
        return self.request('POST',PATH,{'circle_id':circle,'text':text,'reply_to':reply,'client_id':client or str(uuid.uuid4())},session['token'])

    def messages(self, session, **params):
        return self.request('GET', PATH+'?'+urlencode(dict(circle_id=CIRCLE,**params)),token=session['token'])

    def test_two_members_exchange_reply_retract_and_poll_changes(self):
        a,b = self.member('alice'),self.member('bob')
        status,sent = self.send(a,'今天走了800步，大家加油！')
        self.assertEqual(status,201,sent)
        first = sent['chat_message']
        result = self.messages(b)[1]
        self.assertEqual(result['messages'][0]['text'],first['text'])
        self.assertFalse(result['messages'][0]['is_me'])
        self.assertFalse({'email','token','refresh_token','password'} & result['messages'][0].keys())
        status,reply = self.send(b,'继续走，下一层见！',first['id'])
        self.assertEqual(status,201,reply)
        self.assertEqual(reply['chat_message']['reply_to'],first['id'])
        changes = self.messages(a,after=result['watermark'])[1]
        self.assertEqual([m['id'] for m in changes['messages']],[reply['chat_message']['id']])
        self.error(self.request('DELETE',PATH,{'circle_id':CIRCLE,'message_id':first['id']},b['token']),404,'message_unavailable')
        deleted = self.request('DELETE',PATH,{'circle_id':CIRCLE,'message_id':first['id']},a['token'])
        self.assertEqual(deleted[0],200,deleted)
        self.assertTrue(deleted[1]['chat_message']['deleted'])
        self.assertEqual(deleted[1]['chat_message']['text'],'')
        updates = self.messages(b,after=changes['watermark'])[1]
        self.assertEqual(len(updates['messages']),1)
        self.assertTrue(updates['messages'][0]['deleted'])
        self.error(self.send(b,reply=first['id']),404,'message_unavailable')

    def test_membership_migration_midnight_withdrawal_and_unverified_access(self):
        self.now = self.now.replace(hour=15, minute=59, second=50)
        a,b = self.member('alice'),self.member('bob')
        message = self.send(a)[1]['chat_message']
        outsider = self.verified('outsider@example.test')
        self.error(self.messages(outsider),403,'circle_required')
        self.error(self.request('GET',PATH+'?'+urlencode({'circle_id':'other'}),token=a['token']),409,'circle_changed')
        self.assertEqual(self.request('PUT','/v1/me/steps',{'date':'2026-11-14','steps':1000,'expected_revision':2},b['token'])[0],200)
        self.error(self.messages(b),409,'circle_changed')
        self.error(self.send(b),409,'circle_changed')
        self.error(self.send(b,reply=message['id'],circle='2026-11-14:1000-1999'),404,'message_unavailable')
        self.assertEqual(self.request('PUT','/v1/me/sharing',{'enabled':False,'expected_revision':2},a['token'])[0],200)
        self.error(self.messages(a),403,'circle_required')
        self.error(self.send(a),403,'circle_required')
        self.now += timedelta(seconds=11)
        self.error(self.send(b),409,'circle_changed')
        self.assertEqual(self.send(b,circle='2026-11-15:0-999')[0],201)
        # Mail registration without verification never grants a session/channel access.
        proof = self.register('pending@example.test')
        self.error(self.request('GET',PATH+'?'+urlencode({'circle_id':'2026-11-15:0-999'}),token=proof),401,'unauthorized')

    def test_report_block_both_directions_unblock_and_private_list(self):
        a,b = self.member('alice'),self.member('bob')
        msg = self.send(a)[1]['chat_message']
        endpoint = '/v1/circles/current/'
        for _ in range(2):
            self.assertEqual(self.request('POST',endpoint+'reports',{'circle_id':CIRCLE,'message_id':msg['id'],'reason':'abuse'},b['token'])[0],200)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM circle_reports').fetchone()[0],1)
        block={'circle_id':CIRCLE,'user_id':a['user']['id'],'enabled':True}
        self.assertEqual(self.request('PUT',endpoint+'blocks',block,b['token'])[0],200)
        self.assertEqual(self.messages(b)[1]['messages'],[])
        self.assertEqual(self.send(b)[0],201)
        self.assertEqual(len(self.messages(a)[1]['messages']),1)
        self.error(self.send(b,reply=msg['id']),404,'message_unavailable')
        listed=self.request('GET',endpoint+'blocks?'+urlencode({'circle_id':CIRCLE}),token=b['token'])[1]['blocked_users']
        self.assertEqual(listed,[{'user_id':a['user']['id'],'nickname':'小楼'}])
        self.assertEqual(self.request('GET',endpoint+'blocks?'+urlencode({'circle_id':CIRCLE}),token=a['token'])[1]['blocked_users'],[])
        block['enabled']=False
        self.assertEqual(self.request('PUT',endpoint+'blocks',block,b['token'])[0],200)
        self.assertEqual(len(self.messages(b)[1]['messages']),2)
        self.assertEqual(self.request('PUT','/v1/me/sharing',{'enabled':False,'expected_revision':2},a['token'])[0],200)
        self.assertEqual(len(self.messages(b)[1]['messages']),1)
        self.assertEqual(self.request('DELETE','/v1/me',{'expected_revision':3},a['token'])[0],200)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM circle_reports').fetchone()[0],0)

    def test_idempotent_concurrent_send_validation_and_rate_limit(self):
        a=self.member('alice')
        key=str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda _:self.send(a,client=key),range(2)))
        self.assertEqual(sorted(r[0] for r in results),[200,201],results)
        self.assertEqual(results[0][1]['chat_message']['id'],results[1][1]['chat_message']['id'])
        self.error(self.send(a,'changed',client=key),409,'message_conflict')
        for text in ['', '  ', '楼'*1001, 'bad\x00text']:
            self.error(self.send(a,text),422,'invalid_chat')
        self.error(self.send(a,client='not-uuid'),422,'invalid_chat')
        for _ in range(4): self.assertEqual(self.send(a)[0],201)
        self.error(self.send(a),429,'chat_rate_limited')
        self.assertEqual(self.send(a,client=key)[0],200) # A safe retry is not throttled.
        self.now += timedelta(seconds=11)
        self.assertEqual(self.send(a,'楼'*1000)[0],201)

    def test_keyset_pages_changes_and_strict_query(self):
        a=self.member('alice')
        ids=[]
        for i in range(25):
            self.now += timedelta(seconds=11)
            response=self.send(a,str(i));self.assertEqual(response[0],201,response)
            ids.append(response[1]['chat_message']['id'])
        latest=self.messages(a,limit=10)[1]
        self.assertEqual([m['id'] for m in latest['messages']],ids[-10:])
        older=self.messages(a,limit=10,before=latest['next_before'])[1]
        oldest=self.messages(a,limit=10,before=older['next_before'])[1]
        self.assertEqual([m['id'] for m in oldest['messages']+older['messages']+latest['messages']],ids)
        self.assertIsNone(oldest['next_before'])
        first=self.messages(a,limit=10,after=1)[1]
        self.assertTrue(first['has_more'])
        second=self.messages(a,limit=50,after=first['watermark'])[1]
        self.assertFalse(second['has_more'])
        self.assertEqual(len(first['messages']+second['messages']),24)
        for params in [{'limit':0},{'limit':51},{'before':'nope'},{'before':1,'after':1}]:
            self.error(self.messages(a,**params),422,'invalid_chat')
        self.error(self.messages(a,user_id=a['user']['id']),400,'invalid_query')

    def test_waiting_send_rechecks_revoked_session_and_daily_boundary(self):
        self.now = self.now.replace(hour=15, minute=59, second=50)
        a=self.member('alice')
        with ThreadPoolExecutor(max_workers=1) as pool:
            with self.database.write_lock(a['user']['id']):
                future=pool.submit(self.send,a)
                self.database.wait_for_blocked_writer()
                self.database.execute('DELETE FROM sessions')
            self.error(future.result(),401,'unauthorized')
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM circle_messages').fetchone()[0],0)
        a=self.login('alice@example.test')
        with ThreadPoolExecutor(max_workers=1) as pool:
            with self.database.write_lock(a['user']['id']):
                future=pool.submit(self.send,a)
                self.database.wait_for_blocked_writer()
                self.now += timedelta(seconds=11)
                self.server.set_time(self.now)
            self.error(future.result(),409,'circle_changed')
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM circle_messages').fetchone()[0],0)

    def test_chat_disabled_by_default_and_release_cannot_enable_it(self):
        from backend.tests.pg_fixture import RustServer
        self.server.close()
        for production, environment in [(False, {}), (True, {'STAIRCLIMB_TEST_CHAT':'1'})]:
            self.server = RustServer(self.database, lambda: self.now, production=production,
                pool_environment=environment)
            # The fixture release binary is compiled with test-support, so release safety
            # additionally rejects the flag unless the dedicated test server opts in.
            for method,path in [('GET',PATH),('POST',PATH),('DELETE',PATH),
                                ('POST','/v1/circles/current/reports'),
                                ('GET','/v1/circles/current/blocks'),('PUT','/v1/circles/current/blocks')]:
                self.error(self.request(method,path,{}),503,'chat_disabled')
            self.assertEqual(self.request('GET','/health')[0],200)
            self.server.close()

if __name__=='__main__': unittest.main()
