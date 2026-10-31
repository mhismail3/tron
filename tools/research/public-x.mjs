#!/usr/bin/env node
// Public root evidence only: no account, credentials, source database or remote mutations.
import {writeFile} from "node:fs/promises";
import {pathToFileURL} from "node:url";

const BODY_BYTES=2_000_000, OUTPUT_BYTES=128_000;
class Failure extends Error { constructor(reason,status){super(reason);this.reason=reason;this.status=status;} }
function identity(input){
  let url;try{url=new URL(input);}catch{throw new Failure("invalid_input");}
  const hosts=["x.com","www.x.com","twitter.com","www.twitter.com","mobile.twitter.com"];
  const match=url.pathname.match(/^\/(?:[A-Za-z0-9_]{1,50}\/status|i\/web\/status)\/([1-9][0-9]{0,19})\/?$/);
  if(url.protocol!=="https:"||url.username||url.password||url.port||!hosts.includes(url.hostname)||!match)throw new Failure("invalid_input");
  return match[1];
}
async function readPublicRoot(input){
  const id=identity(input),url="https://x.com/i/web/status/"+id;
  let response,raw;
  try{
    response=await fetch("https://api.fxtwitter.com/2/status/"+id,{redirect:"error",signal:AbortSignal.timeout(5000),headers:{accept:"application/json"}});
    if(!response.ok)throw new Failure([402,429].includes(response.status)?"quota":[401,403,407].includes(response.status)?"blocked":"unavailable",response.status);
    const chunks=[];let size=0;
    for await(const chunk of response.body){size+=chunk.byteLength;if(size>BODY_BYTES)throw new Failure("response_too_large");chunks.push(chunk);}
    raw=JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(Buffer.concat(chunks)));
  }catch(error){
    if(error instanceof Failure)throw error;
    throw new Failure(["TimeoutError","AbortError"].includes(error.name)?"timeout":error instanceof SyntaxError||error.code==="ERR_ENCODING_INVALID_ENCODED_DATA"?"parse_error":"unavailable");
  }
  const post=raw?.status;
  if(raw?.code!==200||!post||typeof post.id!=="string"||post.id!==id)throw new Failure("identity_unavailable",response.status);
  const text=typeof post.text==="string"?post.text:"";
  const blocks=post.article?.content?.blocks;
  const article=Array.isArray(blocks)?blocks.flatMap(block=>typeof block?.text==="string"&&block.text.trim()?[block.text]:[]).join("\n\n"):"";
  const result={status:"partial",reason:text.trim()||article?"provider_root_only":"missing_body",url,id,provider:"fxembed-v2-status",retrievedAt:new Date().toISOString(),
    text,article,limitations:["Third-party root evidence, not authenticated bookmark membership.","No conversation, hidden/deleted posts, linked-page, media or Article-ending completeness claim."],raw};
  if(Buffer.byteLength(JSON.stringify(result))>OUTPUT_BYTES)throw new Failure("output_too_large");
  return result;
}
async function main(args){
  if(args.length!==1&&!(args.length===3&&args[1]==="--output"))throw new Failure("invalid_input");
  const result=await readPublicRoot(args[0]);
  if(args[2]){
    // One ordinary caller-selected JSON document, including exact provider JSON; never overwrite existing work.
    await writeFile(args[2],JSON.stringify(result,null,2)+"\n",{flag:"wx",mode:0o600});
  }
  console.log(JSON.stringify(result));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  main(process.argv.slice(2)).catch(error=>{console.log(JSON.stringify({status:"error",reason:error instanceof Failure?error.reason:error.code==="EEXIST"?"output_exists":"output_unavailable",...(error instanceof Failure&&error.status?{httpStatus:error.status}:{})}));process.exitCode=1;});
}
