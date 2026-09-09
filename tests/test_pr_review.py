import hashlib,hmac,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch,Mock
import threading,requests
from bs4 import BeautifulSoup
from pr_review.service import Store,event_pr,signature_ok,validate_review,parse_pr,send_lark,Worker,render,Gogs,server,save_pr_metadata

class ReviewTests(unittest.TestCase):
 def setUp(self):
  self.repo_patch=patch("pr_review.service.REPO","games/aeroplane");self.repo_patch.start();self.addCleanup(self.repo_patch.stop)
 def test_signature_requires_exact_body(self):
  b=b'{"x":1}'; sig=hmac.new(b'secret',b,hashlib.sha256).hexdigest()
  self.assertTrue(signature_ok('secret',b,sig));self.assertFalse(signature_ok('secret',b+b' ',sig));self.assertFalse(signature_ok('',b,sig))
 def test_events_allowlist(self):
  p={'repository':{'full_name':'games/aeroplane'},'number':31,'action':'synchronized'}
  self.assertEqual(event_pr('pull_request',p),31)
  for action in ['closed','edited','assigned']:
   p['action']=action;self.assertIsNone(event_pr('pull_request',p))
  p['repository']['full_name']='other/repo';self.assertIsNone(event_pr('push',p))
 def test_queue_restart_and_dedup(self):
  with tempfile.TemporaryDirectory() as d:
   s=Store(Path(d)/'state');s.enqueue(31);s.enqueue(31)
   s=Store(Path(d)/'state');self.assertEqual(s.pop(),31);self.assertIsNone(s.pop())
   a=s.job(31,'a'*40,'b'*40);s.update(a['key'],status='ready',result='{}')
   self.assertEqual(s.job(31,'a'*40,'b'*40)['status'],'ready')
   self.assertNotEqual(s.job(31,'c'*40,'b'*40)['key'],a['key'])
   self.assertNotEqual(s.job(31,'a'*40,'c'*40)['key'],a['key'])
 def test_invalid_output_is_not_clean_review(self):
  for p in [{},None,{'issues':'none'},{'issues':[{'severity':'P0'}]}]:
   with self.assertRaises(ValueError):validate_review(p)
  self.assertEqual(validate_review({'issues':[]}),{'issues':[]})
 def test_parse_branches_and_reject_foreign(self):
  h='<div class="column title"><div class="label"><i class="octicon-issue-opened"></i>Open</div></div><h1>Closed bug fix</h1><span class="pull-desc"><code>games/feat/x</code><code>games/test</code></span>'
  p=parse_pr(h,'https://git.example',31);self.assertEqual((p['head'],p['base']),('feat/x','test'));self.assertFalse(p['closed'])
  with self.assertRaises(ValueError):parse_pr(h.replace('games/feat','fork/feat'),'https://git.example',31)
  with self.assertRaises(ValueError):parse_pr(h.replace('feat/x','--bad'),'https://git.example',31)
 def test_lark_http200_error_is_failure(self):
  r=Mock();r.json.return_value={'code':19001}
  with patch('pr_review.service.requests.post',return_value=r):
   with self.assertRaises(ValueError):send_lark('https://example','test')
 def test_stale_review_never_published(self):
  w=object.__new__(Worker);w.gogs=Mock();w.gogs.page.return_value={'closed':False};w.refs=lambda _:('new','base');w.store=Mock()
  w.publish({'pr':31,'head':'old','base':'base','key':'k'})
  w.gogs.comment.assert_not_called();w.store.update.assert_called_once_with('k',status='stale',notified=1)
 def test_zero_findings_does_not_notify_or_duplicate_comment(self):
  w=object.__new__(Worker);w.gogs=Mock();w.gogs.page.return_value={'closed':False,'title':'PR'};w.refs=lambda _:('a','b');w.store=Mock();w.cfg={'lark_webhook':'https://example'}
  with patch('pr_review.service.send_lark') as send:
   w.publish({'pr':31,'head':'a','base':'b','key':'k','result':'{"issues":[]}','comment_url':'https://git/31#c'})
  w.gogs.comment.assert_not_called();send.assert_not_called()
 def test_failed_review_has_no_pass_claim(self):
  _,body=render({},dict(key='k',head='a',base='b'),{'error':'timeout'})
  self.assertIn('评审失败',body);self.assertNotIn('未发现明确缺陷',body);self.assertNotIn('/review-resolve',body);self.assertNotIn('/review-approve',body)

 def test_comment_permalink_keeps_pr_path(self):
  c=object.__new__(Gogs);c.origin='https://git.example';c.session=Mock()
  p={'url':'https://git.example/example/project/pulls/31','soup':BeautifulSoup('<div class="comment"><a href="#issuecomment-9">time</a>review-id:k:complete</div>','html.parser')}
  c.page=lambda n:p
  self.assertEqual(c.comment(31,'review-id:k:complete','body'),p['url']+'#issuecomment-9')
  c.session.post.assert_not_called()
 def test_failure_and_success_comment_markers_differ(self):
  job={'key':'k','head':'a','base':'b'}
  self.assertNotEqual(render({},job,{'error':'timeout'})[0],render({},job,{'issues':[]})[0])
 def test_real_http_signature_and_duplicate_delivery(self):
  with tempfile.TemporaryDirectory() as d:
   st=Store(Path(d)/'state');srv=server({'webhook_secret':'secret','port':0},st)
   thread=threading.Thread(target=srv.serve_forever);thread.start()
   try:
    url=f'http://127.0.0.1:{srv.server_port}/hooks/gogs'
    body=json.dumps({'repository':{'full_name':'games/aeroplane'},'action':'opened','number':31}).encode()
    sig=hmac.new(b'secret',body,hashlib.sha256).hexdigest()
    self.assertEqual(requests.post(url,data=body,timeout=2).status_code,403)
    for _ in range(2):self.assertEqual(requests.post(url,data=body,headers={'X-Gogs-Signature':sig,'X-Gogs-Event':'pull_request'},timeout=2).status_code,202)
    self.assertEqual(st.pop(),31);self.assertIsNone(st.pop())
   finally:srv.shutdown();thread.join();srv.server_close()

 def test_robot_api_comment_does_not_reuse_human_marker(self):
  c=object.__new__(Gogs);c.credentials_file='private';c.origin='https://git.example';c.username='robot';c.session=Mock()
  c.comments=lambda n:[{'id':1,'body':'marker','user':{'username':'author'}}]
  c.page=lambda n:{'closed':False};c.session.post.return_value.json.return_value={'id':2}
  url=c.comment(31,'marker','body')
  self.assertEqual(url,'https://git.example/games/aeroplane/pulls/31#issuecomment-2')
  c.session.post.assert_called_once()
 def test_signed_webhook_metadata_supplies_missing_gogs_pr_api_fields(self):
  with tempfile.TemporaryDirectory() as d:
   st=Store(Path(d)/'state')
   save_pr_metadata({'repository':{'full_name':'games/aeroplane'},'pull_request':{'number':31,'head_branch':'feat/x','base_branch':'test','head_repo':{'full_name':'games/aeroplane'},'base_repo':{'full_name':'games/aeroplane'}}},st)
   self.assertEqual(st.meta('pr_refs:31')['head'],'feat/x')

if __name__=='__main__':unittest.main()
