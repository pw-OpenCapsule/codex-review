import json,tempfile,unittest,time
from pathlib import Path
from unittest.mock import Mock,patch
from pr_review.direct_messages import author_recipient,dm_text,delivery_key,send_direct
from pr_review.service import Worker,Store

class DirectTests(unittest.TestCase):
 def test_uses_pr_author_not_blame_owner(self):
  self.assertEqual(author_recipient({'author':'Author'},{'author':'ou_author','other':'ou_other'}),'ou_author')
  with self.assertRaises(ValueError):author_recipient({'author':'missing'},{})
 def test_bot_sender_stable_key_and_receipt(self):
  p=Mock(returncode=0,stdout=json.dumps({'ok':True,'data':{'message_id':'om_receipt'}}))
  with patch('pr_review.direct_messages.subprocess.run',return_value=p) as run:
   self.assertEqual(send_direct('/bin/lark','ou_author','body','key'),'om_receipt')
   a=run.call_args.args[0];self.assertEqual(a[a.index('--as')+1],'bot');self.assertNotIn('--chat-id',a)
  self.assertEqual(delivery_key({'key':'same'},'ou_author'),delivery_key({'key':'same'},'ou_author'))
 def test_failed_or_missing_receipt_is_not_success(self):
  for p in [Mock(returncode=1,stderr='{"ok":false,"error":{"code":230013}}'),Mock(returncode=0,stdout='{"ok":true,"data":{}}')]:
   with patch('pr_review.direct_messages.subprocess.run',return_value=p):
    with self.assertRaises(RuntimeError):send_direct('lark','ou_author','body','key')
 def test_one_failed_recipient_does_not_repeat_success_or_send_group(self):
  with tempfile.TemporaryDirectory() as d:
   w=object.__new__(Worker);w.store=Store(Path(d)/'db');people=Path(d)/'people';people.write_text('a\tou_a\tA\nb\tou_b\tB\n')
   w.cfg={'notification_mode':'direct','lark_cli':'lark','lark_user_map':str(people)}
   w.notify_gogs=Mock();w.notify_gogs.page.side_effect=lambda n:{'author':'a' if n==1 else 'b','title':f'PR {n}','closed':False}
   w.current_refs=lambda p:('h','b')
   for n in [1,2]:
    j=w.store.job(n,'h','b');w.store.update(j['key'],status='ready',result=json.dumps({'issues':[{'severity':'P1','file':'f','line':n,'summary':'bug'}]}),comment_url=f'https://git/{n}')
   with patch('pr_review.service.send_direct',side_effect=['om_a',RuntimeError('unreachable')]) as dm,patch('pr_review.service.send_lark') as group:
    w.notify_batch();self.assertEqual(dm.call_count,2);group.assert_not_called()
   self.assertEqual(w.store.job(1,'h','b')['notified'],1)
   self.assertEqual(w.store.job(2,'h','b')['notified'],0)
   self.assertGreater(w.store.job(2,'h','b')['retry_at'],time.time())
   w.store.update(w.store.job(2,'h','b')['key'],retry_at=0)
   self.assertEqual([j['pr'] for j in w.store.notices()],[2])
   w.store.set_meta('notify_retry_at',0)
   with patch('pr_review.service.send_direct',return_value='om_b') as dm,patch('pr_review.service.send_lark') as group:
    w.notify_batch();dm.assert_called_once();self.assertEqual(dm.call_args.args[1],'ou_b');group.assert_not_called()
   self.assertEqual(w.store.notices(),[])

if __name__=='__main__':unittest.main()
