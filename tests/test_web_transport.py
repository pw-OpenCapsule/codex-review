import json,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from pr_review.web_transport import send,result_of,WebUnavailable
class WebTransportTests(unittest.TestCase):
 def test_failures_never_clean_pass(self):
  for status in ('busy','unavailable','incomplete','schema_violation','cancelled','submission_unknown'):
   with self.assertRaises(WebUnavailable):result_of({'status':status,'result':{'issues':[]}})
 def test_duplicate_resumes_without_resubmitting(self):
  calls=[]
  def run(cmd,**kwargs):
   calls.append(cmd);return SimpleNamespace(stdout=json.dumps({'status':'duplicate'} if len(calls)==1 else {'status':'completed','result':{'issues':[]}}))
  with tempfile.TemporaryDirectory() as d:
   out=Path(d)/'result';a=send('web','prompt',{},out,0,'instant',20,runner=run)
   self.assertEqual(a[0],{'issues':[]});self.assertEqual([c[1] for c in calls],['ask','resume'])
   send('web','prompt',{},out,0,'instant',20,runner=run);self.assertEqual(len(calls),2)
 def test_busy_does_not_retry_or_switch_identity(self):
  calls=[]
  def run(cmd,**kwargs):calls.append(cmd);return SimpleNamespace(stdout='{"status":"busy"}')
  with tempfile.TemporaryDirectory() as d:
   with self.assertRaises(WebUnavailable):send('web','p',{},Path(d)/'o',0,'instant',20,runner=run)
  self.assertEqual(len(calls),1);self.assertIn('--busy',calls[0])
