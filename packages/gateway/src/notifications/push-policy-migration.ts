import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { validateNotificationDocument } from "./grant-store.js";

const BOUNDED_BYTES = 1_048_576;
const hash = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const digest = (bytes: Buffer | null) => bytes === null ? null : hash(bytes);
const encode = (value: unknown) => Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");

interface Change { path: string; before: Buffer | null; after: Buffer }
export interface PushPolicyPlan { changes: Change[]; policy?: { inputNeeded: boolean; finished: boolean; waiting: boolean } }
interface Manifest { version: 1; files: { path: string; before: string | null; after: string }[] }

async function readBounded(path: string): Promise<Buffer | null> {
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!info) return null;
  if (!info.isFile() || info.size > BOUNDED_BYTES) throw new Error(`${path} is not a bounded regular file`);
  return readFile(path);
}

export async function planPushPolicyMigration(tronHome: string): Promise<PushPolicyPlan> {
  const documentPath = tronHomePath(tronHome, "state/notifications.json");
  const settingsPath = tronHomePath(tronHome, "state/settings/gateway.json");
  const documentBefore = await readBounded(documentPath);
  if (documentBefore === null) return { changes: [] };
  const document = JSON.parse(documentBefore.toString("utf8")) as Record<string, unknown>;
  if (document.version === 3) return { changes: [] };
  const policy = document.policy as Record<string, unknown> | undefined;
  if (document.version !== 2 || !policy || typeof policy.notifyWhenAskPresented !== "boolean"
    || typeof policy.notifyWhenFinished !== "boolean" || typeof policy.notifyWhenWaiting !== "boolean") {
    throw new Error(`${documentPath} is not a version 2 notification store with three policy booleans`);
  }
  const { policy: _retired, ...rest } = document;
  const documentAfter = encode(validateNotificationDocument({ ...rest, version: 3 }));
  const settingsBefore = await readBounded(settingsPath);
  const settings = settingsBefore === null ? {} : JSON.parse(settingsBefore.toString("utf8")) as Record<string, unknown>;
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) throw new Error(`${settingsPath} is not a JSON object`);
  const notifications = (settings.notifications ?? {}) as Record<string, unknown>;
  const push = {
    ...(notifications.push as Record<string, unknown> | undefined),
    inputNeeded: policy.notifyWhenAskPresented, finished: policy.notifyWhenFinished, waiting: policy.notifyWhenWaiting,
  };
  const settingsAfter = encode({ ...settings, notifications: { ...notifications, push } });
  return {
    changes: [
      { path: settingsPath, before: settingsBefore, after: settingsAfter },
      { path: documentPath, before: documentBefore, after: documentAfter },
    ],
    policy: { inputNeeded: policy.notifyWhenAskPresented, finished: policy.notifyWhenFinished, waiting: policy.notifyWhenWaiting },
  };
}

async function publish(path: string, bytes: Buffer, expected: Buffer | null): Promise<void> {
  if (digest(await readBounded(path)) !== digest(expected)) throw new Error(`${path} changed since it was read; rerun with a new backup directory`);
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.migration-${process.pid}.tmp`;
  const handle = await open(temporary, "wx", 0o600);
  try {
    try { await handle.writeFile(bytes); await syncDurably(handle); } finally { await handle.close(); }
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
  const directory = await open(dirname(path), "r");
  try { await syncDurably(directory); } finally { await directory.close(); }
}

export async function applyPushPolicyMigration(plan: PushPolicyPlan, backup: string): Promise<boolean> {
  if (plan.changes.length === 0) return false;
  await mkdir(backup, { recursive: true, mode: 0o700 });
  if ((await readdir(backup)).length) throw new Error(`Backup directory ${backup} is not empty`);
  for (const change of plan.changes) {
    if (change.before === null) continue;
    const original = join(backup, basename(change.path));
    await copyFile(change.path, original, constants.COPYFILE_EXCL);
    if (!(await readFile(original)).equals(change.before)) throw new Error(`${change.path} changed while it was backed up; rerun with a new backup directory`);
  }
  const manifest: Manifest = {
    version: 1,
    files: plan.changes.map(change => ({ path: change.path, before: digest(change.before), after: hash(change.after) })),
  };
  await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  for (const change of plan.changes) await publish(change.path, change.after, change.before);
  return true;
}

export async function restorePushPolicyMigration(backup: string): Promise<boolean> {
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as Manifest;
  let restored = false;
  for (const file of manifest.files) {
    const current = await readBounded(file.path);
    if (digest(current) === file.before) continue;
    if (digest(current) !== file.after || current === null) throw new Error(`${file.path} changed after the migration; restore it by hand from ${backup}`);
    if (file.before === null) {
      await rm(file.path, { force: true });
    } else {
      const original = await readFile(join(backup, basename(file.path)));
      if (digest(original) !== file.before) throw new Error("The backup does not match its manifest");
      await publish(file.path, original, current);
    }
    restored = true;
  }
  return restored;
}

const USAGE = "usage: migrate push-policy --tron-home <dir> [--apply --backup <new dir>] | --restore --backup <dir>\n";

async function main(argv: readonly string[]): Promise<number> {
  const options = new Map<string, string>(); const flags = new Set<string>();
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (argument === "--apply" || argument === "--restore") flags.add(argument);
    else if ((argument === "--tron-home" || argument === "--backup") && argv[index + 1] !== undefined) options.set(argument, argv[++index]!);
    else { process.stderr.write(`unknown argument ${argument}\n${USAGE}`); return 64; }
  }
  const backup = options.get("--backup");
  if (flags.has("--restore")) {
    if (!backup) { process.stderr.write(USAGE); return 64; }
    process.stdout.write(`${JSON.stringify({ restored: await restorePushPolicyMigration(resolve(backup)) })}\n`);
    return 0;
  }
  const tronHome = options.get("--tron-home");
  if (!tronHome || (flags.has("--apply") && !backup)) { process.stderr.write(USAGE); return 64; }
  const plan = await planPushPolicyMigration(resolve(tronHome));
  process.stdout.write(`plan ${JSON.stringify({ policy: plan.policy, files: plan.changes.map(change => change.path) })}\n`);
  if (flags.has("--apply")) process.stdout.write(`${JSON.stringify({ applied: await applyPushPolicyMigration(plan, resolve(backup!)) })}\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
