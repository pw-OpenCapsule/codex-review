"""Stable public failure reasons; raw provider logs stay private."""
REASONS={
 'channel_paused':('评审渠道已由维护者暂停','由提交方 Agent 自查决定合并；不会自动切换 Codex，恢复渠道后再处理。'),
 'quota_exhausted':('模型账户额度不足或请求限流','等待额度恢复后显式重试，或由提交方 Agent 自查决定合并。'),
 'context_insufficient':('已提供的代码片段不足以完成核验','补充相关上下文后重试，或由提交方 Agent 自查决定合并。'),
 'context_window_exceeded':('模型上下文窗口不足','维护者缩减或调整输入后重试；这不是账户额度不足。'),
 'time_limit':('本轮评审达到执行时间上限','维护者核查耗时后重试，或由提交方 Agent 自查决定合并。'),
 'token_budget':('本轮评审达到本地 token 预算上限','维护者缩小评审范围后重试；不代表账户额度耗尽。'),
 'context_read_limit':('本轮达到代码片段或交互轮数上限','补充必要上下文或缩小评审范围后重试。'),
 'tool_budget':('模型超出允许的工具调用范围','维护者检查模型行为与工具配置后重试。'),
 'budget_exceeded':('本轮达到本地评审限制，旧记录未保留具体类别','维护者核对原始日志；不能据此断言账户额度不足。'),
 'web_unavailable':('ChatGPT 网页通道不可用或未返回完整有效结果','查看私有请求回执；不要重复提交，必要时按 request_id 恢复读取。'),
 'engine_error':('评审引擎异常，尚未形成代码结论','维护者查看服务日志；可由提交方 Agent 自查决定合并。'),
}
def describe(code):return REASONS.get(code,REASONS['engine_error'])
def classify(log,fallback='engine_error'):
 s=(log or '').lower()
 checks=[('web_unavailable',('chatgpt-use ',)),('quota_exhausted',("usage limit","quota","too many requests","rate limit")),('context_insufficient',('insufficient focused context',)),('context_window_exceeded',("context window",)),('time_limit',('time budget','engine timeout','timed out')),('token_budget',('context-work token budget',)),('context_read_limit',('context read budget','round budget')),('tool_budget',('tool-call budget',))]
 code=next((code for code,words in checks if any(w in s for w in words)),fallback)
 reason,action=describe(code)
 return {'error':code,'reason_code':code,'reason':reason,'next_action':action}
class CachedFailure(RuntimeError):
 def __init__(self,result):self.result=result
