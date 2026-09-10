import json,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch
from pr_review.protocol import declaration,effective_config,job_key,marker
from pr_review.service import Store,Worker
class ProtocolTests(unittest.TestCase):
 def test_levels_and_legacy(self):
  for level in ('none','spark','deep'):
   self.assertEqual(declaration(f'[review:{level}] 理由'),{'level':level,'reason':'理由','valid':True})
  self.assertEqual(declaration('[no-review] 理由')['level'],'none')
 def test_quotes_code_and_comments_are_not_declarations(self):
  for body in ('> [review:none] 理由','```\n[review:none] 理由\n```','    [review:none] 理由','<!-- [review:none] 理由 -->','说明 [review:none] 理由'):
   self.assertEqual(declaration(body),declaration(''))
 def test_invalid_never_becomes_skip(self):
  for body in ('[review:none]','[review:other] reason','[review:none] a\n[review:deep] b'):
   self.assertFalse(declaration(body)['valid'])
 def test_policy_change_invalidates_confirmation(self):
  a=declaration('[review:spark] a');b=declaration('[review:none] b')
  self.assertNotEqual(job_key('r',1,'h','b',a),job_key('r',1,'h','b',b))
 def test_direct_deep_configuration(self):
  self.assertEqual(effective_config({},declaration('[review:deep] a'))['routing'],'fixed')
  self.assertEqual(effective_config({},declaration(''))['routing'],'fixed')
  self.assertEqual(effective_config({'routing':'complexity'},declaration(''))['model'],'gpt-5.3-codex-spark')
  self.assertEqual(effective_config({},declaration('[review:deep] a'))['model'],'gpt-6-astra')
 def test_unavailable_is_not_zero_findings_pass(self):
  text=marker({'status':'failed'},'h');self.assertIn('"status":"unavailable"',text);self.assertIn('"findings":null',text)
 def test_none_and_invalid_do_not_start_models(self):
  for body,status in (('[review:none] docs','skipped'),('[review:bad] reason','invalid')):
   with tempfile.TemporaryDirectory() as d:
    w=object.__new__(Worker);w.cfg={'state_dir':d};w.store=Store(Path(d)/'state');w.gogs=Mock();w.gogs.page.return_value={'closed':False,'body':body};w.refs=lambda p:('h','b')
    with patch('pr_review.service.subprocess.Popen') as run:w.process(1)
    run.assert_not_called();self.assertEqual(w.store.job(1,'h','b',declaration(body))['status'],status)
 def test_manual_fallback_requires_two_distinct_humans(self):
  from pr_review.gate import evaluate
  job={'key':'k','status':'skipped','result':'{}','declaration':declaration('[review:none] docs')}
  def comment(i,user,body):return {'id':i,'user':{'username':user},'created_at':f'2026-09-09T10:00:0{i}+00:00','body':body}
  comments=[comment(1,'robot',marker(job,'h')),comment(2,'author','/review-resolve k')]
  self.assertFalse(evaluate(job,comments,'author',['author','maintainer'],'robot')['allowed'])
  comments.append(comment(3,'maintainer','/review-approve k 已人工核对本次改动'))
  self.assertTrue(evaluate(job,comments,'author',['maintainer'],'robot')['allowed'])
 def test_skipped_is_not_complete(self):
  self.assertIn('"status":"skipped"',marker({'status':'skipped'},'h'))
  self.assertIn('"findings":null',marker({'status':'skipped'},'h'))
