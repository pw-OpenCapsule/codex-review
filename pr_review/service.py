"""Gogs PR review receiver + durable worker. No repository code is executed."""
from __future__ import annotations
import hashlib, hmac, json, os, re, signal, sqlite3, subprocess, sys, threading, time
from pathlib import Path
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urljoin, urlparse
import requests
from bs4 import BeautifulSoup
try:
    from .notifications import read_people,meaningful,fingerprints,digest_card
    from .gate import evaluate as evaluate_gate
    from .direct_messages import author_recipient,dm_text,delivery_key,send_direct
except ImportError:
    from notifications import read_people,meaningful,fingerprints,digest_card
    from gate import evaluate as evaluate_gate
    from direct_messages import author_recipient,dm_text,delivery_key,send_direct

REPO = os.environ.get('PR_REVIEW_REPO', 'example/project')
SHA = re.compile(r'^[0-9a-f]{40}$')

class UnsupportedPR(ValueError): pass

def signature_ok(secret, body, supplied):
    return bool(secret) and hmac.compare_digest(hmac.new(secret.encode(), body, hashlib.sha256).hexdigest(), supplied)

def event_pr(event, payload):
    if payload.get('repository', {}).get('full_name') != REPO:
        return None
    if event == 'push': return 0
    if event != 'pull_request' or payload.get('action') not in {'opened','reopened','synchronized','synchronize'}:
        return None
    n = payload.get('number') or payload.get('pull_request', {}).get('number')
    return n if type(n) is int and 0 < n < 1_000_000 else None

def save_pr_metadata(payload,store):
    if not isinstance(payload,dict) or payload.get('repository',{}).get('full_name')!=REPO:return
    pr=payload.get('pull_request')
    if not isinstance(pr,dict):return
    n=pr.get('number') or payload.get('number')
    if type(n) is not int or n<=0:return
    head,base=pr.get('head_branch'),pr.get('base_branch')
    if not isinstance(head,str) or not isinstance(base,str):return
    for name in (head,base):
        if name.startswith('-') or subprocess.run(['git','check-ref-format','--branch',name],capture_output=True).returncode:raise ValueError('invalid branch')
    store.set_meta('pr_refs:'+str(n),{'head':head,'base':base,
        'head_repo':(pr.get('head_repo') or {}).get('full_name'),'base_repo':(pr.get('base_repo') or {}).get('full_name')})

def git(cwd, *args):
    auth=[]
    if os.environ.get('PR_REVIEW_CREDENTIALS_FILE'):
        import shlex
        helper=Path(__file__).with_name('credential_helper.py')
        auth=['-c','credential.helper=','-c','credential.helper=!'+shlex.quote(sys.executable)+' '+shlex.quote(str(helper))]
    return subprocess.check_output(['git', *auth, *args], cwd=cwd, text=True, stderr=subprocess.PIPE,
                                   timeout=120, env={**os.environ, 'GIT_TERMINAL_PROMPT':'0'}).strip()

def parse_pr(html, origin, number):
    s = BeautifulSoup(html, 'html.parser')
    desc = s.select('.pull-desc code')
    if len(desc) != 2: raise ValueError('PR branch metadata unavailable')
    names = [c.get_text().strip() for c in desc]
    owner=REPO.split('/')[0]
    if not all(n.startswith(owner+'/') for n in names): raise UnsupportedPR('fork PRs are not enabled')
    head, base = [n[len(owner)+1:] for n in names]
    if base != 'test': raise UnsupportedPR('only PRs targeting test are enabled')
    for name in (head,base):
        if name.startswith('-') or subprocess.run(['git','check-ref-format','--branch',name],capture_output=True).returncode:
            raise ValueError('invalid branch')
    title = s.select_one('h1')
    badge = s.select_one('.column.title > .label')
    if not badge: raise ValueError('PR state badge unavailable')
    closed = badge.select_one('.octicon-issue-opened') is None
    author = desc[0].find_parent(class_='pull-desc').find_previous_sibling('a')
    return {'number':number,'head':head,'base':base,'title':title.get_text(' ',strip=True) if title else f'PR #{number}',
            'url':f'{origin}/{REPO}/pulls/{number}','closed':closed,'author':author.get_text(strip=True) if author else 'unknown','soup':s}

