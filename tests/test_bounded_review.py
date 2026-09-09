import unittest,tempfile,subprocess
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import Mock,patch
from pr_review.budget import Budget,ReviewBudgetExceeded,collect_bounded
from pr_review.service import Worker,Store,ReviewSuperseded

class BudgetTests(unittest.TestCase):
 def test_spark_cannot_use_tools(self):
  b=Budget(0,40000)
  with self.assertRaises(ReviewBudgetExceeded):b.observe('item/started',{'item':{'type':'commandExecution'}})
 def test_cache_counts_towards_context_work_limit(self):
  b=Budget(8,250000)
  with self.assertRaises(ReviewBudgetExceeded):b.observe('thread/tokenUsage/updated',{'tokenUsage':{'total':{'totalTokens':250001,'inputTokens':250000,'outputTokens':1,'cachedInputTokens':240000}}})
 def test_context_window_sentinel_is_not_consumed_tokens(self):
  Budget(0,40000).observe('thread/tokenUsage/updated',{'tokenUsage':{'total':{'totalTokens':258400,'inputTokens':0,'outputTokens':0}}})
 def test_deep_has_finite_tool_budget(self):
  b=Budget(8,250000)
  for _ in range(8):b.observe('item/started',{'item':{'type':'commandExecution'}})
  with self.assertRaises(ReviewBudgetExceeded):b.observe('item/started',{'item':{'type':'commandExecution'}})
 def test_complete_stream_and_usage(self):
  def event(m,p):return SimpleNamespace(method=m,payload=SimpleNamespace(model_dump=lambda **_:p))
  events=[event('thread/tokenUsage/updated',{'tokenUsage':{'total':{'totalTokens':12,'inputTokens':10,'outputTokens':2}}}),event('item/completed',{'item':{'type':'agentMessage','text':'{"issues":[]}','phase':'final_answer'}}),event('turn/completed',{'turn':{'status':'completed','error':None}})]
  h=Mock();h.stream.return_value=(x for x in events)
  text,usage=collect_bounded(h,0,40000,10)
  self.assertEqual(text,'{"issues":[]}');self.assertEqual(usage['total']['totalTokens'],12)
 def test_budget_interrupts_not_clean_pass(self):
  p={'tokenUsage':{'total':{'totalTokens':40001,'inputTokens':40000,'outputTokens':1}}}
  h=Mock();h.stream.return_value=iter([SimpleNamespace(method='thread/tokenUsage/updated',payload=SimpleNamespace(model_dump=lambda **_:p))])
  # Use a generator, as the real SDK stream supplies close().
  h.stream.return_value=(x for x in h.stream.return_value)
  with self.assertRaises(ReviewBudgetExceeded):collect_bounded(h,0,40000,10)
  h.interrupt.assert_called_once()

class CancellationTests(unittest.TestCase):
 def worker(self):
  w=object.__new__(Worker);w.cfg={};w.store=Mock();w.store.meta.return_value=False;w.child=Mock();w.child.communicate.side_effect=subprocess.TimeoutExpired('review',2);w.kill_child=Mock();w.gogs=Mock();w.current_refs=Mock(return_value=('head','base'));return w
 def test_close_webhook_interrupts_inflight(self):
  w=self.worker();w.store.meta.return_value=True
  with self.assertRaises(ReviewSuperseded):w.wait_for_review(40,'head','base')
  w.kill_child.assert_called_once();w.gogs.page.assert_not_called()
 def test_merged_pr_detected_without_webhook(self):
  w=self.worker();w.gogs.page.return_value={'closed':True}
  with patch('pr_review.service.time.monotonic',side_effect=[0,0,1,6]):
   with self.assertRaises(ReviewSuperseded):w.wait_for_review(40,'head','base')
  w.kill_child.assert_called_once()
 def test_new_revision_interrupts_old_review(self):
  w=self.worker();w.gogs.page.return_value={'closed':False};w.current_refs.return_value=('new','base')
  with patch('pr_review.service.time.monotonic',side_effect=[0,0,1,6]):
   with self.assertRaises(ReviewSuperseded):w.wait_for_review(40,'head','base')
 def test_cancel_queued_pr_keeps_completed_history(self):
  with tempfile.TemporaryDirectory() as d:
   s=Store(Path(d)/'state');old=s.job(40,'old','base');s.update(old['key'],status='ready',comment_url='published',notified=1)
   pending=s.job(40,'new','base');s.enqueue(40);s.cancel_pr(40)
   self.assertEqual(s.job(40,'new','base')['status'],'stale');self.assertIsNone(s.pop());self.assertEqual(s.job(40,'old','base')['status'],'ready')

if __name__=='__main__':unittest.main()
