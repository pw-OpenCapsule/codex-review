import unittest,tempfile,json,hashlib
from pathlib import Path
from unittest.mock import Mock,patch
from pr_review.progress import progress_body
from pr_review.service import Gogs,Store,Worker

class ProgressTests(unittest.TestCase):
 def test_queued_and_running_are_distinct(self):
  self.assertIn('已排队',progress_body(None,'a','b'))
  self.assertIn('评审中',progress_body({'status':'running'},'a','b'))
  self.assertIn('暂缓合并',progress_body(None,'a','b'))
 def test_clean_is_not_automatic_merge_permission(self):
  body=progress_body({'status':'ready','result':'{"issues":[]}','comment_url':'https://git/pr#c'},'a','b')
  self.assertIn('仍需人工检查与双人确认',body);self.assertIn('尚未被技术锁定',body)
 def test_ready_without_published_report_does_not_claim_done(self):
  self.assertIn('正在发布',progress_body({'status':'ready','result':'{"issues":[]}'},'a','b'))
 def test_failed_review_blocks_recommendation(self):
  self.assertIn('未完成',progress_body({'status':'failed'},'a','b'))
 def test_same_comment_is_edited_and_unchanged_body_is_not_reposted(self):
  g=object.__new__(Gogs);g.username='robot';g.origin='https://git';g.session=Mock()
  with patch('pr_review.service.REPO','games/aeroplane'):
   marker='<!-- pr-review-status:games/aeroplane:40 -->'
   g.comments=lambda n:[{'id':9,'user':{'username':'robot'},'body':'queued\n\n'+marker}]
   self.assertEqual(g.status_comment(40,'queued'),'https://git/games/aeroplane/pulls/40#issuecomment-9')
   g.session.patch.assert_not_called()
   g.status_comment(40,'completed');g.session.patch.assert_called_once();g.session.post.assert_not_called()
 def test_human_cannot_spoof_status_comment(self):
  g=object.__new__(Gogs);g.username='robot';g.origin='https://git';g.session=Mock();g.page=lambda n:{'closed':False};g.comment=Mock(return_value='new')
  with patch('pr_review.service.REPO','games/aeroplane'):
   g.comments=lambda n:[{'id':9,'user':{'username':'human'},'body':'<!-- pr-review-status:games/aeroplane:40 -->'}]
   self.assertEqual(g.status_comment(40,'queued'),'new');g.session.patch.assert_not_called();g.comment.assert_called_once()
 def test_new_revision_does_not_reuse_completed_old_status(self):
  with tempfile.TemporaryDirectory() as d,patch('pr_review.service.REPO','games/aeroplane'):
   w=object.__new__(Worker);w.store=Store(Path(d)/'state');j=w.store.job(40,'old','base');w.store.update(j['key'],status='ready',result='{"issues":[]}',comment_url='old-link')
   w.status_gogs=Mock();w.status_gogs.page.return_value={'closed':False};w.current_refs=lambda p:('new','base')
   with patch('pr_review.service.send_lark') as group,patch('pr_review.service.send_direct') as dm:
    w.sync_status(40);group.assert_not_called();dm.assert_not_called()
   body=w.status_gogs.status_comment.call_args.args[1];self.assertIn('已排队',body);self.assertIn('new',body);self.assertNotIn('old-link',body)
 def test_status_queue_is_independent_and_coalesces_events(self):
  with tempfile.TemporaryDirectory() as d:
   s=Store(Path(d)/'state');s.enqueue(1);s.enqueue_status(2);s.enqueue_status(2)
   self.assertEqual(s.pop_status(),2);self.assertIsNone(s.pop_status());self.assertEqual(s.pop(),1)

if __name__=='__main__':unittest.main()
