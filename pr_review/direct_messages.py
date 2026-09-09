"""Send one private bot notification to the PR author; never falls back to a group."""
import hashlib,json,re,subprocess

def author_recipient(pr,people):
    recipient=people.get(pr.get('author','').casefold())
    if not recipient or not re.fullmatch(r'ou_[A-Za-z0-9]+',recipient):
        raise ValueError('PR author has no verified Lark mapping')
    return recipient

def dm_text(pr,job,result):
    lines=[pr['title'],f'提交 {job["head"][:10]}']
    if 'error' in result:lines.append('自动评审未完成，请查看 PR 中的失败说明。')
    else:
        lines.append(f'发现 {len(result["issues"])} 个待处理问题：')
        lines.extend(f'[{x["severity"]}] {x["summary"][:180]}' for x in result['issues'][:8])
        if len(result['issues'])>8:lines.append('其余问题见 PR 完整评审。')
    lines.append(job['comment_url'])
    return '\n'.join(lines)

def delivery_key(job,recipient):
    return 'prdm:'+hashlib.sha256((job['key']+':'+recipient).encode()).hexdigest()[:40]

def send_direct(cli,recipient,text,key):
    p=subprocess.run([cli,'im','+messages-send','--as','bot','--user-id',recipient,
        '--text',text,'--idempotency-key',key,'--json'],capture_output=True,text=True,timeout=45)
    try:r=json.loads(p.stdout if p.returncode==0 else p.stderr)
    except ValueError:raise RuntimeError('Lark CLI returned an invalid response') from None
    if p.returncode or r.get('ok') is not True:
        e=r.get('error',{})
        raise RuntimeError(f'Lark DM rejected: {e.get("code",e.get("type","unknown"))}')
    data=r.get('data',{});message_id=data.get('message_id') or data.get('message',{}).get('message_id')
    if not message_id:raise RuntimeError('Lark DM receipt missing message_id')
    return message_id
