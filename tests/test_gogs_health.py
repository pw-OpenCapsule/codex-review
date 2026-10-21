import json,os,subprocess,sys,tempfile,threading,time,unittest
from pathlib import Path
from unittest.mock import Mock,patch
import requests
from pr_review.hosts import same_gogs_host
from pr_review.service import Gogs,Store,Worker,server

HELPER=Path(__file__).resolve().parents[1]/'pr_review'/'credential_helper.py'
ALIASES=['sg-git-src.pwtk.cc','sg-git.pwtk.cc','sg-cy-git.caminonode.com','sg-git.port888.com']

def worker(cfg=None,ok_age=0):
 w=object.__new__(Worker);w.cfg=cfg or {};w.last_gogs_ok=time.time()-ok_age;w.last_error=None;w.last_error_at=None
 return w

class HostAliasTests(unittest.TestCase):
 def test_same_gogs_aliases_match_each_other(self):
  for a in ALIASES:
   for b in ALIASES:self.assertTrue(same_gogs_host(a,b),(a,b))
 def test_other_gogs_still_mismatch(self):
  self.assertTrue(same_gogs_host('git.example.com','git.example.com'))
  for a in ALIASES:
   self.assertFalse(same_gogs_host(a,'git.example.com'));self.assertFalse(same_gogs_host('git.example.com',a))
  self.assertFalse(same_gogs_host('sg-git.pwtk.cc:8443','sg-git-src.pwtk.cc'))
 def test_login_accepts_old_credential_host_for_new_origin(self):
  with tempfile.TemporaryDirectory() as d:
   f=Path(d)/'cred.json';f.write_text(json.dumps({'host':'sg-git.pwtk.cc','username':'robot','token':'t'}))
   with patch('pr_review.service.requests.Session') as S:
    S.return_value.headers={};S.return_value.get.return_value.json.return_value={'username':'robot'}
    g=Gogs('https://sg-git-src.pwtk.cc',str(f))
    self.assertEqual(g.username,'robot');S.return_value.get.assert_called_once_with('https://sg-git-src.pwtk.cc/api/v1/user',timeout=30)
    f.write_text(json.dumps({'host':'git.example.com','username':'robot','token':'t'}))
    with self.assertRaisesRegex(ValueError,'credential host mismatch'):Gogs('https://sg-git-src.pwtk.cc',str(f))
 def helper(self,cred_host,ask_host):
  with tempfile.TemporaryDirectory() as d:
   f=Path(d)/'cred.json';f.write_text(json.dumps({'host':cred_host,'username':'robot','token':'t'}))
   return subprocess.run([sys.executable,str(HELPER),'get'],input=f'protocol=https\nhost={ask_host}\n\n',text=True,
                         capture_output=True,check=True,env={**os.environ,'PR_REVIEW_CREDENTIALS_FILE':str(f)}).stdout
 def test_git_credential_helper_accepts_alias_only(self):
  self.assertEqual(self.helper('sg-git.pwtk.cc','sg-git-src.pwtk.cc'),'username=robot\npassword=t\n')
  self.assertEqual(self.helper('sg-git-src.pwtk.cc','sg-cy-git.caminonode.com'),'username=robot\npassword=t\n')
  self.assertEqual(self.helper('sg-git.pwtk.cc','git.example.com'),'')

class HealthTests(unittest.TestCase):
 def test_fresh_start_is_healthy(self):
  code,state=worker({'poll_seconds':120}).health()
  self.assertEqual(code,200);self.assertEqual(state['status'],'ok');self.assertEqual(state['stale_after_seconds'],900)
 def test_stale_discovery_is_503_with_last_error(self):
  w=worker({'poll_seconds':120},ok_age=901);w.last_error='ConnectTimeout';w.last_error_at=time.time()
  code,state=w.health()
  self.assertEqual(code,503);self.assertEqual(state['status'],'stale');self.assertEqual(state['last_error'],'ConnectTimeout')
  self.assertRegex(state['last_success'],r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$');self.assertIsNotNone(state['last_error_at'])
 def test_threshold_follows_config(self):
  self.assertEqual(worker({'poll_seconds':600},ok_age=1700).health()[0],200)
  self.assertEqual(worker({'poll_seconds':600},ok_age=1801).health()[0],503)
  self.assertEqual(worker({'health_stale_seconds':60},ok_age=61).health()[0],503)
 def test_discovery_success_and_failure_are_recorded(self):
  w=worker(ok_age=5000);w.gogs=Mock();w.gogs.open_prs.return_value=[3];w.store=Mock()
  w.process(0);self.assertEqual(w.health()[0],200);w.store.enqueue.assert_called_once_with(3)
  w=worker(ok_age=5000);w.gogs=Mock();w.gogs.open_prs.side_effect=requests.ConnectTimeout()
  w.store=Mock();w.store.pop.side_effect=[0,KeyboardInterrupt()];w.store.retry_jobs.return_value=[]
  with patch('pr_review.service.time.sleep'),self.assertRaises(KeyboardInterrupt):w.loop()
  code,state=w.health();self.assertEqual((code,state['last_error']),(503,'ConnectTimeout'))
 def test_http_health_reports_state(self):
  with tempfile.TemporaryDirectory() as d:
   w=worker(ok_age=5000);w.last_error='CalledProcessError';w.last_error_at=time.time()
   srv=server({'webhook_secret':'s','port':0},Store(Path(d)/'state'),None,w.health)
   thread=threading.Thread(target=srv.serve_forever);thread.start()
   try:
    r=requests.get(f'http://127.0.0.1:{srv.server_port}/health',timeout=2)
    self.assertEqual(r.status_code,503);self.assertEqual(r.json()['last_error'],'CalledProcessError')
    w.last_gogs_ok=time.time();self.assertEqual(requests.get(f'http://127.0.0.1:{srv.server_port}/health',timeout=2).status_code,200)
    self.assertEqual(requests.get(f'http://127.0.0.1:{srv.server_port}/other',timeout=2).status_code,404)
   finally:srv.shutdown();thread.join();srv.server_close()
