"""Two-person acknowledgement policy, bound to one immutable review revision.

This evaluates eligibility; Gogs must call it at its merge boundary to enforce it.
"""
import re
from datetime import datetime

def stamp(c):
    raw=c.get('updated_at') or c.get('created_at')
    try:return datetime.fromisoformat(raw.replace('Z','+00:00')).timestamp()
    except (AttributeError,ValueError):return 0

def evaluate(job,comments,author,reviewers,bot):
    if not job or job['status'] not in ('ready','failed','skipped'):return {'allowed':False,'reason':'评审尚未成功完成'}
    import json
    result=json.loads(job['result'])
    manual=job['status'] in ('failed','skipped') or 'error' in result
    match=re.search(r'#issuecomment-(\d+)$',job.get('comment_url') or '')
    if manual:
        review=None
        for c in comments:
            user=c.get('user',{});name=user.get('username') or user.get('login')
            if name!=bot:continue
            m=re.search(r'<!-- pr-review:v1 (.*?) -->',c.get('body',''))
            if not m:continue
            try:state=json.loads(m[1])
            except ValueError:continue
            if state.get('review_key')==job['key'] and state.get('status') in ('unavailable','skipped'):review=c
        result={'issues':[]}
    else:
        if not match:return {'allowed':False,'reason':'评审评论尚未发布'}
        review=next((c for c in comments if c['id']==int(match[1])),None)
    if not review:return {'allowed':False,'reason':'无法验证评审评论'}
    if stamp(review)<=0:return {'allowed':False,'reason':'评审时间无法验证'}
    key=job['key'];author=author.casefold();reviewers={x.casefold() for x in reviewers}
    count=len([x for x in result.get('issues',[]) if x['severity'] in ('P0','P1','P2') and x.get('confidence',1)>=.9]);resolution=None;approved=[]
    for c in sorted(comments,key=lambda c:(stamp(c),c['id'])):
        if c['id']<=review['id'] or stamp(c)<stamp(review):continue
        user=(c.get('user',{}).get('username') or c.get('user',{}).get('login') or '').casefold()
        if not user or user==bot.casefold():continue
        lines=(c.get('body') or '').strip().splitlines()
        if not lines:continue
        if user==author and lines[0].strip()==f'/review-resolve {key}':
            answers={}
            for line in lines[1:]:
                m=re.fullmatch(r'F([1-9]\d*)\s+(fixed|false-positive)\s+(.{6,})',line.strip())
                if m:answers[int(m[1])]=(m[2],m[3])
            resolution=(c,answers)
        if user!=author and user in reviewers and re.fullmatch(r'/review-approve '+key+r'\s+.{6,}',lines[0].strip()):approved.append(c)
    if resolution is None:return {'allowed':False,'reason':'等待作者逐条处理意见'}
    comment,answers=resolution
    if set(answers)!=set(range(1,count+1)):return {'allowed':False,'reason':'作者尚未逐条说明已修复或误报依据'}
    ack=next((c for c in reversed(approved) if stamp(c)>=stamp(comment) and c['id']>comment['id']),None)
    if not ack:return {'allowed':False,'reason':'等待另一位维护者确认作者处理意见'}
    return {'allowed':True,'reason':'双人确认完成','author_comment_id':comment['id'],'reviewer_comment_id':ack['id'],'review_key':key}