class Gogs:
    def __init__(self, origin, credentials_file=None, metadata_store=None):
        self.credentials_file=credentials_file
        self.metadata_store=metadata_store
        self.origin = origin.rstrip('/')
        self.session = requests.Session()
        self.login()
    def login(self):
        if self.credentials_file:
            cred=json.loads(Path(self.credentials_file).read_text())
            if cred['host']!=urlparse(self.origin).netloc:raise ValueError('credential host mismatch')
            self.session.headers['Authorization']='token '+cred['token']
            r=self.session.get(self.origin+'/api/v1/user',timeout=30);r.raise_for_status()
            self.username=r.json().get('username') or r.json().get('login')
            if self.username!=cred['username']:raise ValueError('unexpected robot identity')
            return
        host = urlparse(self.origin).netloc
        raw = subprocess.check_output(['git','credential','fill'],input=f'protocol=https\nhost={host}\n\n',text=True,
                                      timeout=15,env={**os.environ,'GIT_TERMINAL_PROMPT':'0'})
        cred = dict(l.split('=',1) for l in raw.splitlines() if '=' in l)
        self.username=cred['username']
        r = self.session.get(self.origin+'/user/login',timeout=30); r.raise_for_status()
        s = BeautifulSoup(r.text,'html.parser'); csrf=s.select_one('meta[name="_csrf"]')
        if not csrf: raise ValueError('Gogs login form unavailable')
        r=self.session.post(self.origin+'/user/login',data={'_csrf':csrf['content'],'user_name':cred['username'],'password':cred['password']},timeout=30)
        r.raise_for_status()
        if '/user/login' in r.url: raise ValueError('Gogs authentication failed')
    def page(self, number):
        if self.credentials_file:
            r=self.session.get(f'{self.origin}/api/v1/repos/{REPO}/issues/{number}',timeout=30);r.raise_for_status()
            issue=r.json()
            if not issue.get('pull_request'):raise UnsupportedPR('not a PR')
            meta=self.metadata_store.meta('pr_refs:'+str(number)) if self.metadata_store else None
            if not meta:raise UnsupportedPR('PR branch metadata missing; redeliver the PR webhook')
            if meta['base_repo']!=REPO or meta['head_repo']!=REPO or meta['base']!='test':raise UnsupportedPR('unsupported PR target or fork')
            return {'number':number,'head':meta['head'],'base':meta['base'],'title':f'#{number} '+issue['title'],
                    'url':f'{self.origin}/{REPO}/pulls/{number}','closed':issue['state']!='open',
                    'author':issue['user'].get('username') or issue['user'].get('login')}
        r=self.session.get(f'{self.origin}/{REPO}/pulls/{number}',timeout=30);r.raise_for_status()
        if '/user/login' in r.url:
            if self.credentials_file:raise UnsupportedPR('Private PR HTML needs a supported metadata API')
            self.login(); return self.page(number)
        return parse_pr(r.text,self.origin,number)
    def open_prs(self):
        if self.credentials_file:
            refs=git(None,'ls-remote',self.origin+'/'+REPO+'.git','refs/pull/*/head')
            numbers=sorted({int(m[1]) for m in re.finditer(r'refs/pull/(\d+)/head',refs)})
            result=[]
            for n in numbers:
                r=self.session.get(f'{self.origin}/api/v1/repos/{REPO}/issues/{n}',timeout=30);r.raise_for_status()
                issue=r.json()
                if issue.get('pull_request') and issue['state']=='open':result.append(n)
            return result
        # Pagination avoids silently missing PRs beyond the first page.
        found=set()
        for page in range(1,101):
            r=self.session.get(f'{self.origin}/{REPO}/pulls',params={'state':'open','page':page},timeout=30);r.raise_for_status()
            ids={int(n) for n in re.findall('/'+re.escape(REPO)+r'/pulls/(\d+)',r.text)}
            if not ids-found: break
            found.update(ids)
        return sorted(found)
    def comments(self,number):
        result=[]
        for page in range(1,101):
            r=self.session.get(f'{self.origin}/api/v1/repos/{REPO}/issues/{number}/comments',params={'page':page,'limit':50},timeout=30);r.raise_for_status()
            rows=r.json()
            if not isinstance(rows,list):raise ValueError('invalid comments response')
            fresh=[x for x in rows if x['id'] not in {y['id'] for y in result}]
            if not fresh:break
            result.extend(fresh)
            if len(rows)<50:break
        return result
    def comment(self, number, marker, body):
        if getattr(self,'credentials_file',None):
            for x in self.comments(number):
                if marker in x.get('body','') and x.get('user',{}).get('username',x.get('user',{}).get('login'))==self.username:
                    return f'{self.origin}/{REPO}/pulls/{number}#issuecomment-{x["id"]}'
            if self.page(number)['closed']:raise ValueError('PR closed before comment')
            r=self.session.post(f'{self.origin}/api/v1/repos/{REPO}/issues/{number}/comments',json={'body':body},timeout=30);r.raise_for_status()
            posted=r.json()
            if not posted.get('id'):raise ValueError('comment id missing')
            return f'{self.origin}/{REPO}/pulls/{number}#issuecomment-{posted["id"]}'
        p=self.page(number);s=p['soup']
        for block in s.select('.comment'):
            if marker in block.get_text():
                link=block.select_one('a[href*="issuecomment-"]')
                return urljoin(p['url'],link['href']) if link else p['url']
        if p['closed']: raise ValueError('PR closed before comment')
        form=s.select_one(f'form[action$="/issues/{number}/comments"]')
        if not form: raise ValueError('comment form unavailable')
        data={'content':body,'status':''}
        csrf=form.select_one('input[name="_csrf"]')
        if not csrf: raise ValueError('comment CSRF missing')
        data['_csrf']=csrf['value']
        url=urljoin(self.origin,form['action'])
        if urlparse(url).netloc != urlparse(self.origin).netloc: raise ValueError('foreign form action')
        # On an uncertain response worker retries; visible marker finds an already-published comment.
        r=self.session.post(url,data=data,timeout=30);r.raise_for_status()
        p=self.page(number)
        for block in p['soup'].select('.comment'):
            if marker in block.get_text():
                link=block.select_one('a[href*="issuecomment-"]')
                return urljoin(p['url'],link['href']) if link else p['url']
        raise ValueError('comment was not confirmed on PR')

