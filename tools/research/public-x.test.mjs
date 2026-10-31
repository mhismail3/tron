import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,writeFile,readFile,rm,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
const exec=promisify(execFile),script=fileURLToPath(new URL('./public-x.mjs',import.meta.url));
const post={code:200,status:{id:'123456789',text:'Root evidence',article:{content:{blocks:[{text:'Article body'}]}}}};
async function fixture(t,respond){
 const root=await mkdtemp(join(tmpdir(),'tron-public-x-fixture-'));let requests=[];
 const server=createServer((req,res)=>{requests.push({url:req.url,headers:req.headers});respond(req,res);});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const origin='http://127.0.0.1:'+server.address().port;
 const loader=join(root,'fixture-loader.mjs');
 // Test-side destination substitution only. Actual CLI, fetch/abort/redirect handling,
 // streaming, parser, output bounds and filesystem publication remain shipped code.
 await writeFile(loader,`const original=globalThis.fetch;globalThis.fetch=(input,options)=>{const url=String(input),prefix='https://api.fxtwitter.com/2/status/';if(!url.startsWith(prefix)||! /^[1-9][0-9]{0,19}$/.test(url.slice(prefix.length)))throw Error('unexpected external request');return original(${JSON.stringify(origin)}+new URL(url).pathname,options);};`);
 t.after(async()=>{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(root,{recursive:true,force:true});});
 const run=async(args)=>{try{const r=await exec(process.execPath,['--import',loader,script,...args],{timeout:12000,maxBuffer:3_000_000});return {code:0,value:JSON.parse(r.stdout)};}catch(error){assert(error.stdout,'CLI must produce an explicit result: '+error.stderr);return {code:error.code,value:JSON.parse(error.stdout)};}};
 return {root,requests,run,origin};
}
test('actual CLI saves cited root/Article/raw evidence without credentials, account query or extra fetches',async t=>{
 const f=await fixture(t,(_req,res)=>res.end(JSON.stringify(post)));const output=join(f.root,'evidence.json');
 const r=await f.run(['https://twitter.com/example/status/123456789?tracking=private','--output',output]);
 assert.equal(r.code,0);assert.equal(r.value.status,'partial');assert.equal(r.value.url,'https://x.com/i/web/status/123456789');
 assert.equal(r.value.text,'Root evidence');assert.equal(r.value.article,'Article body');assert.deepEqual(r.value.raw,post);
 assert.deepEqual(JSON.parse(await readFile(output,'utf8')),r.value);assert.equal((await stat(output)).mode&0o777,0o600);
 assert.equal(f.requests.length,1);assert.equal(f.requests[0].url,'/2/status/123456789');assert.equal(f.requests[0].headers.authorization,undefined);assert.equal(f.requests[0].headers.cookie,undefined);
 const second=await f.run(['https://x.com/i/web/status/123456789','--output',output]);assert.equal(second.value.reason,'output_exists');assert.deepEqual(JSON.parse(await readFile(output,'utf8')),r.value);
});
test('invalid/private-shaped URLs and unknown options produce no provider request',async t=>{
 const f=await fixture(t,(_req,res)=>res.end('{}'));
 for(const args of [['http://x.com/example/status/123456789'],['https://user:secret@x.com/example/status/123456789'],['https://x.com/i/bookmarks'],['https://example.org/example/status/123456789'],['https://x.com/example/status/123456789','--cookies','secret']]){
  const r=await f.run(args);assert.equal(r.code,1);assert.equal(r.value.reason,'invalid_input');
 }
 assert.equal(f.requests.length,0);
});
test('quota, blocked and unavailable remain distinct; no retry or paid fallback',async t=>{
 for(const [status,reason] of [[402,'quota'],[429,'quota'],[403,'blocked'],[404,'unavailable'],[503,'unavailable']]){
  const f=await fixture(t,(_req,res)=>{res.statusCode=status;res.end('upstream');});const r=await f.run(['https://x.com/example/status/123456789']);
  assert.equal(r.code,1);assert.equal(r.value.reason,reason);assert.equal(r.value.httpStatus,status);assert.equal(f.requests.length,1);
 }
});
test('malformed and mismatched roots are not empty successes; metadata-only root is explicitly partial',async t=>{
 for(const [body,expected] of [['not-json','parse_error'],[JSON.stringify({code:200,status:{id:'987654321',text:'wrong'}}),'identity_unavailable'],[JSON.stringify({code:200,status:{id:'123456789',text:''}}),'missing_body']]){
  const f=await fixture(t,(_req,res)=>res.end(body));const r=await f.run(['https://x.com/example/status/123456789']);
  assert.equal(r.value.reason,expected);assert.equal(r.value.status,expected==='missing_body'?'partial':'error');assert.equal(f.requests.length,1);
 }
});
test('provider redirect is refused without visiting its destination',async t=>{
 const f=await fixture(t,(req,res)=>{if(req.url==='/destination'){res.end(JSON.stringify(post));return;}res.statusCode=302;res.setHeader('location',f.origin+'/destination');res.end();});
 const r=await f.run(['https://x.com/example/status/123456789']);assert.equal(r.code,1);assert.equal(r.value.reason,'unavailable');assert.equal(f.requests.length,1);
});
test('response and model-output bounds fail explicitly, never silently truncate',async t=>{
 for(const [body,reason] of [['x'.repeat(2_000_001),'response_too_large'],[JSON.stringify({code:200,status:{id:'123456789',text:'x'.repeat(130_000)}}),'output_too_large']]){
  const f=await fixture(t,(_req,res)=>res.end(body));const r=await f.run(['https://x.com/example/status/123456789']);assert.equal(r.code,1);assert.equal(r.value.reason,reason);assert.equal(f.requests.length,1);
 }
});
test('real stalled socket obeys shipped five-second abort and returns timeout, not empty',async t=>{
 const f=await fixture(t,()=>{});const r=await f.run(['https://x.com/example/status/123456789']);assert.equal(r.code,1);assert.equal(r.value.reason,'timeout');assert.equal(f.requests.length,1);
});
