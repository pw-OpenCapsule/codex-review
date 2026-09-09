import unittest
from pr_review.model_profile import context_limits,startup_overrides
from pr_review.routing import SPARK,DEEP

class ModelProfileTests(unittest.TestCase):
 def test_spark_overrides_personal_million_token_context(self):
  personal={'model_context_window':1000000,'model_auto_compact_token_limit':900000}
  effective={**personal,**context_limits(SPARK)}
  self.assertEqual(effective['model_context_window'],128000)
  self.assertLess(effective['model_auto_compact_token_limit'],121600)
 def test_deep_has_separate_service_limits(self):
  self.assertEqual(context_limits(DEEP)['model_context_window'],256000)
  self.assertLess(context_limits(DEEP)['model_auto_compact_token_limit'],context_limits(DEEP)['model_context_window'])
 def test_startup_and_thread_limits_agree(self):
  for model in (SPARK,DEEP):
   args=startup_overrides(model)
   for k,v in context_limits(model).items():self.assertIn(f'{k}={v}',args)
   self.assertIn('service_tier="default"',args)
   self.assertIn('features.hooks=false',args)
   self.assertIn('features.child_agents_md=false',args)
   self.assertIn('project_doc_max_bytes=0',args)

if __name__=='__main__':unittest.main()
