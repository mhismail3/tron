#!/usr/bin/env python3
"""Free/keyless HTTP boundary measurements; no auth, signup, retries or installation.
Frozen experiment: 3 public queries, DDG vs Firecrawl keyless, two rounds reversed.
Oracle: public target domains in results, CAPTCHA/error payloads never success.
Network timings are descriptive n=2, not a general latency/quality benchmark.
No token encoder installed: bytes/4 is explicitly only a token proxy.
"""
import concurrent.futures,json,time,urllib.request,urllib.error,urllib.parse,pathlib,argparse,re
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args()
queries=[('Firecrawl search API documentation','docs.firecrawl.dev'),('Quint informal systems','quint-lang.org'),('Brave Search API pricing','brave.com')]
rows=[]
def request(provider,q,target,round):
 url='https://api.firecrawl.dev/v2/search' if provider=='firecrawl' else 'https://html.duckduckgo.com/html/?'+urllib.parse.urlencode({'q':q})
 data=json.dumps({'query':q,'limit':5}).encode() if provider=='firecrawl' else None
 req=urllib.request.Request(url,data=data,headers={'Content-Type':'application/json','User-Agent':'Tron-web-diagnosis/1.0'})
 t=time.monotonic();status=None;body=b'';err=None
 try:
  with urllib.request.urlopen(req,timeout=20) as r:status=r.status;body=r.read(1024*1024+1)
 except urllib.error.HTTPError as e:status=e.code;body=e.read(4096)
 except Exception as e:err=type(e).__name__+': '+str(e)
 text=body.decode(errors='replace');blocked=bool(re.search(r'anomaly.js|captcha|bots use DuckDuckGo|error-lite',text,re.I));out={'provider':provider,'query':q,'round':round,'status':status,'ms':round_ms(time.monotonic()-t),'bytes':len(body),'error':err,'blocked':blocked,'targetInPayload':target in text}
 if provider=='firecrawl':
  try:
   j=json.loads(text);results=j.get('data',{});results=results.get('web',[]) if isinstance(results,dict) else results;out.update(success=j.get('success'),urls=[x.get('url') for x in results] if isinstance(results,list) else [],message=str(j.get('error',''))[:300]);out['compactBytes']=len(json.dumps([{'title':x.get('title'),'url':x.get('url'),'snippet':x.get('description',x.get('snippet',''))[:300]} for x in results]).encode()) if isinstance(results,list) else 0
  except Exception:out['message']=text[:150]
 else:out['parsedResultCount']=len(re.findall(r'class="result__a"',text));out['preview']=re.sub('<[^>]+>',' ',text)[:100] if blocked else ''
 return out
def round_ms(seconds):return int(seconds*1000)
for n in range(2):
 for q,target in queries:
  for provider in (['duckduckgo','firecrawl'] if n==0 else ['firecrawl','duckduckgo']):rows.append(request(provider,q,target,n));print(json.dumps(rows[-1]),flush=True)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps({'recordedAt':time.time(),'samples':rows},indent=2))
