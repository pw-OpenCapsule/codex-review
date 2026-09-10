"""PR Review v1: declarations are data from the top-level PR body only."""
import hashlib,json,re

def declaration(body):
    found=[];fence=None;html=False
    for raw in (body or '').splitlines():
        line=raw.strip()
        if '<!--' in line:html=True
        if html:
            if '-->' in line:html=False
            continue
        if raw.startswith(('    ','\t')) or line.startswith('>'):continue
        m=re.match(r'^(`{3,}|~{3,})',line)
        if m:
            if fence is None:fence=m[1][0]
            elif m[1][0]==fence:fence=None
            continue
        if fence:continue
        if not re.match(r'^\[(?:review\b|no-review\b)',line,re.I):continue
        m=re.fullmatch(r'\[(?:review:(none|spark|deep)|(no-review))\]\s+(.+)',line)
        found.append({'level':(m[1] or 'none'),'reason':m[3].strip(),'valid':True} if m else {'level':'spark','reason':'声明格式无效或缺少理由','valid':False})
    if not found:return {'level':'spark','reason':'','valid':True}
    if len(found)!=1:return {'level':'spark','reason':'只能有一条评审声明','valid':False}
    return found[0]

def job_key(repo,n,head,base,d=None):
    d=d or declaration('');suffix='' if d==declaration('') else ':'+json.dumps(d,sort_keys=True,ensure_ascii=False)
    return hashlib.sha256(f'{repo}:{n}:{head}:{base}{suffix}'.encode()).hexdigest()

def effective_config(config,d):
    return {**config,'routing':'fixed','model':'gpt-6-astra' if d['level']=='deep' else 'gpt-5.3-codex-spark','effort':'low'}

def marker(job,head,closed=False):
    r=json.loads((job or {}).get('result') or '{}');d=(job or {}).get('declaration',declaration(''))
    state=(job or {}).get('status','pending')
    status='cancelled' if closed else {'pending':'queued','stale':'cancelled','running':'running','failed':'unavailable','skipped':'skipped','invalid':'invalid','ready':'completed'}.get(state,'unavailable')
    if state=='ready' and not (job or {}).get('comment_url'):status='running'
    models=[]
    for v in r.get('usage_by_stage',r.get('cached_usage_by_stage',{})).values():
        m=v.get('model');label='spark' if m=='gpt-5.3-codex-spark' else 'gpt6-low' if m=='gpt-6-astra' else m
        if label and label not in models:models.append(label)
    if not models and r.get('model'):models=['spark' if r['model']=='gpt-5.3-codex-spark' else 'gpt6-low' if r['model']=='gpt-6-astra' else r['model']]
    value={'head':head,'requested':d['level'],'status':status,'models':models,'cache_hit':r.get('cache',{}).get('hit',False),'findings':len(r.get('issues',[])) if status=='completed' else None}
    value['decision_policy']='agent' if status=='unavailable' else 'existing'
    value['reason_code']=r.get('reason_code',r.get('error'))
    value['reason']=r.get('reason')
    value['review_key']=(job or {}).get('key')
    return '<!-- pr-review:v1 '+json.dumps(value,ensure_ascii=False,separators=(',',':'))+' -->'
