import unittest,tempfile,json,time
from pathlib import Path
from unittest.mock import Mock,patch
from pr_review.gate import evaluate
from pr_review.notifications import meaningful,read_people,fingerprints,digest_card
from pr_review.service import Worker,Store

class PolicyTests(unittest.TestCase):
 def test_low_priority_removed(self):
  self.assertEqual(meaningful({'issues':[{'severity':'P3'}]})['issues'],[])
  self.assertEqual(meaningful({'issues':[{'severity':'P2','confidence':.5}]})['issues'],[])
 def test_mapping_and_real_at_markup(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'people';p.write_text('Name@Email\tou_person1\tName\nwrong\tall\tbad\n')
   m=read_people(p);self.assertEqual(m,{'name@email':'ou_person1'})
   card=digest_card([({'title':'test','author':'Name@Email'},{'comment_url':'https://git/pr/1'},{'issues':[{'severity':'P1'}]})],m)
   self.assertIn('<at id=ou_person1></at>',json.dumps(card))
 def test_escalation_not_hidden(self):
  a={'file':'f','line':1,'severity':'P2','anchor':'same'}
  self.assertNotEqual(fingerprints({'issues':[a]}),fingerprints({'issues':[{**a,'severity':'P1'}]}))
  self.assertEqual(fingerprints({'issues':[a]}),fingerprints({'issues':[{**a,'line':4}]}))
 def test_digest_waits_for_p2_but_p1_is_immediate(self):
  with tempfile.TemporaryDirectory() as d:
   w=object.__new__(Worker);w.store=Store(Path(d)/'state');w.cfg={'lark_webhook':'https://fake'}
   w.notify_gogs=Mock();w.notify_gogs.page.return_value={'closed':False,'title':'PR','author':'user'};w.current_refs=lambda p:('a','b')
   job=w.store.job(1,'a','b');result={'issues':[{'file':'f','line':1,'severity':'P2','summary':'bug'}]}
   w.store.update(job['key'],status='ready',comment_url='https://git/p/1',result=json.dumps(result));w.store.set_meta('digest_due',time.time()+30)
   with patch('pr_review.service.send_lark') as send:
    w.notify_batch();send.assert_not_called()
    result['issues'][0]['severity']='P1';w.store.update(job['key'],result=json.dumps(result))
    w.notify_batch();send.assert_called_once()
    w.notify_batch();send.assert_called_once()

 def test_digest_recovers_missing_deadline_after_restart(self):
  with tempfile.TemporaryDirectory() as d:
   w=object.__new__(Worker);w.store=Store(Path(d)/'state');w.cfg={'lark_webhook':'https://fake'}
   w.notify_gogs=Mock();w.notify_gogs.page.return_value={'closed':False,'title':'PR','author':'user'};w.current_refs=lambda p:('a','b')
   job=w.store.job(1,'a','b');result={'issues':[{'file':'f','line':1,'severity':'P2','summary':'bug'}]}
   w.store.update(job['key'],status='ready',comment_url='https://git/p/1',result=json.dumps(result))
   with patch('pr_review.service.send_lark') as send,patch('pr_review.service.time.time',return_value=100):
    w.notify_batch();send.assert_not_called();self.assertEqual(w.store.meta('digest_due'),130)
   with patch('pr_review.service.send_lark') as send,patch('pr_review.service.time.time',return_value=131):
    w.notify_batch();send.assert_called_once()
 def test_only_new_issue_and_its_owner_are_notified(self):
  with tempfile.TemporaryDirectory() as d:
   w=object.__new__(Worker);w.store=Store(Path(d)/'state');w.cfg={'lark_webhook':'https://fake'}
   w.notify_gogs=Mock();w.notify_gogs.page.return_value={'closed':False,'title':'PR','author':'user'};w.current_refs=lambda p:('a','b')
   old={'file':'f','line':1,'severity':'P1','summary':'old','owner_lark_id':'ou_old'}
   new={'file':'f','line':4,'severity':'P1','summary':'new','owner_lark_id':'ou_new'}
   job=w.store.job(1,'a','b');result={'issues':[old,new]}
   w.store.update(job['key'],status='ready',comment_url='https://git/p/1',result=json.dumps(result));w.store.set_meta('sent:1',sorted(fingerprints({'issues':[old]})))
   with patch('pr_review.service.send_lark') as send:
    w.notify_batch();card=json.dumps(send.call_args.args[1]);self.assertIn('ou_new',card);self.assertNotIn('ou_old',card)
   self.assertEqual(set(w.store.meta('sent:1')),fingerprints(result))

def comment(i,user,body,minute=0):
 return {'id':i,'user':{'username':user},'body':body,'created_at':f'2026-09-08T12:{minute:02d}:00Z'}

class GateTests(unittest.TestCase):
 def setUp(self):
  self.job={'key':'key','status':'ready','result':json.dumps({'issues':[{'severity':'P2'}]}),'comment_url':'https://git/p/1#issuecomment-1'}
  self.review=comment(1,'robot','review')
  self.resolve=comment(2,'author','/review-resolve key\nF1 false-positive 已核对服务端已有同样校验',1)
  self.approve=comment(3,'maintainer','/review-approve key 已检查代码和作者提供的依据',2)
 def check(self,comments,job=None):return evaluate(job or self.job,comments,'author',['author','maintainer'],'robot')['allowed']
 def test_two_people_can_accept_evidenced_false_positive(self):self.assertTrue(self.check([self.review,self.resolve,self.approve]))
 def test_author_cannot_approve_self(self):self.assertFalse(self.check([self.review,self.resolve,{**self.approve,'user':{'username':'author'}}]))
 def test_nonmaintainer_cannot_approve(self):self.assertFalse(self.check([self.review,self.resolve,{**self.approve,'user':{'username':'random'}}]))
 def test_missing_issue_resolution_blocks(self):self.assertFalse(self.check([self.review,{**self.resolve,'body':'/review-resolve key'},self.approve]))
 def test_new_revision_invalidates_approval(self):self.assertFalse(self.check([self.review,self.resolve,self.approve],{**self.job,'key':'new'}))
 def test_edited_resolution_invalidates_previous_confirmation(self):self.assertFalse(self.check([self.review,{**self.resolve,'updated_at':'2026-09-08T12:04:00Z'},self.approve]))
 def test_failure_blocks(self):self.assertFalse(self.check([self.review,self.resolve,self.approve],{**self.job,'status':'failed'}))
 def test_zero_issues_still_requires_two_people(self):
  j={**self.job,'result':'{"issues":[]}'}
  self.assertFalse(self.check([self.review],j))
  self.assertTrue(self.check([self.review,{**self.resolve,'body':'/review-resolve key'},self.approve],j))

if __name__=='__main__':unittest.main()
