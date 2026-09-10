"""One editable PR status comment. Never emits a Lark notification."""
import json
try:
 from .failures import describe
 from .protocol import marker
except ImportError:
 from failures import describe
 from protocol import marker

def progress_body(job,head=None,base=None,closed=False):
    if closed:return 'PR 已关闭，自动评审状态停止更新。\n\n'+marker(job,head,True)
    version=f'当前版本：`{head[:10]}`，目标基线：`{base[:10]}`。' if head and base else ''
    state=job.get('status') if job else 'pending'
    if state in ('pending','stale'):
        title='⏳ 自动评审已排队，请暂缓合并。'
    elif state in ('skipped','invalid'):
        reason=json.loads(job.get('result') or '{}').get('reason','')
        title=('⏭ 已跳过自动评审：' if state=='skipped' else '⚪ 声明无效，待修正：')+reason+'。仍需双人人工确认；已有缺陷、真人意见和冲突不豁免。'
    elif state=='running':
        title='🔎 自动评审中，请暂缓合并。'
    elif state=='failed':
        title='⚪ 自动评审未完成（服务不可用），请走双人人工确认；服务故障或额度不足不阻止人工合并。已有缺陷仍需处理或说明误报。'
    else:
        result=json.loads(job.get('result') or '{}')
        if 'error' in result:title='⚪ 自动评审未完成（服务不可用），请走双人人工确认；已有缺陷仍需处理或说明误报。'
        elif not job.get('comment_url'):title='🔎 评审结果正在发布，请暂缓合并。'
        elif result.get('issues'):title=f'⚠️ 自动评审发现 {len(result["issues"])} 个待处理问题，请处理并完成双人确认后再合并。'
        else:title='✅ 自动评审完成，未发现明确缺陷；仍需人工检查与双人确认。'
    lines=[title,version]
    result=json.loads((job or {}).get('result') or '{}')
    if state=='failed' or 'error' in result:
        reason,action=describe(result.get('reason_code',result.get('error')))
        lines.append('未完成原因：'+reason+'。')
        lines.append('下一步：'+action)
        if result.get('failure_cache_hit'):lines.append('本次复用了已记录的失败原因，没有重新调用模型。')
    if job and job.get('comment_url'):lines.append(f'[查看本次评审]({job["comment_url"]})')
    lines.append('这是评审状态提示，当前 Gogs 合并按钮尚未被技术锁定。')
    if job and job.get('key') and state in ('failed','skipped'):
        lines.append(f'人工确认：作者 `/review-resolve {job["key"]}`；另一位维护者 `/review-approve {job["key"]} 核对依据`。')
    lines.append(marker(job,head))
    return '\n\n'.join(x for x in lines if x)
