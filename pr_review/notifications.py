"""Quiet, source-attributed Lark digests. Model output cannot choose mention IDs."""
import hashlib,html,json,re
from pathlib import Path
from collections import Counter

def read_people(path):
    out={}
    if not path or not Path(path).is_file():return out
    for line in Path(path).read_text().splitlines():
        parts=line.strip().split('\t')
        if line.startswith('#') or len(parts)<2:continue
        if re.fullmatch(r'ou_[A-Za-z0-9]+',parts[1]):out[parts[0].casefold()]=parts[1]
    return out

def meaningful(result):
    if 'error' in result:return result
    return {**result,'issues':[x for x in result['issues'] if x['severity'] in ('P0','P1','P2') and x.get('confidence',1)>=.9]}

def fingerprints(result):
    if 'error' in result:return {'engine-failure'}
    # Severity stays outside the identity, so escalation can trigger a fresh notification.
    return {(x.get('anchor') or hashlib.sha256(f'{x["file"]}:{x["line"]}'.encode()).hexdigest())+':'+x['severity'] for x in result['issues']}

def digest_card(items,people):
    blocks=[]
    for p,job,result in items:
        counts=Counter(x['severity'] for x in result.get('issues',[]))
        status='评审失败，需要查看服务日志' if 'error' in result else ' · '.join(f'{k} × {v}' for k,v in sorted(counts.items()))
        owners=list(dict.fromkeys(x.get('owner_lark_id') for x in result.get('issues',[]) if x.get('owner_lark_id')))
        if not owners:
            owner=people.get(p.get('author','').casefold())
            if owner:owners=[owner]
        mentions=' '.join(f'<at id={o}></at>' for o in owners[:3] if re.fullmatch(r'ou_[A-Za-z0-9]+',o))
        if not mentions:mentions='负责人：'+html.escape(p.get('author','未映射'))+'（映射待补）'
        blocks.append({'tag':'markdown','content':f'**{html.escape(p["title"])}**\n{status}  {mentions}\n[查看评审与处理意见]({job["comment_url"]})'})
    return {'msg_type':'interactive','card':{'header':{'title':{'tag':'plain_text','content':'PR 评审待处理'},'template':'orange'},'elements':blocks}}
