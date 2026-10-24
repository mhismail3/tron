#!/usr/bin/env python3
"""Read-only JSONL call ledger. Writes private evidence, never raw logs or credentials.
Usage: python3 scripts/web-search-audit.py --root ~/.tron --output /private/path.json
Counts structured message toolCall/toolResult pairs; codemode/browser equivalents are
listed separately because lexical matches are not dispatched web-tool invocations.
"""
import argparse, datetime, json, pathlib, re, collections
P=argparse.ArgumentParser();P.add_argument('--root',type=pathlib.Path,required=True);P.add_argument('--output',type=pathlib.Path,required=True);A=P.parse_args()
START='2026-10-21T19:41:52';END='2026-10-24T19:41:52'
NAMES={'web_search','web_fetch','fetch_content','source_check','get_search_content','agent_browser'}
def clean(x):
 s=str(x)
 s=re.sub(r'(?i)(bearer\s+|(?:api[_-]?key|token|authorization|password)\s*[=:]\s*)[^\s,\"\'}]+',r'\1[REDACTED]',s)
 s=re.sub(r'\b(?:sk-|fc-|tvly-|ghp_|github_pat_)[A-Za-z0-9_-]{12,}','[REDACTED]',s)
 s=re.sub(r'([?&](?:key|token|api_key|access_token)=)[^&\s]+',r'\1[REDACTED]',s,flags=re.I)
 s=re.sub(r'wss?://[^\s\"<>]+','[LOCAL_BROWSER_ENDPOINT]',s)
 return s
rows=[];browser=[];files=0;bad=0;seen=set();equiv=[]
paths=list((A.root/'agent'/'sessions').rglob('*.jsonl'))+list((A.root/'internal'/'subagents').rglob('*.jsonl'))
# Native sessions first; exported transcripts repeat tool IDs and omit duration/model.
paths.sort(key=lambda p: ('transcript' in p.name, str(p)))
for p in paths:
 if p.stat().st_mtime < datetime.datetime.fromisoformat(START).replace(tzinfo=datetime.timezone.utc).timestamp():continue
 if any(x in p.parts for x in ['node_modules','.git','payloads','episodic']):continue
 if '/sessions/' not in str(p) and '/subagents/' not in str(p):continue
 # Fixture sessions are retained separately, never inflate production call counts.
 fixture=any(x in str(p) for x in ['--private-var-folders','--private-tmp','integration-','test-results'])
 try:
  model=None;sid=str(p.relative_to(A.root));calls={};results={};messages=[]
  for line,l in enumerate(p.open(errors='replace'),1):
   if not any(t in l[:160] for t in ['"message"','"model_change"','"session"']):continue
   try:d=json.loads(l)
   except Exception:bad+=1;continue
   if d.get('type')=='session':sid=d.get('id')
   if d.get('type')=='model_change':model=f"{d.get('provider')}/{d.get('modelId')}"
   m=d.get('message',{});ts=d.get('timestamp','')
   if not isinstance(m,dict) or not isinstance(ts,str):continue
   content=m.get('content',[])
   if isinstance(content,str):content=[{'type':'text','text':content}]
   if m.get('role')=='assistant':
    if m.get('model'):model=f"{m.get('provider','unknown')}/{m['model']}"
    for c in content:
     if c.get('type')=='toolCall':
      name=c.get('name','');cid=c.get('id');args=c.get('arguments',{})
      if name in NAMES and START<=ts[:19]<END:
       calls[cid]={'session':sid,'path':str(p),'line':line,'timestamp':ts,'model':model,'tool':name,'callId':cid,'arguments':clean(json.dumps(args,ensure_ascii=False)),'provider':args.get('provider','unspecified'),'fixture':fixture}
      elif name in ['bash','agent_browser','codemode','functions.codemode'] and START<=ts[:19]<END and re.search(r'web_search|web_fetch|fetch_content|duckduckgo|bing.com/search|firecrawl|r.jina.ai',json.dumps(args),re.I):
       equiv.append({'session':sid,'path':str(p),'line':line,'timestamp':ts,'tool':name,'fixture':fixture,'arguments':clean(json.dumps(args))[:1400]})
   if m.get('role')=='toolResult':results[m.get('toolCallId')]=(line,ts,m)
   if m.get('role')=='assistant':messages.append((line,ts,content))
  if calls:files+=1
  for cid,row in calls.items():
   identity=cid
   if identity in seen:continue
   seen.add(identity)
   result=results.get(cid)
   if result:
    line,ts,m=result;txt='\n'.join(c.get('text','') for c in m.get('content',[]) if c.get('type')=='text')
    details=m.get('details') or {}
    if isinstance(details,dict):
     row['reportedProvider']=details.get('provider')
     row['urlCount']=details.get('urlCount')
     row['successfulUrls']=details.get('successful')
     row['totalChars']=details.get('totalChars')
     row['truncated']=details.get('truncated')
     row['reportedStatus']=details.get('status')
     row['reportedError']=clean(details.get('error',''))
     if isinstance(details.get('results'),list):row['providerResults']=[{k:v for k,v in d.items() if k in ['provider','error']} for d in details['results'] if isinstance(d,dict)]
    row.update(resultLine=line,resultTimestamp=ts,durationMs=m.get('durationMs'),isError=m.get('isError'),bytes=len(txt.encode()),tokenProxy=(len(txt.encode())+3)//4,result=clean(txt)[:1800],detailsKeys=list(details.keys()) if isinstance(details,dict) else [])
    row['urlErrors']=clean('\n'.join(re.findall(r'^- https?://[^\n]+: Error - [^\n]+',txt,re.M)))
    classes=[]
    for k,pattern in [('captcha',r'captcha|anomaly.js|bots use DuckDuckGo|select all squares'),('timeout',r'timed? ?out|aborted|deadline'),('http_error',r'HTTP [45]\d\d|Forbidden|Access Denied|Too Many Requests'),('empty',r'No (?:search )?results|No matching'),('schema',r'Unknown tool|Tool .+ not (?:found|available)|invalid.*(?:argument|schema)'),('error_page',r'Please try again later|Something went wrong|has been blocked')]:
     if re.search(pattern,txt,re.I):classes.append(k)
    if m.get('isError'):classes.append('tool_error')
    if len(txt.encode())>24000:classes.append('large_output')
    row['flags']=classes
    nxt=next((c for n,t,c in messages if n>line),[])
    nxt=[{k:v for k,v in c.items() if k in ['type','name','arguments','text','thinking']} for c in nxt]
    row['nextAction']=clean(json.dumps(nxt,ensure_ascii=False))[:1600]
   else:row['flags']=['missing_result']
   (browser if row['tool']=='agent_browser' else rows).append(row)
 except (OSError,UnicodeError):continue
out={'window':[START,END],'filesWithCandidateCalls':files,'canonicalCallFiles':len({r['path'] for r in rows}),'malformedLines':bad,'calls':rows,'browserCalls':browser,'equivalentCandidates':equiv,'counts':dict(collections.Counter(f for r in rows if not r['fixture'] for f in r['flags']))}
A.output.parent.mkdir(parents=True,exist_ok=True);A.output.write_text(json.dumps(out,indent=2,ensure_ascii=False));print(json.dumps({'calls':len(rows),'productionCalls':sum(not r['fixture'] for r in rows),'counts':out['counts'],'filesWithCandidateCalls':files,'canonicalCallFiles':len({r['path'] for r in rows}),'browserCalls':len(browser),'equivalentCandidates':len(equiv)}))
