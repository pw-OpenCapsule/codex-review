"""Read-only chatgpt-use transport. No live browser probes in tests."""
import hashlib,json,subprocess
from pathlib import Path

class WebUnavailable(RuntimeError):pass

def request_id(scope,round_no,prompt):
    return 'review-'+hashlib.sha256(f'{scope}:{round_no}:{prompt}'.encode()).hexdigest()

def result_of(envelope):
    status=envelope.get('status')
    if status!='completed':
        # No raw provider text in public status. The complete envelope stays private.
        raise WebUnavailable('chatgpt-use '+str(status))
    value=envelope.get('result')
    if not isinstance(value,dict):raise WebUnavailable('chatgpt-use schema_violation')
    return value

def send(binary,prompt,schema,output,round_no,model,seconds,profile='auto',session='chatgpt-web',runner=subprocess.run):
    root=Path(str(output)+'.web');root.mkdir(parents=True,exist_ok=True)
    rid=request_id(str(output),round_no,prompt)
    schema_file=root/(rid+'.schema.json');prompt_file=root/(rid+'.prompt.txt');reply_file=root/(rid+'.reply.json')
    schema_file.write_text(json.dumps(schema));prompt_file.write_text(prompt)
    if reply_file.exists():
        cached=json.loads(reply_file.read_text())
        if cached.get('status')=='completed':return result_of(cached),None
    common=['--output-schema',str(schema_file),'--timeout',str(max(1,int(seconds))),'--profile',profile,'--session',session,'--busy','fail']
    cmd=[binary,'ask','Review the supplied data; return only the requested schema.','--file',str(prompt_file),'--request-id',rid,'--model',model,*common]
    run=runner(cmd,text=True,capture_output=True)
    try:envelope=json.loads(run.stdout)
    except (ValueError,TypeError):raise WebUnavailable('chatgpt-use unparseable')
    if envelope.get('status')=='duplicate':
        # Resume is read-only, never a second submission of the prompt.
        run=runner([binary,'resume',rid,*common],text=True,capture_output=True)
        try:envelope=json.loads(run.stdout)
        except (ValueError,TypeError):raise WebUnavailable('chatgpt-use unparseable')
    reply_file.write_text(json.dumps(envelope,ensure_ascii=False))
    return result_of(envelope),None
