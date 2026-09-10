import unittest,json
from pr_review.failures import classify
from pr_review.progress import progress_body
class FailureTests(unittest.TestCase):
 def test_reasons_are_distinct(self):
  cases={'insufficient focused context; manual review required':'context_insufficient',"You've hit your usage limit":'quota_exhausted','Codex ran out of room in the model context window':'context_window_exceeded','context-work token budget exceeded':'token_budget','stage time budget exceeded':'time_limit','focused review round budget exceeded':'context_read_limit'}
  for raw,code in cases.items():self.assertEqual(classify(raw)['reason_code'],code)
 def test_no_raw_secrets_in_public_reason(self):
  self.assertNotIn('private-secret',json.dumps(classify('provider error: private-secret')))
 def test_context_failure_visible_in_comment(self):
  text=progress_body({'status':'failed','result':json.dumps(classify('insufficient focused context'))})
  self.assertIn('代码片段不足',text);self.assertIn('context_insufficient',text)
