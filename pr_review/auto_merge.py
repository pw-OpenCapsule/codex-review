"""Opt-in no-review merge dispatch. Host adapter must atomically verify refs."""
import json,subprocess

def eligibility(declared,author,allowed_authors,comments,bot,known_findings):
    if not declared.get('valid') or declared.get('level')!='none':return False,'explicit none declaration required'
    if author not in allowed_authors:return False,'author not allowlisted for automatic merge'
    if known_findings:return False,'existing findings require resolution'
    for c in comments:
        name=c.get('user',{}).get('username') or c.get('user',{}).get('login')
        if name!=bot and c.get('body','').strip():return False,'human comments require manual handling'
    return True,'explicit no-review declaration with no known blockers'

def dispatch(config,request):
    command=config.get('command')
    if not config.get('enabled'):return {'status':'disabled'}
    if config.get('identity')!='robot':return {'status':'blocked','reason':'only robot merge identity is authorized'}
    if not isinstance(command,list) or not command or not all(isinstance(x,str) for x in command):return {'status':'blocked','reason':'merge adapter missing'}
    # Adapter is an operator-controlled executable, never taken from a PR checkout.
    out=subprocess.run(command,input=json.dumps(request),text=True,capture_output=True,timeout=45,check=True)
    receipt=json.loads(out.stdout)
    if receipt.get('status')=='merged' and (receipt.get('head')!=request['head'] or receipt.get('base')!=request['base']):
        raise ValueError('merge receipt does not match requested revision')
    return receipt
