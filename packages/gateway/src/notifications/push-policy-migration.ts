import { createHash, randomBytes } from "node:crypto";
import type { Stats } from "node:fs";
import { lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveAgentDir } from "../config.js";
import { GatewayError } from "../errors.js";
import { syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { acquireAgentRuntimeLock } from "../sessions/agent-runtime-lock.js";
import { validateNotificationDocument } from "./grant-store.js";

const BOUNDED_BYTES = 1_048_576;
const MANIFEST = "manifest.json";
const FILES = [
  { path: "state/settings/gateway.json", name: "gateway.json" },
  { path: "state/notifications.json", name: "notifications.json" },
] as const;
const SHA256 = /^[a-f0-9]{64}$/u;

interface Change { path: string; name: string; before: Buffer | null; after: Buffer }
interface Entry { path: string; before: string | null; after: string }
interface Manifest { version: 1; files: Entry[] }

const hash = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex");
const digest = (bytes: Buffer | null): string | null => bytes === null ? null : hash(bytes);
const encode = (value: unknown): Buffer => Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");
const conflict = (message: string): GatewayError => new GatewayError("conflict", message);

function backupDirectory(tronHome: string): string {
  return tronHomePath(tronHome, "state/migrations", "push-policy-v3");
}

async function status(path: string): Promise<Stats | undefined> {
  return lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
}

async function readBounded(path: string): Promise<Buffer | null> {
  const info = await status(path);
  if (!info) return null;
  if (!info.isFile() || info.size > BOUNDED_BYTES || info.uid !== process.getuid?.()) {
    throw conflict(`${path} is not an owned bounded regular file`);
  }
  return readFile(path);
}

async function ownedDirectory(path: string): Promise<boolean> {
  const info = await status(path);
  if (!info) return false;
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.()) {
    throw conflict(`${path} must be an owner-only directory, not a link or another owner's`);
  }
  return true;
}

async function syncDirectory(path: string): Promise<void> {
  const directory = await open(path, "r");
  try { await syncDurably(directory); } finally { await directory.close(); }
}

async function writeDurable(path: string, bytes: Buffer): Promise<void> {
  const handle = await open(path, "wx", 0o600);
  try {
    await handle.chmod(0o600);
    await handle.writeFile(bytes);
    await syncDurably(handle);
  } finally { await handle.close(); }
}

function validManifest(value: unknown): Manifest | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const manifest = value as Record<string, unknown>;
  if (Object.keys(manifest).sort().join() !== "files,version" || manifest.version !== 1 || !Array.isArray(manifest.files)) return undefined;
  if (manifest.files.length !== FILES.length) return undefined;
  for (const [index, entry] of manifest.files.entries()) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return undefined;
    const item = entry as Record<string, unknown>;
    if (Object.keys(item).sort().join() !== "after,before,path" || item.path !== FILES[index]!.path) return undefined;
    if (typeof item.after !== "string" || !SHA256.test(item.after)) return undefined;
    if (item.before !== null && (typeof item.before !== "string" || !SHA256.test(item.before))) return undefined;
    if (index === 1 && item.before === null) return undefined;
  }
  return manifest as unknown as Manifest;
}

async function readReceipt(directory: string): Promise<Manifest | undefined> {
  const path = join(directory, MANIFEST);
  const info = await status(path);
  if (!info || !info.isFile() || info.isSymbolicLink() || info.size > BOUNDED_BYTES) return undefined;
  try { return validManifest(JSON.parse(await readFile(path, "utf8"))); }
  catch { return undefined; }
}

async function backupIntact(directory: string, receipt: Manifest): Promise<boolean> {
  for (const entry of receipt.files) {
    if (entry.before === null) continue;
    const name = FILES.find(file => file.path === entry.path)!.name;
    const bytes = await readBounded(join(directory, name)).catch(() => null);
    if (digest(bytes) !== entry.before) return false;
  }
  return true;
}

