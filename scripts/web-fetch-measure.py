#!/usr/bin/env python3
"""Free/keyless scrape comparison; public URLs only, n=1 each; no secrets."""
import json,pathlib,time,urllib.request,urllib.error,sys
rows=[]
for url in ['https://docs.firecrawl.dev/features/search','https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard']:
 for provider in ['firecrawl','jina']:
  req=urllib.request.Request('https://api.firecrawl.dev/v2/scrape' if provider=='firecrawl' else 'https://r.jina.ai/'+url,data=json.dumps({'url':url,'formats':['markdown'],'onlyMainContent':True,'timeout':15000}).encode() if provider=='firecrawl' else None,headers={'Content-Type':'application/json','User-Agent':'Tron-web-diagnosis/1.0'})
  start=time.monotonic();status=None;body=b'';error=None
  try:
   with urllib.request.urlopen(req,timeout=20) as r:status=r.status;body=r.read(1048577)
  except urllib.error.HTTPError as e:status=e.code;body=e.read(4096)
  except Exception as e:error=type(e).__name__+': '+str(e)
  text=body.decode(errors='replace');content=text;semantic=None
  if provider=='firecrawl':
   try:
    j=json.loads(text);content=j.get('data',{}).get('markdown','');semantic=j.get('data',{}).get('metadata',{}).get('statusCode');error=j.get('error',error)
   except Exception:pass
  row={'provider':provider,'url':url,'status':status,'sourceStatus':semantic,'ms':round((time.monotonic()-start)*1000),'responseBytes':len(body),'markdownBytes':len(content.encode()),'error':error,'hasExpectedTerms':('Search' in content and 'query' in content) if 'firecrawl.dev' in url else ('keyboard' in content.lower() and len(content)>1500),'preview':content[:180]};rows.append(row);print(json.dumps(row),flush=True)
pathlib.Path(sys.argv[1]).write_text(json.dumps(rows,indent=2))
