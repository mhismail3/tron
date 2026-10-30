import { spawn } from "node:child_process";
import { once } from "node:events";
import { writeFile, utimes } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { waitFor } from "./wait-for.js";
import type { ProfileAssignment } from "../src/knowledge/knowledge-notes.js";

/** A real process heap ceiling proves deep-history admission is incremental,
 * rather than merely checking the final encoded backup after unbounded loading. */
export async function boundedProfilePartition(root: string, home: string, assignments: ProfileAssignment[], mode: "migrate" | "reorganize") {
  const hook = join(root, "bounded-hook.mjs"), program = join(root, "bounded-child.mjs"), input = join(root, "bounded-input.json");
  await writeFile(input, JSON.stringify({ assignments, mode }));
  await writeFile(hook, `import { registerHooks } from 'node:module';
registerHooks({ resolve(specifier, context, next) { try { return next(specifier, context); } catch (error) { if (specifier.endsWith('.js')) return next(specifier.slice(0,-3)+'.ts',context); throw error; } } });
`);
  const storeModule = fileURLToPath(new URL("../src/knowledge/knowledge-store.ts", import.meta.url));
  const workspaceModule = fileURLToPath(new URL("../src/workspace/tron-workspace.ts", import.meta.url));
  await writeFile(program, `import fs from 'node:fs/promises';
const [home,input] = process.argv.slice(2);
const { KnowledgeStore } = await import(${JSON.stringify(storeModule)});
const { TronWorkspace } = await import(${JSON.stringify(workspaceModule)});
const workspace = new TronWorkspace(home);
await workspace.initialize();
let result;
try {
  const { assignments, mode } = JSON.parse(await fs.readFile(input,'utf8'));
  await new KnowledgeStore(workspace).partitionProfile({commandId:'partition-bounded-command',mode,assignments});
  result = {status:'unexpected-commit'};
} catch (error) {
  if (error.code !== 'conflict') throw error;
  result = {status:'refused',message:error.message};
} finally { await workspace.dispose(); }
process.stdout.write(JSON.stringify(result));
`);
  const child = spawn(process.execPath, ["--max-old-space-size=96", "--experimental-transform-types", "--import", hook, program, home, input], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", chunk => { stdout += String(chunk); }); child.stderr.on("data", chunk => { stderr += String(chunk); });
  const [code, signal] = await once(child, "exit");
  return { code, signal, stdout, stderr };
}

/** Test-owned subprocess cuts at real filesystem/SQLite boundaries. It never
 * opens a live workspace or alters a production fault-injection surface. */
export async function crashProfilePartition(root: string, home: string, assignments: ProfileAssignment[], cut: string, forget?: { recordId: string; expectedRevision: string }, audit?: { context: unknown; undoChangeId?: string }): Promise<void> {
  const hook = join(root, "partition-hook.mjs"), program = join(root, "partition-child.mjs"), input = join(root, "partition-input.json");
  await writeFile(input, JSON.stringify({ assignments, forget, audit }));
  await writeFile(hook, `import { registerHooks } from 'node:module';
registerHooks({ resolve(specifier, context, next) { try { return next(specifier, context); } catch (error) { if (specifier.endsWith('.js')) return next(specifier.slice(0,-3)+'.ts',context); throw error; } } });
`);
  const storeModule = fileURLToPath(new URL("../src/knowledge/knowledge-store.ts", import.meta.url));
  const workspaceModule = fileURLToPath(new URL("../src/workspace/tron-workspace.ts", import.meta.url));
  const modules = Object.fromEntries(Object.entries({ profile: "../src/modules/home/home-profile.ts", service: "../src/knowledge/knowledge-service.ts", change: "../src/kernel/settings/settings-change.ts", model: "../src/kernel/settings/settings-model.ts", record: "../src/kernel/settings/settings-record.ts", adapter: "../src/admin/settings-model.ts", schema: "./settings-schema.ts", trust: "../src/kernel/resources/trust-service.ts" }).map(([key, path]) => [key, fileURLToPath(new URL(path, import.meta.url))]));
  const sdk = import.meta.resolve("@earendil-works/pi-coding-agent");
  await writeFile(program, `import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { DatabaseSync } from 'node:sqlite';
const [home,input,cut] = process.argv.slice(2);
const {assignments,forget,audit} = JSON.parse(await fs.readFile(input,'utf8'));
let written = 0;
const park = () => { process.stdout.write('partition-crash-window\\n'); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0); };
const open = fs.open, rename = fs.rename, exec = DatabaseSync.prototype.exec;
fs.open = async function(path,...args) {
  if (cut === 'before-backup' && String(path).includes('/profile-backups/') && String(path).endsWith('.tmp')) park();
  if (cut === 'after-backup' && String(path).includes('/records/') && String(path).endsWith('.tmp')) park();
  return open.call(this,path,...args);
};
fs.rename = async function(from,to) {
  const result = await rename.call(this,from,to);
  if (String(to).includes('/records/') && String(to).endsWith('.json')) { written++; if (cut === 'mid-body' && written === (audit ? 1 : 7)) park(); }
  return result;
};
DatabaseSync.prototype.exec = function(sql) {
  if (sql === 'COMMIT' && written && cut === 'precommit') park();
  const result = exec.call(this,sql);
  if (sql === 'COMMIT' && written && cut === 'after-commit') park();
  return result;
};
syncBuiltinESMExports();
const { KnowledgeStore } = await import(${JSON.stringify(storeModule)});
const { TronWorkspace } = await import(${JSON.stringify(workspaceModule)});
const workspace = new TronWorkspace(home);
await workspace.initialize();
const store = new KnowledgeStore(workspace);
if (forget) await store.forget('partition-child-forget',forget.recordId,'Explicit fixture forget',forget.expectedRevision);
else if (audit) {
  const modules = ${JSON.stringify(modules)};
  const { HomeProfileItems } = await import(modules.profile);
  const { KnowledgeService } = await import(modules.service);
  const { SettingsChangePath } = await import(modules.change);
  const { SettingsModel } = await import(modules.model);
  const { SettingsChangeRecord } = await import(modules.record);
  const { SettingsStoreAdapter } = await import(modules.adapter);
  const { TEST_SETTINGS_SCHEMA } = await import(modules.schema);
  const { TrustService } = await import(modules.trust);
  const { ModelRuntime } = await import(${JSON.stringify(sdk)});
  const modelRuntime = await ModelRuntime.create({authPath:home+'/child-auth.json',modelsPath:null,refreshOnCreate:false});
  const knowledge = new KnowledgeService(store);
  const profile = new HomeProfileItems(() => knowledge);
  const model = new SettingsModel(new SettingsStoreAdapter({schema:TEST_SETTINGS_SCHEMA,agentDir:home+'/agent',tronHome:home,trust:new TrustService(home+'/agent'),modelRuntime}));
  const changes = new SettingsChangePath(model,new SettingsChangeRecord(home),{setTrust:async()=>{throw new Error('Not used');},undoSubject:(entry,context)=>profile.undo(changes,entry,context)});
  if (audit.undoChangeId) await changes.undo(audit.undoChangeId,audit.context);
  else await profile.partition(changes,{commandId:audit.context.commandId,mode:'migrate',assignments},audit.context);
} else await store.partitionProfile({ commandId:'partition-child-command', mode:'migrate', assignments });
await workspace.dispose();
throw new Error('Requested crash cut was not reached');
`);
  const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, home, input, cut], { stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  child.stdout.on("data", chunk => { output += String(chunk); }); child.stderr.on("data", chunk => { output += String(chunk); });
  try {
    await waitFor(() => {
      if (output.includes("partition-crash-window")) return true;
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Partition child exited before ${cut}: ${output}`);
      return undefined;
    }, `partition child at ${cut}`);
  } finally {
    if (child.exitCode === null && child.signalCode === null) { const exited = once(child, "exit"); child.kill("SIGKILL"); await exited; }
  }
  // Only this killed fixture's stale workspace lease is aged, as in existing
  // real-process recovery tests. No foreign lease or live runtime is touched.
  const past = new Date(Date.now() - 120_000);
  await utimes(join(home, "gateway", "workspace-state.lock"), past, past);
}
