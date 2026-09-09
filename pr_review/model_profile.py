"""Service-owned limits and disabled personal hooks for unattended review."""
try:
    from .routing import SPARK
except ImportError:
    from routing import SPARK

def context_limits(model):
    if model==SPARK:return {'model_context_window':128000,'model_auto_compact_token_limit':80000}
    return {'model_context_window':256000,'model_auto_compact_token_limit':180000}

def startup_overrides(model):
    limits=context_limits(model)
    return (f'model="{model}"','model_reasoning_effort="low"','service_tier="default"','features.hooks=false','features.child_agents_md=false','project_doc_max_bytes=0',
            *(f'{k}={v}' for k,v in limits.items()))
