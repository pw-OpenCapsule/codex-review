import json,sqlite3,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch
from pr_review.protocol import effective_config,declaration
from pr_review.reuse import cache_key,policy_digest,stable_remaining
from pr_review.service import Store,Worker

class ReuseTests(unittest.TestCase):
 def test_identity_cannot_cross_project_source_or_policy(self):
  args=['repo','head','merge','policy'];key=cache_key(*args)
  for i in range(4):
   changed=args.copy();changed[i]+='changed';self.assertNotEqual(key,cache_key(*changed))
 def test_policy_tracks_model(self):
  self.assertNotEqual(policy_digest({'model':'a'}),policy_digest({'model':'b'}))
 def test_repeated_event_does_not_extend_settle_but_new_head_does(self):
  s,left=stable_remaining(None,'h',100,60);self.assertEqual(left,60)
  self.assertEqual(stable_remaining(s,'h',140,60)[1],20)
  self.assertEqual(stable_remaining(s,'new',140,60)[1],60)
 def test_migrates_old_queue_and_defers_without_losing_close(self):
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'state';c=sqlite3.connect(path);c.execute('CREATE TABLE events(pr INTEGER PRIMARY KEY)');c.execute('INSERT INTO events VALUES(2)');c.commit();c.close()
   s=Store(path);self.assertEqual(s.pop(),2)
   with patch('pr_review.service.time.time',return_value=100):s.enqueue(3,60);self.assertIsNone(s.pop())
   with patch('pr_review.service.time.time',return_value=161):self.assertEqual(s.pop(),3)
   s.enqueue(4,60);s.cancel_pr(4);self.assertIsNone(s.pop())
 def test_cached_result_does_not_start_model_and_keeps_new_job_identity(self):
  with tempfile.TemporaryDirectory() as d:
   w=object.__new__(Worker);w.cfg={'state_dir':d,'settle_seconds':0};w.store=Store(Path(d)/'state');w.child=None
   w.gogs=Mock();w.gogs.page.return_value={'closed':False,'author':'a'};w.refs=Mock(return_value=('head','target2'))
   w.mirror=Path(d)/'mirror';w.kill_child=Mock()
   from pr_review.service import REPO
   key=cache_key(REPO,'head','merge',policy_digest(effective_config(w.cfg,declaration(""))));p=Path(d)/'cache'/key;p.mkdir(parents=True)
   (p/'review.json').write_text(json.dumps({'issues':[],'model':'gpt-5.3-codex-spark','usage_by_stage':{'spark':{'usage':123}}}))
   with patch('pr_review.service.git',return_value='merge'),patch('pr_review.service.subprocess.Popen') as model:
    w.process(9)
   model.assert_not_called();j=w.store.job(9,'head','target2');r=json.loads(j['result'])
   self.assertEqual(j['status'],'ready');self.assertTrue(r['cache']['hit']);self.assertEqual(r['usage_by_stage'],{})
   self.assertIn('spark',r['cached_usage_by_stage'])

 def test_failed_scope_is_not_restarted_by_another_target(self):
  with tempfile.TemporaryDirectory() as d:
   w=object.__new__(Worker);w.cfg={'state_dir':d,'settle_seconds':0};w.store=Store(Path(d)/'state');w.child=None
   w.gogs=Mock();w.gogs.page.return_value={'closed':False};w.refs=Mock(return_value=('head','newtarget'));w.mirror=Path(d)/'mirror';w.kill_child=Mock()
   from pr_review.service import REPO
   key=cache_key(REPO,'head','merge',policy_digest(effective_config(w.cfg,declaration(""))));p=Path(d)/'cache'/key;p.mkdir(parents=True);(p/'failure.json').write_text('{}')
   with patch('pr_review.service.git',return_value='merge'),patch('pr_review.service.subprocess.Popen') as model:w.process(9)
   model.assert_not_called();self.assertEqual(w.store.job(9,'head','newtarget')['status'],'failed')
