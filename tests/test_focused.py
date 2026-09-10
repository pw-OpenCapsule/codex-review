import subprocess
import tempfile
import unittest
from pathlib import Path
from pr_review.focused import read_context, focused_review
from pr_review.budget import ReviewBudgetExceeded

class FocusedTests(unittest.TestCase):
 def test_only_bounded_tracked_source(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d)
   subprocess.run(['git','init',d],capture_output=True,check=True)
   (root/'source.py').write_text('first\nsecond\n')
   (root/'private.txt').write_text('private')
   subprocess.run(['git','add','source.py'],cwd=d,check=True)
   req={'file':'source.py','start_line':1,'end_line':2}
   self.assertEqual(read_context(d,req)['content'],'1: first\n2: second')
   for changes in ({'file':'../escape'},{'file':'private.txt'},{'end_line':161}):
    with self.assertRaises((ValueError,subprocess.CalledProcessError)):
     read_context(d,{**req,**changes})
 def test_context_then_complete(self):
  inputs=[]
  def turn(extra):
   inputs.append(extra)
   if len(inputs)==1:return {'decision':'need_context','requests':[{'file':'a'}]},None
   return {'decision':'complete','issues':[]},{'total':1}
  result,usage=focused_review(turn,lambda r:{'content':'source'})
  self.assertEqual(result,{'issues':[]})
  self.assertIn('source',inputs[1])
 def test_repeated_requests_stop_without_clean_pass(self):
  reads=[]
  def turn(extra):return {'decision':'need_context','requests':[{'file':'a'}]*3},None
  with self.assertRaises(ReviewBudgetExceeded):
   focused_review(turn,lambda r:reads.append(r))
  self.assertEqual(len(reads),8)

 def test_spark_incomplete_stops_after_two_rounds(self):
  calls=[]
  def turn(extra):
   calls.append(extra)
   return {'decision':'need_context','requests':[{'file':'a'}]},None
  with self.assertRaises(ReviewBudgetExceeded):focused_review(turn,lambda req:{'content':'a'},max_rounds=2,max_reads=3)
  self.assertEqual(len(calls),2)
