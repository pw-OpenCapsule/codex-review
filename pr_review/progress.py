"""One editable PR status comment. Never emits a Lark notification."""
import json

def progress_body(job,head=None,base=None,closed=False):
    if closed:return 'PR 已关闭，自动评审状态停止更新。'
    version=f'当前版本：`{head[:10]}`，目标基线：`{base[:10]}`。' if head and base else ''
    state=job.get('status') if job else 'pending'
    if state in ('pending','stale'):
        title='⏳ 自动评审已排队，请暂缓合并。'
    elif state=='running':
        title='🔎 自动评审中，请暂缓合并。'
    elif state=='failed':
        title='❌ 自动评审未完成，请暂缓合并并查看失败说明。'
    else:
        result=json.loads(job.get('result') or '{}')
        if 'error' in result:title='❌ 自动评审未完成，请暂缓合并。'
        elif not job.get('comment_url'):title='🔎 评审结果正在发布，请暂缓合并。'
        elif result.get('issues'):title=f'⚠️ 自动评审发现 {len(result["issues"])} 个待处理问题，请处理并完成双人确认后再合并。'
        else:title='✅ 自动评审完成，未发现明确缺陷；仍需人工检查与双人确认。'
    lines=[title,version]
    if job and job.get('comment_url'):lines.append(f'[查看本次评审]({job["comment_url"]})')
    lines.append('这是评审状态提示，当前 Gogs 合并按钮尚未被技术锁定。')
    return '\n\n'.join(x for x in lines if x)