class Store:
    def __init__(self,path):
        self.path=str(path)
        with self.db() as c:
            c.executescript('''CREATE TABLE IF NOT EXISTS notice_meta(name TEXT PRIMARY KEY,value TEXT);
CREATE TABLE IF NOT EXISTS events(pr INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS jobs(key TEXT PRIMARY KEY, pr INTEGER NOT NULL, head TEXT NOT NULL, base TEXT NOT NULL,
 status TEXT NOT NULL, result TEXT, comment_url TEXT, notified INTEGER DEFAULT 0, attempts INTEGER DEFAULT 0, retry_at REAL DEFAULT 0);
''')
    @contextmanager
    def db(self):
        c=sqlite3.connect(self.path,timeout=30);c.row_factory=sqlite3.Row
        try:
            with c:yield c
        finally:c.close()
    def enqueue(self,n):
        with self.db() as c:c.execute('INSERT OR IGNORE INTO events VALUES (?)',(n,))
    def pop(self):
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            row=c.execute('SELECT pr FROM events ORDER BY pr LIMIT 1').fetchone()
            if row:c.execute('DELETE FROM events WHERE pr=?',(row['pr'],))
            return row['pr'] if row else None
    def job(self,n,head,base):
        key=hashlib.sha256(f'{REPO}:{n}:{head}:{base}'.encode()).hexdigest()
        with self.db() as c:
            c.execute('INSERT OR IGNORE INTO jobs(key,pr,head,base,status) VALUES(?,?,?,?,?)',(key,n,head,base,'pending'))
            return dict(c.execute('SELECT * FROM jobs WHERE key=?',(key,)).fetchone())
    def update(self,key,**kw):
        allowed={'status','result','comment_url','notified','attempts','retry_at'}
        if not kw.keys() <= allowed:raise ValueError('invalid update')
        with self.db() as c:c.execute('UPDATE jobs SET '+','.join(k+'=?' for k in kw)+' WHERE key=?',(*kw.values(),key))
    def retry_jobs(self):
        with self.db() as c:return [dict(r) for r in c.execute("SELECT * FROM jobs WHERE status IN ('ready','failed') AND notified=0 AND comment_url IS NULL AND retry_at<=?",(time.time(),))]

    def meta(self,name,default=None):
        with self.db() as c:r=c.execute('SELECT value FROM notice_meta WHERE name=?',(name,)).fetchone()
        return json.loads(r['value']) if r else default
    def set_meta(self,name,value):
        with self.db() as c:c.execute('INSERT OR REPLACE INTO notice_meta VALUES (?,?)',(name,json.dumps(value)))
    def notices(self):
        with self.db() as c:return [dict(r) for r in c.execute("SELECT * FROM jobs WHERE status IN ('ready','failed') AND notified=0 AND comment_url IS NOT NULL AND retry_at<=?",(time.time(),))]

