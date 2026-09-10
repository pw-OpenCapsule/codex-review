import unittest
from pr_review.gate import evaluate
from pr_review.protocol import marker
class AgentFallbackTests(unittest.TestCase):
 def setup_case(self):
  job={'key':'k','status':'failed','result':'{"error":"quota_exhausted"}'}
  def c(i,user,body):return {'id':i,'user':{'username':user},'body':body,'created_at':f'2026-09-10T10:00:0{i}+00:00'}
  return job,c,[c(1,'robot',marker(job,'h'))]
 def test_author_agent_can_decide_without_second_human(self):
  j,c,cs=self.setup_case();cs.append(c(2,'author','/review-agent-decide k merge 已核对测试与改动边界'))
  self.assertTrue(evaluate(j,cs,'author',[],'robot')['allowed'])
 def test_hold_and_unknown_identity_do_not_allow(self):
  for name,action in [('author','hold'),('outsider','merge')]:
   j,c,cs=self.setup_case();cs.append(c(2,name,f'/review-agent-decide k {action} 已核对测试与改动边界'))
   self.assertFalse(evaluate(j,cs,'author',[],'robot')['allowed'])
 def test_existing_defects_need_explicit_resolution(self):
  j,c,cs=self.setup_case();j['known_issues']=[{'severity':'P1'}]
  cs.append(c(2,'author','/review-agent-decide k merge 已核对测试与改动边界'))
  self.assertFalse(evaluate(j,cs,'author',[],'robot')['allowed'])
  cs.append(c(3,'author','/review-agent-decide k merge 已核对测试与改动边界\nF1 fixed 已修复并通过对应回归测试'))
  self.assertTrue(evaluate(j,cs,'author',[],'robot')['allowed'])