function planChanges(documentBefore: Buffer, settingsBefore: Buffer | null): Change[] {
  const document = JSON.parse(documentBefore.toString("utf8")) as Record<string, unknown>;
  const policy = document.policy as Record<string, unknown> | undefined;
  if (document.version !== 2 || !policy || typeof policy.notifyWhenAskPresented !== "boolean"
    || typeof policy.notifyWhenFinished !== "boolean" || typeof policy.notifyWhenWaiting !== "boolean") {
    throw conflict("Notification state is not a version 2 store with three policy booleans");
  }
  const { policy: _retired, ...rest } = document;
  const settings = settingsBefore === null ? {} : JSON.parse(settingsBefore.toString("utf8")) as Record<string, unknown>;
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) throw conflict("Gateway settings are not a JSON object");
  const notifications = (settings.notifications ?? {}) as Record<string, unknown>;
  const push = {
    ...(notifications.push as Record<string, unknown> | undefined),
    inputNeeded: policy.notifyWhenAskPresented, finished: policy.notifyWhenFinished, waiting: policy.notifyWhenWaiting,
  };
  return [
    { path: FILES[0].path, name: FILES[0].name, before: settingsBefore, after: encode({ ...settings, notifications: { ...notifications, push } }) },
    { path: FILES[1].path, name: FILES[1].name, before: documentBefore, after: encode(validateNotificationDocument({ ...rest, version: 3 })) },
  ];
}

