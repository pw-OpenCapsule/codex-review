import unittest
from unittest.mock import patch
from pr_review.auto_merge import eligibility,dispatch
class AutoMergeTests(unittest.TestCase):
 def test_none_only(self):
  for level in ('spark','deep'):
   self.assertFalse(eligibility({'valid':True,'level':level},'a',['a'],[],'robot',False)[0])
 def test_explicit_none_and_blockers(self):
  d={'valid':True,'level':'none'}
  self.assertTrue(eligibility(d,'a',['a'],[],'robot',False)[0])
  self.assertFalse(eligibility(d,'a',['a'],[],'robot',True)[0])
  self.assertFalse(eligibility(d,'a',[],[],'robot',False)[0])
  self.assertFalse(eligibility(d,'a',['a'],[{'user':{'username':'person'},'body':'please check'}],'robot',False)[0])
 def test_disabled_or_wrong_identity_never_dispatches(self):
  with patch('pr_review.auto_merge.subprocess.run') as run:
   self.assertEqual(dispatch({},{} )['status'],'disabled')
   self.assertEqual(dispatch({'enabled':True,'identity':'human'},{} )['status'],'blocked')
   run.assert_not_called()
