"""Git-only token helper; called with 'get', never writes a credential store."""
import json,os,sys
from pathlib import Path
if len(sys.argv)>1 and sys.argv[1]=='get':
    request=dict(l.rstrip('\n').split('=',1) for l in sys.stdin if '=' in l)
    data=json.loads(Path(os.environ['PR_REVIEW_CREDENTIALS_FILE']).read_text())
    if request.get('protocol')=='https' and request.get('host')==data['host']:
        print('username='+data['username'])
        print('password='+data['token'])
