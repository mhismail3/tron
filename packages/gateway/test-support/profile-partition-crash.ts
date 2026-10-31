import { spawn } from "node:child_process";
import { once } from "node:events";
import { writeFile, utimes } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { waitFor } from "./wait-for.js";
import type { ProfileAssignment } from "../src/modules/home/profile-notes.js";

const storeModule = fileURLToPath(new URL("../src/modules/home/profile-store.ts", import.meta.url));
const workspaceModule = fileURLToPath(new URL("../src/workspace/tron-workspace.ts", import.meta.url));
async function loader(root: string) {
  const path = join(root, "profile-loader.mjs");
  await writeFile(path, `import { registerHooks } from 'node:module';
registerHooks({ resolve(specifier, context, next) { try { return next(specifier, context); } catch (error) { if (specifier.endsWith('.js')) return next(specifier.slice(0,-3)+'.ts',context); throw error; } } });\n`);
  return path;
}
/** A real heap ceiling proves current-file admission is independent of retired
 * history. The caller owns a sealed synthetic archive outside the workspace. */
export async function boundedProfilePartition(root: string, home: string, assignments: ProfileAssignment[], mode: "migrate" | "reorganize") {
  const hook = await loader(root), program = join(root, "bounded-child.mjs"), input = join(root, "bounded-input.json");
  await writeFile(input, JSON.stringify({ assignments, mode }));
  await writeFile(program, `import fs from 'node:fs/promises';
const [home,input] = process.argv.slice(2);
const { ProfileStore } = await import(${JSON.stringify(storeModule)});
const { TronWorkspace } = await import(${JSON.stringify(workspaceModule)});
const workspace = new TronWorkspace(home); await workspace.initialize();
try { const {assignments,mode}=JSON.parse(await fs.readFile(input,'utf8'));
 const result=await new ProfileStore(workspace).partitionProfile({commandId:'partition-bounded-command',mode,assignments});
 process.stdout.write(JSON.stringify({status:'committed',changes:result.changes.length}));
} finally { await workspace.dispose(); }
`);
  const child = spawn(process.execPath, ["--max-old-space-size=96", "--experimental-transform-types", "--import", hook, program, home, input], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", chunk => { stdout += String(chunk); }); child.stderr.on("data", chunk => { stderr += String(chunk); });
  const [code, signal] = await once(child, "exit");
  return { code, signal, stdout, stderr };
}

/** Test-only instrumentation delegates every real journal/file operation and
 * SIGKILLs only its owned subprocess at observed durability boundaries. */
export async function crashProfilePartition(root: string, home: string, assignments: ProfileAssignment[], cut: string, audit: { context: unknown; undoChangeId?: string; mode?: "migrate" | "reorganize" }): Promise<void> {
  const hook = await loader(root), program = join(root, "partition-child.mjs"), input = join(root, "partition-input.json");
  await writeFile(input, JSON.stringify({ assignments, audit }));
  const modules = Object.fromEntries(Object.entries({ profile: "../src/modules/home/home-profile.ts", change: "../src/kernel/settings/settings-change.ts", model: "../src/kernel/settings/settings-model.ts", record: "../src/kernel/settings/settings-record.ts", adapter: "../src/admin/settings-model.ts", schema: "./settings-schema.ts", trust: "../src/kernel/resources/trust-service.ts" }).map(([key, path]) => [key, fileURLToPath(new URL(path, import.meta.url))]));
  await writeFile(program, `import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
const [home,input,cut] = process.argv.slice(2);
const {assignments,audit} = JSON.parse(await fs.readFile(input,'utf8'));
const park=()=>{process.stdout.write('partition-crash-window\\n');Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0);};
let prepared=false;
const open=fs.open,rename=fs.rename;
fs.open=async function(path,...args){
 if(String(path).includes('/files/Profile.json.')&&String(path).endsWith('.tmp')&&((cut==='before-intent'&&!prepared)||(cut==='before-domain'&&prepared)))park();
 return open.call(this,path,...args);
};
fs.rename=async function(from,to){
 if(cut==='staged-domain'&&prepared&&String(to).endsWith('/files/Profile.json'))park();
 const result=await rename.call(this,from,to);
 if(String(to).endsWith('/files/Profile.json')){
  const doc=JSON.parse(await fs.readFile(to,'utf8'));const receipt=doc.control.commands['knowledge.profile.partition'+String.fromCharCode(0)+audit.context.commandId];
  if((cut==='after-intent'&&receipt?.partition)||(cut==='after-domain'&&receipt?.result&&receipt.auditPending)||(cut==='after-ack'&&receipt?.result&&receipt.audit&&!receipt.auditPending))park();
 }
 return result;
};syncBuiltinESMExports();
const {ProfileStore}=await import(${JSON.stringify(storeModule)});
const {TronWorkspace}=await import(${JSON.stringify(workspaceModule)});
const modules=${JSON.stringify(modules)};
const {HomeProfileItems}=await import(modules.profile);
const {SettingsChangePath}=await import(modules.change);
const {SettingsModel}=await import(modules.model);
const {SettingsChangeRecord}=await import(modules.record);
const {SettingsStoreAdapter}=await import(modules.adapter);
const {TEST_SETTINGS_SCHEMA}=await import(modules.schema);
const {TrustService}=await import(modules.trust);
const {ModelRuntime}=await import(${JSON.stringify(import.meta.resolve("@earendil-works/pi-coding-agent"))});
const append=SettingsChangeRecord.prototype.appendOnce;
SettingsChangeRecord.prototype.appendOnce=async function(entries){
 if(entries[0]?.status==='applied'&&cut==='before-publication')park();
 const result=await append.call(this,entries);
 if(entries[0]?.status==='started'){prepared=true;if(cut==='after-prepare')park();}
 if(entries[0]?.status==='applied'&&cut==='after-publication')park();
 return result;
};
const workspace=new TronWorkspace(home);await workspace.initialize();
const store=new ProfileStore(workspace),profile=new HomeProfileItems(()=>store);
const modelRuntime=await ModelRuntime.create({authPath:home+'/child-auth.json',modelsPath:null,refreshOnCreate:false});
const model=new SettingsModel(new SettingsStoreAdapter({schema:TEST_SETTINGS_SCHEMA,agentDir:home+'/agent',tronHome:home,trust:new TrustService(home+'/agent'),modelRuntime}));
const changes=new SettingsChangePath(model,new SettingsChangeRecord(home),{setTrust:async()=>{throw new Error('Not used');},undoSubject:(entry,context)=>profile.undo(changes,entry,context)});
if(audit.undoChangeId)await changes.undo(audit.undoChangeId,audit.context);
else await profile.partition(changes,{commandId:audit.context.commandId,mode:audit.mode??'migrate',assignments},audit.context);
await workspace.dispose();throw new Error('Requested crash cut was not reached');
`);
  const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, home, input, cut], { stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  child.stdout.on("data", chunk => { output += String(chunk); }); child.stderr.on("data", chunk => { output += String(chunk); });
  try {
    await waitFor(() => { if (output.includes("partition-crash-window")) return true; if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Partition child exited before ${cut}: ${output}`); return undefined; }, `partition child at ${cut}`);
  } finally {
    if (child.exitCode === null && child.signalCode === null) { const exited = once(child, "exit"); child.kill("SIGKILL"); await exited; }
  }
  const past = new Date(Date.now() - 120_000);
  await utimes(join(home, "gateway", "workspace-state.lock"), past, past);
}