async function publish(path: string, bytes: Buffer, expected: Buffer | null): Promise<void> {
  if (digest(await readBounded(path)) !== digest(expected)) throw conflict(`${path} changed during the push policy migration`);
  const temporary = `${path}.migration-${process.pid}.tmp`;
  try {
    await writeDurable(temporary, bytes);
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
  await syncDirectory(dirname(path));
}

async function writeBackup(tronHome: string, changes: Change[]): Promise<void> {
  const directory = backupDirectory(tronHome);
  await mkdir(dirname(directory), { recursive: true, mode: 0o700 });
  await mkdir(directory, { mode: 0o700 });
  for (const change of changes) {
    if (change.before !== null) await writeDurable(join(directory, change.name), change.before);
  }
  await syncDirectory(directory);
  const manifest: Manifest = {
    version: 1,
    files: changes.map(change => ({ path: change.path, before: digest(change.before), after: hash(change.after) })),
  };
  const temporary = join(directory, `${MANIFEST}.tmp-${process.pid}`);
  try {
    await writeDurable(temporary, Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, "utf8"));
    await rename(temporary, join(directory, MANIFEST));
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
  await syncDirectory(directory);
  await syncDirectory(dirname(directory));
}

async function preserveIncomplete(tronHome: string): Promise<void> {
  const directory = backupDirectory(tronHome);
  const stamp = `${new Date().toISOString().replace(/[:.]/gu, "-")}-${randomBytes(4).toString("hex")}`;
  await rename(directory, `${directory}.incomplete-${stamp}`);
  await syncDirectory(dirname(directory));
}

async function backupOriginals(directory: string, receipt: Manifest): Promise<Map<string, Buffer | null>> {
  const originals = new Map<string, Buffer | null>();
  for (const entry of receipt.files) {
    originals.set(entry.path, entry.before === null ? null : await readBounded(join(directory, FILES.find(file => file.path === entry.path)!.name)));
  }
  return originals;
}

function sameTargets(changes: Change[], receipt: Manifest): boolean {
  return changes.every((change, index) => receipt.files[index]!.path === change.path && receipt.files[index]!.after === hash(change.after));
}

export async function migratePushPolicy(tronHome: string): Promise<boolean> {
  const documentBefore = await readBounded(tronHomePath(tronHome, "state/notifications.json"));
  if (documentBefore === null) return false;
  let version: unknown;
  try { version = (JSON.parse(documentBefore.toString("utf8")) as { version?: unknown }).version; }
  catch { throw conflict("Notification state is malformed"); }
  if (version === 3) return false;
  const directory = backupDirectory(tronHome);
  const settingsPath = tronHomePath(tronHome, "state/settings/gateway.json");
  if (await ownedDirectory(directory)) {
    const receipt = await readReceipt(directory);
    if (receipt && await backupIntact(directory, receipt)) {
      const originals = await backupOriginals(directory, receipt);
      const changes = planChanges(originals.get(FILES[1].path)!, originals.get(FILES[0].path) ?? null);
      if (sameTargets(changes, receipt)) {
        const pending: Change[] = [];
        for (const [index, change] of changes.entries()) {
          const current = digest(await readBounded(join(tronHome, change.path)));
          const entry = receipt.files[index]!;
          if (current === entry.before) pending.push(change);
          else if (current !== entry.after) throw conflict(`${change.path} changed after its push policy backup; restore it by hand from ${directory}`);
        }
        for (const change of pending) await publish(join(tronHome, change.path), change.after, change.before);
        return true;
      }
    } else if (receipt) {
      const current = await Promise.all(receipt.files.map(entry => readBounded(join(tronHome, entry.path))));
      if (current.some((bytes, index) => digest(bytes) !== null && digest(bytes) === receipt.files[index]!.after)) {
        throw conflict(`The push policy migration was interrupted with an unreadable backup; restore it by hand from ${directory}`);
      }
    }
    await preserveIncomplete(tronHome);
  }
  const changes = planChanges(documentBefore, await readBounded(settingsPath));
  await writeBackup(tronHome, changes);
  for (const change of changes) await publish(join(tronHome, change.path), change.after, change.before);
  return true;
}

export async function restorePushPolicyMigration(tronHome: string, agentDir: string): Promise<boolean> {
  const release = await acquireAgentRuntimeLock(agentDir);
  try {
    const directory = backupDirectory(tronHome);
    if (!await ownedDirectory(directory)) throw conflict("No push policy backup exists; nothing changed");
    const receipt = await readReceipt(directory);
    if (!receipt || !await backupIntact(directory, receipt)) throw conflict(`The push policy backup in ${directory} is incomplete; nothing changed`);
    const actions: Array<{ path: string; action: "keep" | "write" | "remove"; bytes: Buffer | null; expected: Buffer | null }> = [];
    for (const entry of receipt.files) {
      const path = join(tronHome, entry.path);
      const current = await readBounded(path);
      if (digest(current) === entry.before) { actions.push({ path, action: "keep", bytes: null, expected: current }); continue; }
      if (digest(current) !== entry.after) throw conflict(`${path} changed after the migration; restore it by hand from ${directory}`);
      if (entry.before === null) actions.push({ path, action: "remove", bytes: null, expected: current });
      else {
        const name = FILES.find(file => file.path === entry.path)!.name;
        actions.push({ path, action: "write", bytes: await readFile(join(directory, name)), expected: current });
      }
    }
    let restored = false;
    for (const action of [...actions].reverse()) {
      if (action.action === "keep") continue;
      if (action.action === "remove") await rm(action.path, { force: true });
      else await publish(action.path, action.bytes!, action.expected);
      restored = true;
    }
    return restored;
  } finally {
    await release();
  }
}

const USAGE = "usage: migrate push-policy --restore --tron-home <dir>\n";

async function main(argv: readonly string[]): Promise<number> {
  const index = argv.indexOf("--tron-home");
  const tronHome = index >= 0 ? argv[index + 1] : undefined;
  if (argv.length !== 3 || argv[0] !== "--restore" || !tronHome || tronHome.startsWith("--")) {
    process.stderr.write(USAGE);
    return 64;
  }
  const home = resolve(tronHome);
  process.stdout.write(`${JSON.stringify({ restored: await restorePushPolicyMigration(home, resolveAgentDir(home)) })}\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
