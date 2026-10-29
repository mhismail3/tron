import { execFileSync } from "node:child_process";
import { constants } from "node:fs";
import { mkdir, mkdtemp, open, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, expect, inject, it } from "vitest";

type Binding = { publishDirectoryExclusive(source: number, name: string, destination: number, leaf: string, done: (error: Error | null, published: boolean) => void): void };
let root: string, artifact: string, native: Binding;
beforeAll(async () => {
  root = await realpath(await mkdtemp(join(tmpdir(), "tron-native-directory-")));
  artifact = inject("nativePublicationBinary");
  native = createRequire(import.meta.url)(artifact);
});
afterAll(async () => { if (root) await rm(root, { recursive: true, force: true }); });
async function scope(name: string) {
  const base = join(root, name), source = join(base, "source"), destination = join(base, "destination");
  await mkdir(source, { recursive: true }); await mkdir(destination); await mkdir(join(source, "stage"), { mode: 0o700 });
  await writeFile(join(source, "stage/payload"), "owned bytes");
  const from = await open(source, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW), to = await open(destination, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  return { base, source, destination, from, to, publish: (leaf = "entry") => new Promise<boolean>((resolve, reject) => {
    try { native.publishDirectoryExclusive(from.fd, "stage", to.fd, leaf, (error, published) => error ? reject(error) : resolve(published)); } catch (error) { reject(error); }
  }), close: () => Promise.all([from.close(), to.close()]) };
}

it("atomically publishes a private directory through pinned parent descriptors", async () => {
  const f = await scope("publish");
  try {
    expect(await f.publish()).toBe(true);
    expect(await readFile(join(f.destination, "entry/payload"), "utf8")).toBe("owned bytes");
    expect(await readdir(f.source)).toEqual([]);
  } finally { await f.close(); }
});

it("does not replace empty directories, nonempty directories, files or dangling links", async () => {
  for (const kind of ["empty", "nonempty", "file", "link"]) {
    const f = await scope(kind), path = join(f.destination, "entry");
    try {
      if (kind === "empty" || kind === "nonempty") await mkdir(path);
      if (kind === "nonempty") await writeFile(join(path, "external"), "external bytes");
      if (kind === "file") await writeFile(path, "external bytes");
      if (kind === "link") await symlink("absent", path);
      expect(await f.publish()).toBe(false);
      expect(await readFile(join(f.source, "stage/payload"), "utf8")).toBe("owned bytes");
      if (kind === "empty") expect(await readdir(path)).toEqual([]);
      if (kind === "nonempty") expect(await readFile(join(path, "external"), "utf8")).toBe("external bytes");
      if (kind === "file") expect(await readFile(path, "utf8")).toBe("external bytes");
      if (kind === "link") await expect(readFile(path)).rejects.toMatchObject({ code: "ENOENT" });
    } finally { await f.close(); }
  }
});

it("pins borrowed descriptors before returning and never resolves a replaced parent pathname", async () => {
  const f = await scope("pinned");
  const script = `const fs=require('node:fs'),cp=require('node:child_process'),addon=require(process.argv[1]),base=process.argv[2];
cp.execFileSync('/usr/bin/mkfifo',[base+'/gate']); const gate=fs.openSync(base+'/gate',fs.constants.O_RDWR);
fs.read(gate,Buffer.alloc(1),0,1,null,error=>{if(error)throw error;fs.closeSync(gate);});
const a=fs.openSync(base+'/source','r'), b=fs.openSync(base+'/destination','r');
addon.publishDirectoryExclusive(a,'stage',b,'entry',(error,published)=>{if(error)throw error; console.log(JSON.stringify({published, bytes:fs.readFileSync(base+'/retained/entry/payload','utf8'), replacement:fs.readdirSync(base+'/destination')}));});
fs.closeSync(a);fs.closeSync(b);fs.renameSync(base+'/destination',base+'/retained');fs.mkdirSync(base+'/destination');fs.writeSync(gate,Buffer.from('x'));`;
  try {
    const result = JSON.parse(execFileSync(process.execPath, ["-e", script, artifact, f.base], { encoding: "utf8", env: { ...process.env, UV_THREADPOOL_SIZE: "1" } }));
    expect(result).toEqual({ published: true, bytes: "owned bytes", replacement: [] });
  } finally { await f.close(); }
});

it("retains an empty directory created by another process after publication is accepted", async () => {
  const f = await scope("race");
  const script = `const fs=require('node:fs'),cp=require('node:child_process'),addon=require(process.argv[1]),base=process.argv[2];
cp.execFileSync('/usr/bin/mkfifo',[base+'/gate']);const gate=fs.openSync(base+'/gate',fs.constants.O_RDWR);
fs.read(gate,Buffer.alloc(1),0,1,null,error=>{if(error)throw error;fs.closeSync(gate);});
const a=fs.openSync(base+'/source','r'),b=fs.openSync(base+'/destination','r');
addon.publishDirectoryExclusive(a,'stage',b,'entry',(error,published)=>{if(error)throw error;console.log(JSON.stringify({published,external:fs.readdirSync(base+'/destination/entry'),source:fs.readFileSync(base+'/source/stage/payload','utf8')}));});
cp.execFileSync(process.execPath,['-e',\"require('node:fs').mkdirSync(process.argv[1])\",base+'/destination/entry']);fs.closeSync(a);fs.closeSync(b);fs.writeSync(gate,Buffer.from('x'));`;
  try {
    const result = JSON.parse(execFileSync(process.execPath, ["-e", script, artifact, f.base], { encoding: "utf8", env: { ...process.env, UV_THREADPOOL_SIZE: "1" } }));
    expect(result).toEqual({ published: false, external: [], source: "owned bytes" });
  } finally { await f.close(); }
});

it("releases duplicated descriptors after repeated refused publications", async () => {
  const f = await scope("descriptor-release"); await mkdir(join(f.destination, "entry"));
  const script = `const fs=require('node:fs'),addon=require(process.argv[1]),base=process.argv[2];
const a=fs.openSync(base+'/source','r'),b=fs.openSync(base+'/destination','r'),count=()=>fs.readdirSync('/dev/fd').length;
(async()=>{const before=count();for(let i=0;i<500;i++)await new Promise((resolve,reject)=>addon.publishDirectoryExclusive(a,'stage',b,'entry',(error,published)=>error?reject(error):published?reject(Error('clobbered')):resolve())); console.log(JSON.stringify({before,after:count()}));fs.closeSync(a);fs.closeSync(b);})().catch(error=>{console.error(error);process.exitCode=1;});`;
  try {
    const result = JSON.parse(execFileSync(process.execPath, ["-e", script, artifact, f.base], { encoding: "utf8" }));
    expect(result.after).toBe(result.before);
  } finally { await f.close(); }
});

it("joins queued native work and releases descriptors when a caller worker is terminated", async () => {
  const f = await scope("worker-termination"); await mkdir(join(f.destination, "entry"));
  const script = `const fs=require('node:fs'),cp=require('node:child_process'),{Worker}=require('node:worker_threads'),{once}=require('node:events'),artifact=process.argv[1],base=process.argv[2],count=()=>fs.readdirSync('/dev/fd').length;
(async()=>{await new Worker(' ',{eval:true}).terminate();cp.execFileSync('/usr/bin/mkfifo',[base+'/gate']);const gate=fs.openSync(base+'/gate',fs.constants.O_RDWR);const before=count();
const worker=new Worker(\`const fs=require('node:fs'),{parentPort,workerData}=require('node:worker_threads'),addon=require(workerData.artifact);const a=fs.openSync(workerData.base+'/source','r'),b=fs.openSync(workerData.base+'/destination','r'); fs.read(workerData.gate,Buffer.alloc(1),0,1,null,()=>{});for(let i=0;i<100;i++)addon.publishDirectoryExclusive(a,'stage',b,'entry',()=>{});parentPort.postMessage('accepted');\`,{eval:true,workerData:{artifact,base,gate}});
await once(worker,'message');const terminating=worker.terminate();fs.writeSync(gate,Buffer.from('x'));await terminating; console.log(JSON.stringify({before,after:count(),external:fs.readdirSync(base+'/destination/entry')}));fs.closeSync(gate);})().catch(error=>{console.error(error);process.exitCode=1;});`;
  try {
    const result = JSON.parse(execFileSync(process.execPath, ["-e", script, artifact, f.base], { encoding: "utf8", env: { ...process.env, UV_THREADPOOL_SIZE: "1" } }));
    expect(result.after).toBe(result.before); expect(result.external).toEqual([]);
  } finally { await f.close(); }
});

it("refuses traversal and unsafe source entries without moving anything", async () => {
  const f = await scope("refusals");
  try {
    await expect(f.publish("../escape")).rejects.toThrow(); await expect(f.publish("bad\0leaf")).rejects.toThrow();
    await rm(join(f.source, "stage"), { recursive: true }); await symlink(f.destination, join(f.source, "stage"));
    await expect(f.publish()).rejects.toHaveProperty("errno"); expect(await readdir(f.destination)).toEqual([]);
  } finally { await f.close(); }
});
