// Local-socket reproduction of installed adapter semantic status handling.
// Process-only fixture environment; does not change Gateway settings/config files.
import {createServer} from 'node:http';
import {pathToFileURL} from 'node:url';
import {writeFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const fixtureRoot=await mkdtemp(join(tmpdir(),'tron-firecrawl-control-'));
const server=createServer((req,res)=>{req.resume();res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({success:true,data:{markdown:'# Not Found\nThe requested article does not exist.',metadata:{title:'Not Found',statusCode:404,error:'Page not found'}}}));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
try{
 process.env.PI_CODING_AGENT_DIR=fixtureRoot;
 delete process.env.FIRECRAWL_API_KEY;
 process.env.FIRECRAWL_BASE_URL=`http://127.0.0.1:${server.address().port}`;
 // Reuse an already installed Jiti loader; Node cannot strip TS in node_modules.
 const {createJiti}=await import(pathToFileURL(process.argv[4]).href);
 const {extractWithFirecrawl}=await createJiti(import.meta.url,{moduleCache:false,fsCache:false}).import(process.argv[2]);
 const result=await extractWithFirecrawl('https://example.org/article',undefined,{ssrf:{allowRanges:['127.0.0.0/8']}});
 const evidence={control:'API success:true with source metadata.statusCode:404 over local socket',acceptedAsSuccess:result?.error===null,result};
 await writeFile(process.argv[3],JSON.stringify(evidence,null,2));console.log(JSON.stringify(evidence));
 if(evidence.acceptedAsSuccess){console.error('FAIL: source HTTP404 accepted as successful extraction');process.exitCode=1;}
}finally{await new Promise(resolve=>server.close(resolve));await rm(fixtureRoot,{recursive:true,force:true});}
