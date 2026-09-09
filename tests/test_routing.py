import copy,tempfile,unittest
from pathlib import Path
from pr_review.routing import choose_route,pipeline,SPARK,DEEP

SCHEMA={'properties':{'issues':{'type':'array','items':{'type':'object'}}}}
def triage(**changes):
 x={'decision':'complete','complexity':{'scope':'local','state_paths':'linear','coupled_invariants':False,'verification':'local'},'evidence':[],'summary':'局部字段映射，已验证调用契约','issues':[]}
 x.update(changes);return x

def complex_triage():
 return triage(decision='escalate',complexity={'scope':'cross_module','state_paths':'interleaved','coupled_invariants':True,'verification':'unresolved'},evidence=[{'file':'ui/state.py','line':3,'scenario':'取消后旧回调再次提交状态','needs_verification':'核对取消信号与提交的先后关系'}],summary='取消与异步回调交错')

class RoutingTests(unittest.TestCase):
 def test_business_name_and_severity_do_not_force_upgrade(self):
  x=triage(issues=[{'severity':'P1','file':'payments.py','line':1,'summary':'局部确定错误','evidence':'参数明显错误'}])
  self.assertEqual(choose_route(x)[0],'complete')
 def test_mechanical_cross_module_change_stays_spark(self):
  x=triage();x['complexity']['scope']='cross_module'
  self.assertEqual(choose_route(x)[0],'complete')
 def test_complex_ui_escalates(self):self.assertEqual(choose_route(complex_triage())[0],'escalate')
 def test_complexity_cannot_be_hidden_by_complete_label(self):
  x=complex_triage();x['decision']='complete';self.assertEqual(choose_route(x)[0],'escalate')
 def test_vague_escalation_is_not_a_pass_or_unbounded_upgrade(self):
  with self.assertRaises(ValueError):choose_route(triage(decision='escalate'))
 def test_simple_runs_only_spark_and_records_usage(self):
  with tempfile.TemporaryDirectory() as d:
   calls=[]
   def run(model,prompt,schema):calls.append(model);return triage(),{'total':12}
   r=pipeline(run,{'base':'a','head':'b'},Path(d)/'out',SCHEMA)
   self.assertEqual(calls,[SPARK]);self.assertEqual(r['model'],SPARK);self.assertEqual(r['usage_by_stage']['spark']['usage'],{'total':12})
 def test_deep_gets_handoff_and_only_confirmed_findings_are_returned(self):
  with tempfile.TemporaryDirectory() as d:
   calls=[]
   def run(model,prompt,schema):
    calls.append(model)
    if model==SPARK:
     x=complex_triage();x['issues']=[{'summary':'候选，未经确认'}];return x,None
    self.assertIn('取消与异步回调交错',prompt);return {'issues':[]},None
   r=pipeline(run,{'base':'a','head':'b'},Path(d)/'out',SCHEMA)
   self.assertEqual(calls,[SPARK,DEEP]);self.assertEqual(r['issues'],[]);self.assertEqual(r['model'],DEEP)
 def test_failed_deep_stage_retry_reuses_spark(self):
  with tempfile.TemporaryDirectory() as d:
   out=Path(d)/'out';calls=[]
   def first(model,prompt,schema):
    calls.append(model)
    if model==SPARK:return complex_triage(),None
    raise RuntimeError('temporary failure')
   with self.assertRaises(RuntimeError):pipeline(first,{'head':'b'},out,SCHEMA)
   def retry(model,prompt,schema):calls.append(model);return {'issues':[]},None
   pipeline(retry,{'head':'b'},out,SCHEMA)
   self.assertEqual(calls,[SPARK,DEEP,DEEP])
 def test_new_revision_invalidates_checkpoint(self):
  with tempfile.TemporaryDirectory() as d:
   out=Path(d)/'out';calls=[]
   def run(model,prompt,schema):calls.append(model);return triage(),None
   pipeline(run,{'head':'b'},out,SCHEMA);pipeline(run,{'head':'c'},out,SCHEMA)
   self.assertEqual(calls,[SPARK,SPARK])
 def test_invalid_evidence_never_calls_deep(self):
  with tempfile.TemporaryDirectory() as d:
   calls=[]
   def run(model,prompt,schema):calls.append(model);return complex_triage(),None
   def reject(e):raise ValueError('outside checkout')
   with self.assertRaises(ValueError):pipeline(run,{},Path(d)/'out',SCHEMA,reject)
   self.assertEqual(calls,[SPARK])

if __name__=='__main__':unittest.main()
