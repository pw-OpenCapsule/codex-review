"""Project-scoped exact-source cache, independent of PR and target tip."""
import hashlib,json
from pathlib import Path

def policy_digest(config):
    root=Path(__file__).parent
    files=('review.py','routing.py','focused.py','budget.py','model_profile.py','reuse.py','web_transport.py')
    h=hashlib.sha256()
    for name in files:h.update(name.encode()+b'\0'+(root/name).read_bytes())
    h.update(json.dumps({k:config.get(k) for k in ('routing','model','effort','codex_bin','backend','chatgpt_use')},sort_keys=True).encode())
    return h.hexdigest()

def cache_key(repo,head,merge,policy):
    # Same head pins the entire source tree, not merely the displayed patch.
    return hashlib.sha256(json.dumps([repo,head,merge,policy]).encode()).hexdigest()

def stable_remaining(previous,head,now,delay):
    state=previous if previous and previous.get('head')==head else {'head':head,'since':now}
    return state,max(0,state['since']+delay-now)
