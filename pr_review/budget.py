"""Hard per-stage limits; cached input still counts toward the context-work cap."""
import threading

class ReviewBudgetExceeded(RuntimeError):pass

class Budget:
 def __init__(self,max_tools,max_tokens):self.max_tools=max_tools;self.max_tokens=max_tokens;self.tools=0
 def observe(self,method,payload):
  if method=='item/started':
   item=payload.get('item',{})
   if item.get('type') not in ('agentMessage','userMessage','reasoning'):
    self.tools+=1
    if self.tools>self.max_tools:raise ReviewBudgetExceeded('tool-call budget exceeded')
  if method=='thread/tokenUsage/updated':
   total=payload.get('tokenUsage',payload.get('token_usage',{})).get('total',{})
   # App-server may emit a context-window sentinel with totalTokens set but all usage counters zero.
   n=total.get('inputTokens',total.get('input_tokens',0))+total.get('outputTokens',total.get('output_tokens',0))
   if n>self.max_tokens:raise ReviewBudgetExceeded('context-work token budget exceeded')

def collect_bounded(handle,max_tools,max_tokens,seconds,checkpoint=lambda usage:None):
 budget=Budget(max_tools,max_tokens);timed_out=threading.Event();usage=None;final=None;fallback=None;completed=None
 def expire():
  timed_out.set()
  try:handle.interrupt()
  except Exception:pass
 timer=threading.Timer(seconds,expire);timer.daemon=True;timer.start()
 stream=handle.stream()
 try:
  for event in stream:
   p=event.payload.model_dump(mode='json',by_alias=True)
   if timed_out.is_set():raise ReviewBudgetExceeded('stage time budget exceeded')
   if event.method=='thread/tokenUsage/updated':
    candidate=p.get('tokenUsage',{});total=candidate.get('total',{})
    if total.get('inputTokens',0)+total.get('outputTokens',0)>0:
     usage=candidate;checkpoint(usage)
   budget.observe(event.method,p)
   if event.method=='item/completed':
    item=p.get('item',{})
    if item.get('type')=='agentMessage':
     if item.get('phase')=='final_answer':final=item.get('text')
     elif item.get('phase') is None:fallback=item.get('text')
   if event.method=='turn/completed':completed=p.get('turn')
  if timed_out.is_set():raise ReviewBudgetExceeded('stage time budget exceeded')
  if not completed:raise RuntimeError('review turn incomplete: no completion event received')
  if completed.get('status')!='completed' or completed.get('error'):
   error=completed.get('error') or {}
   detail=error.get('message','no error message supplied') if isinstance(error,dict) else str(error)
   raise RuntimeError(f'review turn {completed.get("status")}: {detail[:1200]}')
  if final is None:final=fallback
  if not final:raise RuntimeError('review response missing')
  return final,usage
 except BaseException:
  try:handle.interrupt()
  except Exception:pass
  raise
 finally:
  timer.cancel();stream.close()