def validate_review(value):
    if not isinstance(value,dict) or not isinstance(value.get('issues'),list):raise ValueError('review output missing issues')
    for x in value['issues']:
        if not isinstance(x,dict) or x.get('severity') not in ['P0','P1','P2','P3']:raise ValueError('invalid severity')
        if not all(isinstance(x.get(k),str) and x[k].strip() for k in ['summary','file','evidence']):raise ValueError('incomplete finding')
        if type(x.get('line')) is not int or x['line']<1:raise ValueError('invalid line')
        if x['file'].startswith('/') or '..' in Path(x['file']).parts:raise ValueError('invalid file')
    return value

def render(p,job,result):
    marker='review-id:'+job['key']+(':failed' if 'error' in result else ':complete')
    status='评审失败，需要重试' if 'error' in result else ('建议修复后合并' if result['issues'] else '未发现明确缺陷')
    lines=[f'自动评审：{status}',f'范围：`{job["base"][:10]}...{job["head"][:10]}`','']
    if result.get('model'):lines.append(f'模型：`{result["model"]}` · `{result.get("effort","low")}`')
    if result.get('routing',{}).get('decision')=='escalate':
        lines.append('复杂度升级：'+result['routing']['summary'])
    if 'error' in result:lines.append('评审引擎未完成，本次没有通过结论。请检查服务日志后重试。')
    else:
        for i,x in enumerate(result['issues'],1):
            lines += [f'**F{i} [{x["severity"]}] {x["summary"]}**',f'位置：`{x["file"]}:{x["line"]}`',x['evidence'],'']
        lines += ['验证范围：只读代码评审；未执行仓库脚本、线上验收或部署。']
    lines += ['','合并前需双人确认，AI 意见允许有依据地判为误报。新提交或目标分支变化使旧确认失效。',
        f'作者回复：`/review-resolve {job["key"]}`，下一行起逐条写 `F1 fixed 原因` 或 `F1 false-positive 依据`（0 问题只需首行）。',
        f'另一位维护者在作者处理后回复：`/review-approve {job["key"]} 已核对的具体依据`。',
        '注意：当前为可验证的双人确认记录，尚未接入 Gogs 服务端硬拦截。']
    lines += ['',f'自动评审标识 `{marker}`']
    return marker,'\n'.join(lines)

