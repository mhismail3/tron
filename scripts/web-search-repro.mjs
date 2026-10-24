// Diagnosis harness: executes the deployed real Home tools, no Gateway startup.
// Run: scripts/tron-node exec node scripts/web-search-repro.mjs <absolute-home-tool-module> <output.json>
import {pathToFileURL} from 'node:url';
import {writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
const {homeResearchTools}=await import(pathToFileURL(process.argv[2]).href);
const host={sessionRead:{},knowledge:()=>undefined,sessionSearch:()=>undefined,explicitlyTrustedDirectory:async()=>false};
const tools=homeResearchTools(host), rows=[];
for(const [name,args] of (process.argv.includes('--fixture-only')?[]:[['web_search',{query:'Quint informal systems'}],['web_fetch',{url:'https://html.duckduckgo.com/html/?q=slimkey'}],['web_fetch',{url:'https://www.bing.com/search?q=%22slimkey%22'}]])){
 const start=performance.now();const result=await tools.find(t=>t.name===name).execute('diagnosis-only',args);
 rows.push({name,args,ms:Math.round(performance.now()-start),details:result.details,text:result.content.map(c=>c.text||'').join('\n')});
}
// Controlled real HTTP response demonstrates the semantic error at the tool boundary.
const server=createServer((req,res)=>{res.writeHead(200,{'content-type':'text/html'});res.end('<html><title>Search temporarily unavailable</title><body>Please try again later. Images not loading? error-lite Code: 4458</body></html>');});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
try{
 const fixtureTools=homeResearchTools({...host,transport:{resolveHost:async()=>['93.184.216.34'],fetcher:async()=>fetch(`http://127.0.0.1:${server.address().port}`)}});
 for(const [name,args] of [['web_search',{query:'known existing topic'}],['web_fetch',{url:'https://public.example/error'}]]){
  const result=await fixtureTools.find(t=>t.name===name).execute('fixture',args);rows.push({name,args,control:'HTTP200 error page via local socket',details:result.details,text:result.content.map(c=>c.text||'').join('\n')});
 }
}finally{await new Promise(resolve=>server.close(resolve));}
await writeFile(process.argv[3],JSON.stringify(rows,null,2));
console.log(JSON.stringify(rows.map(({text,...r})=>({...r,bytes:Buffer.byteLength(text),preview:text.slice(0,320)})),null,2));
if(process.argv.includes('--expect-safe')&&rows.some(r=>r.control&&r.details?.status==='ok')){
 console.error('FAIL: HTTP-200 error content was accepted as successful research.');process.exitCode=1;
}
