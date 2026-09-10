import subprocess,tempfile,unittest
from pathlib import Path
from pr_review.review_tools import execute,review_loop
from pr_review.budget import ReviewBudgetExceeded
class ToolTests(unittest.TestCase):
 def test_search_and_base_head_read(self):
  with tempfile.TemporaryDirectory() as d:
   def git(*a):return subprocess.check_output(['git','-C',d,*a],text=True,stderr=subprocess.DEVNULL).strip()
   git('init');git('config','user.name','Test');git('config','user.email','test@example.com')
   p=Path(d)/'logic.py';p.write_text('def target(): return 1\n');git('add','.');git('commit','-m','base');base=git('rev-parse','HEAD')
   p.write_text('def target(): return 2\ntarget()\n');git('commit','-am','head');head=git('rev-parse','HEAD')
   call={'name':'search_code','path':'','query':'target','revision':'head','start_line':1,'end_line':2}
   self.assertIn('logic.py:2:target()',execute(d,base,head,call)['content'])
   self.assertIn('return 1',execute(d,base,head,{**call,'name':'git_show','path':'logic.py','revision':'base'})['content'])
   for change in ({'path':'../secret'},{'name':'bash'},{'end_line':9999}):
    with self.assertRaises(ValueError):execute(d,base,head,{**call,**change})
 def test_model_selects_tools_then_finishes(self):
  seen=[]
  def turn(obs):
   seen.append(obs)
   return ({'decision':'tools','tool_calls':[{'name':'search_code','path':'src'}]} if len(seen)==1 else {'decision':'complete','issues':[]}),None
  result,_=review_loop(turn,lambda c:{'content':'caller found'})
  self.assertIn('caller found',seen[1]);self.assertEqual(result['tools_used'][0]['name'],'search_code')
 def test_budget_is_not_clean_pass(self):
  with self.assertRaises(ReviewBudgetExceeded):review_loop(lambda x:({'decision':'tools','tool_calls':[{'name':'list_files'}]},None),lambda c:{},max_rounds=2)