def send_lark(url,text):
    r=requests.post(url,json=text if isinstance(text,dict) else {'msg_type':'text','content':{'text':text}},timeout=30);r.raise_for_status()
    data=r.json()
    code=data.get('code',data.get('StatusCode'))
    if code != 0:raise ValueError(f'Lark rejected notification: code={code}')

class Worker:
    def __init__(self,config,store):
        self.cfg=config;self.store=store;self.gogs=Gogs(config['gogs_origin'],config.get('gogs_credentials_file'),store);self.child=None
        self.notify_gogs=Gogs(config['gogs_origin'],config.get('gogs_credentials_file'),store)
        self.mirror=Path(config['state_dir'])/'mirror.git'
        if not self.mirror.exists():git(None,'clone','--mirror',config['gogs_origin']+'/'+REPO+'.git',str(self.mirror))
    def refs(self,p):
        git(self.mirror,'fetch','--prune','origin')
        return git(self.mirror,'rev-parse','refs/heads/'+p['head']),git(self.mirror,'rev-parse','refs/heads/'+p['base'])
    def current_refs(self,p):
        refs=['refs/heads/'+p['head'],'refs/heads/'+p['base']]
        rows=git(None,'ls-remote',self.cfg['gogs_origin']+'/'+REPO+'.git',*refs)
        by={ref:sha for sha,ref in (x.split() for x in rows.splitlines())}
        return by.get(refs[0]),by.get(refs[1])
    def process(self,n):
        if n==0:
            for number in self.gogs.open_prs():self.store.enqueue(number)
            return
        try:p=self.gogs.page(n)
        except UnsupportedPR as e:
            print(f'PR {n} skipped: {e}',flush=True);return
        if p['closed']:return
        head,base=self.refs(p)
        job=self.store.job(n,head,base)
        if job['status']=='stale':
            self.store.update(job['key'],status='pending',notified=0,comment_url=None)
            job['status']='pending'
        if job['status'] not in ['pending','running']:return
        self.store.update(job['key'],status='running')
        cwd=Path(self.cfg['state_dir'])/'work'/job['key']
        result_path=Path(self.cfg['state_dir'])/'results'/f'{job["key"]}.json'
        cwd.parent.mkdir(exist_ok=True);result_path.parent.mkdir(exist_ok=True)
        try:
            if not cwd.exists():git(self.mirror,'worktree','add','--detach',str(cwd),head)
            merge=git(cwd,'merge-base',base,head)
            # Isolated child bounds the entire SDK call, including startup and stalled turns.
            cmd=[sys.executable,str(Path(__file__).with_name('review.py')),'--cwd',str(cwd),
                '--base',merge,'--head',head,'--output',str(result_path)]
            engine_env={k:v for k,v in os.environ.items() if k in
                {'PATH','HOME','USER','LOGNAME','TMPDIR','LANG','CODEX_HOME','CODEX_REVIEW_MODEL'}}
            engine_env['CODEX_REVIEW_MODEL']=self.cfg.get('model','gpt-6-astra')
            engine_env['CODEX_REVIEW_EFFORT']=self.cfg.get('effort','low')
            engine_env['CODEX_REVIEW_ROUTING']=self.cfg.get('routing','fixed')
            max_attempts=1 if engine_env['CODEX_REVIEW_ROUTING']=='complexity' else 2
            for attempt in range(max_attempts):
                self.child=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                    start_new_session=True,env=engine_env)
                try:
                    _,err=self.child.communicate(timeout=self.cfg.get('review_timeout',900))
                    result_path.with_suffix('.log').write_text(err)
                    if self.child.returncode==0:break
                except subprocess.TimeoutExpired:
                    self.kill_child()
                    result_path.with_suffix('.log').write_text('review engine timeout')
                finally:
                    self.child=None
                if attempt+1==max_attempts:raise ValueError('review engine failed; explicit retry required')
                time.sleep(10)
            result=meaningful(validate_review(json.loads(result_path.read_text())))
            people=read_people(self.cfg.get('lark_user_map',''))
            for issue in result['issues']:
                file=cwd/issue['file']
                if not file.is_file() or not file.resolve().is_relative_to(cwd.resolve()):raise ValueError('finding outside checkout')
                if issue['line']>len(file.read_text(errors='replace').splitlines()):raise ValueError('finding line out of range')
                source=file.read_text(errors='replace').splitlines()
                snippet=' '.join(' '.join(source[max(0,issue['line']-2):issue['line']+1]).split())
                issue['anchor']=hashlib.sha256((issue['file']+':'+snippet).encode()).hexdigest()
                try:
                    blame=git(cwd,'blame','--line-porcelain','-L',f'{issue["line"]},{issue["line"]}',head,'--',issue['file'])
                    email=re.search(r'^author-mail <(.+)>$',blame,re.M)
                    name=re.search(r'^author (.+)$',blame,re.M)
                    issue['owner_lark_id']=next((people.get(x.casefold()) for x in [email[1] if email else '',name[1] if name else '',p.get('author','')] if people.get(x.casefold())),None)
                except Exception:issue['owner_lark_id']=people.get(p.get('author','').casefold())
            result.setdefault('model',engine_env['CODEX_REVIEW_MODEL']);result.setdefault('effort',engine_env['CODEX_REVIEW_EFFORT'])
            self.store.update(job['key'],status='ready',result=json.dumps(result,ensure_ascii=False))
        except Exception as e:
            print(f'review {n} failed: {type(e).__name__}',flush=True)
            self.store.update(job['key'],status='failed',result=json.dumps({'error':type(e).__name__}))
        finally:
            if cwd.exists():git(self.mirror,'worktree','remove','--force',str(cwd))
    def kill_child(self):
        if self.child and self.child.poll() is None:
            try:os.killpg(self.child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            self.child.communicate()

    def publish(self,job):
        p=self.gogs.page(job['pr'])
        if p['closed'] or self.refs(p)!=(job['head'],job['base']):
            self.store.update(job['key'],status='stale',notified=1);self.store.enqueue(job['pr']);return
        result=meaningful(json.loads(job['result']));marker,body=render(p,job,result)
        url=job['comment_url']
        if not url:
            url=self.gogs.comment(job['pr'],marker,body)
            self.store.update(job['key'],comment_url=url)
        if 'error' not in result and not result['issues']:
            self.store.set_meta('sent:'+str(job['pr']),[])
            self.store.update(job['key'],notified=1)
        elif self.store.meta('digest_due') is None:
            self.store.set_meta('digest_due',time.time()+self.cfg.get('digest_delay_seconds',30))

    def notify_batch(self):
        jobs=self.store.notices()
        if not jobs:
            if self.store.meta('digest_due') is not None:self.store.set_meta('digest_due',None)
            return
        if self.cfg.get('notification_mode','group')!='direct' and time.time()<self.store.meta('notify_retry_at',0):return
        due=self.store.meta('digest_due')
        if due is None:
            due=time.time()+self.cfg.get('digest_delay_seconds',30)
            self.store.set_meta('digest_due',due)
        urgent=any(any(x['severity'] in ('P0','P1') for x in json.loads(j['result']).get('issues',[])) for j in jobs)
        if not urgent and time.time()<due:return
        items=[];resolved=[]
        for job in jobs:
            p=self.notify_gogs.page(job['pr'])
            if p['closed'] or self.current_refs(p)!=(job['head'],job['base']):
                self.store.update(job['key'],status='stale',notified=1);continue
            result=meaningful(json.loads(job['result']))
            known=set(self.store.meta('sent:'+str(job['pr']),[]))
            fresh=fingerprints(result)-known
            if not fresh:resolved.append(job['key']);continue
            notice=result if 'error' in result else {**result,'issues':[x for x in result['issues'] if fingerprints({'issues':[x]}) & fresh]}
            items.append((p,job,notice))
            if len(items)>=10:break
        for key in resolved:self.store.update(key,notified=1)
        if items:
            if self.cfg.get('notification_mode','group')=='direct':
                people=read_people(self.cfg.get('lark_user_map',''))
                for p,job,result in items:
                    try:
                        recipient=author_recipient(p,people)
                        key=delivery_key(job,recipient)
                        if not self.store.meta('dm_receipt:'+key):
                            mid=send_direct(self.cfg['lark_cli'],recipient,dm_text(p,job,result),key)
                            self.store.set_meta('dm_receipt:'+key,mid)
                        self.store.set_meta('sent:'+str(job['pr']),sorted(fingerprints(meaningful(json.loads(job['result'])))))
                        self.store.update(job['key'],notified=1)
                    except Exception as e:
                        self.store.update(job['key'],retry_at=time.time()+120)
                        print(f'PR {job["pr"]} direct notification deferred: {e}',flush=True)
            else:
                try:send_lark(self.cfg['lark_webhook'],digest_card(items,read_people(self.cfg.get('lark_user_map',''))))
                except Exception:
                    self.store.set_meta('notify_retry_at',time.time()+120)
                    raise
                for p,job,result in items:
                    self.store.set_meta('sent:'+str(job['pr']),sorted(fingerprints(meaningful(json.loads(job['result'])))))
                    self.store.update(job['key'],notified=1)
        self.store.set_meta('digest_due',time.time()+self.cfg.get('digest_delay_seconds',30))

    def check_gate(self,number,head,base):
        p=self.notify_gogs.page(number)
        if p['closed'] or self.current_refs(p)!=(head,base):return {'allowed':False,'reason':'PR 已关闭或版本已变化'}
        key=hashlib.sha256(f'{REPO}:{number}:{head}:{base}'.encode()).hexdigest()
        with self.store.db() as c:r=c.execute('SELECT * FROM jobs WHERE key=?',(key,)).fetchone()
        return evaluate_gate(dict(r) if r else None,self.notify_gogs.comments(number),p['author'],self.cfg.get('reviewers',[]),self.notify_gogs.username)

    def notification_loop(self):
        while True:
            try:self.notify_batch()
            except Exception as e:print(f'notification deferred: {type(e).__name__}',flush=True)
            time.sleep(2)
    def loop(self):
        next_scan=0
        while True:
            try:
                if time.time()>=next_scan:self.store.enqueue(0);next_scan=time.time()+self.cfg.get('poll_seconds',120)
                n=self.store.pop()
                if n is not None:
                    try:self.process(n)
                    except Exception as e:
                        print(f'PR discovery failed: {type(e).__name__}',flush=True)
                        time.sleep(5)  # next periodic scan retries discovery without starving other PRs
                for job in self.store.retry_jobs():
                    try:self.publish(job)
                    except Exception as e:
                        a=job['attempts']+1
                        self.store.update(job['key'],attempts=a,retry_at=time.time()+min(3600,30*2**min(a,7)))
                        print(f'PR publication failed: {type(e).__name__}; retry queued',flush=True)
                time.sleep(1)
            except Exception as e:
                print(f'worker loop: {type(e).__name__}',flush=True);time.sleep(15)

def server(config,store,gate_checker=None):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200 if self.path=='/health' else 404);self.end_headers();self.wfile.write(b'pr-review')
        def do_POST(self):
            if self.path not in ('/hooks/gogs','/merge-gate/check'):self.send_error(404);return
            try:n=int(self.headers.get('Content-Length','0'))
            except ValueError:self.send_error(400);return
            if not 0<n<=2_000_000:self.send_error(413);return
            self.connection.settimeout(10)
            body=self.rfile.read(n)
            secret=config.get('gate_secret','') if self.path=='/merge-gate/check' else config['webhook_secret']
            if not signature_ok(secret,body,self.headers.get('X-Gogs-Signature','')):
                self.send_error(403);return
            if self.path=='/merge-gate/check':
                try:
                    payload=json.loads(body)
                    if payload.get('repo')!=REPO or type(payload.get('pr')) is not int or not all(SHA.fullmatch(payload.get(k,'')) for k in ['head','base']):raise ValueError('invalid gate request')
                    if gate_checker is None:raise ValueError('gate not configured')
                    result=gate_checker(payload['pr'],payload['head'],payload['base'])
                    self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(result,ensure_ascii=False).encode())
                except Exception:self.send_error(503,'gate unavailable; deny merge')
                return
            try:
                payload=json.loads(body)
                save_pr_metadata(payload,store)
                pr=event_pr(self.headers.get('X-Gogs-Event',''),payload)
            except (ValueError,AttributeError,TypeError):self.send_error(400);return
            if pr is not None:store.enqueue(pr)
            self.send_response(202);self.end_headers();self.wfile.write(b'queued' if pr is not None else b'ignored')
        def log_message(self,format,*args):pass
    return ThreadingHTTPServer((config.get('bind','127.0.0.1'),config.get('port',9847)),Handler)

def main():
    if len(sys.argv) not in (2,4) or (len(sys.argv)==4 and sys.argv[2]!='retry'):
        raise SystemExit('usage: service.py CONFIG [retry PR_NUMBER]')
    global REPO
    config=json.loads(Path(sys.argv[1]).read_text())
    if config.get('routing','fixed') not in ('fixed','complexity'):raise SystemExit('invalid review routing mode')
    REPO=config['repo']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',REPO):raise SystemExit('invalid repository')
    if not config.get('webhook_secret'):raise SystemExit('webhook secret required')
    mode=config.get('notification_mode','group')
    if mode not in ('direct','group'):raise SystemExit('invalid notification mode')
    if mode=='direct' and not config.get('lark_cli'):raise SystemExit('Lark CLI required for direct messages')
    if mode=='group' and not config.get('lark_webhook'):raise SystemExit('Lark webhook required for group notifications')
    if config.get('gogs_credentials_file'):os.environ['PR_REVIEW_CREDENTIALS_FILE']=config['gogs_credentials_file']
    root=Path(config['state_dir']);root.mkdir(parents=True,exist_ok=True)
    store=Store(root/'state.sqlite')
    # A single daemon owns the sqlite/worktree worker, including after launchd restarts.
    import fcntl
    lock=(root/'service.lock').open('a')
    if len(sys.argv)<=2:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if len(sys.argv)<=2:
        with store.db() as c:c.execute("UPDATE jobs SET status='pending' WHERE status='running'")
    if len(sys.argv)>2 and sys.argv[2]=='retry':
        n=int(sys.argv[3])
        with store.db() as c:c.execute("UPDATE jobs SET status='pending',result=NULL,comment_url=NULL,notified=0 WHERE pr=? AND status='failed'",(n,))
        store.enqueue(n);print('retry queued');return
    worker=Worker(config,store)
    threading.Thread(target=worker.loop,daemon=True).start()
    threading.Thread(target=worker.notification_loop,daemon=True).start()
    def terminate(*_):
        worker.kill_child()
        raise SystemExit(0)
    signal.signal(signal.SIGTERM,terminate)
    signal.signal(signal.SIGINT,terminate)
    server(config,store,worker.check_gate).serve_forever()

if __name__=='__main__':main()
