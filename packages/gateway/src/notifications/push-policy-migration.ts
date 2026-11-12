import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { validate } from "./grant-store.js";

const BOUNDED_BYTES = 1_048_576;
const digest = (bytes: Buffer | null) => bytes === null ? null : createHash("sha256").update(bytes).digest("hex");

export interface PushPolicyPlan {
  documentPath: string;
  settingsPath: string;
  policy?: { inputNeeded: boolean; finished: boolean; waiting: boolean };
  documentBefore?: Buffer;
  documentAfter?: Buffer;
  settingsBefore?: Buffer | null;
  settingsAfter?: Buffer;
}
interface Manifest {
  version: 1;
  documentPath: string;
  settingsPath: string;
  documentBefore: string;
  documentAfter: string;
  settingsBefore: string | null;
  settingsAfter: string;
}

async function readBounded(path: string): Promise<Buffer | null> {
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!info) return null;
  if (!info.isFile() || info.size > BOUNDED_BYTES) throw new Error(`${path} is not a bounded regular file`);
  return readFile(path);
}

export async function planPushPolicyMigration(tronHome: string): Promise<PushPolicyPlan> {
  const documentPath = tronHomePath(tronHome, "gateway/notifications.json");
  const settingsPath = tronHomePath(tronHome, "gateway/settings/gateway.json");
  const plan: PushPolicyPlan = { documentPath, settingsPath };
  const documentBefore = await readBounded(documentPath);
  if (documentBefore === null) return plan;
  const document = JSON.parse(documentBefore.toString("utf8")) as Record<string, unknown>;
  if (document.version !== 2) return plan;
  const policy = document.policy as Record<string, unknown> | undefined;
  if (!policy || typeof policy.notifyWhenAskPresented !== "boolean" || typeof policy.notifyWhenFinished !== "boolean" || typeof policy.notifyWhenWaiting !== "boolean") {
    throw new Error(`${documentPath} has a version 2 policy that is not three booleans`);
  }
  const { policy: _retired, ...rest } = document;
  const after = { ...rest, version: 3 };
  validate(after);
  const settingsBefore = await readBounded(settingsPath);
  const settings = settingsBefore === null ? {} : JSON.parse(settingsBefore.toString("utf8")) as Record<string, unknown>;
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) throw new Error(`${settingsPath} is not a JSON object`);
  const push = { ...(settings.notifications as Record<string, unknown> | undefined)?.push as Record<string, unknown> | undefined };
  push.inputNeeded = policy.notifyWhenAskPresented;
  push.finished = policy.notifyWhenFinished;
  push.waiting = policy.notifyWhenWaiting;
  const settingsAfter = Buffer.from(`${JSON.stringify({ ...settings, notifications: { ...(settings.notifications as object | undefined), push } }, null, 2)}\n`, "utf8");
  return {
    ...plan,
    policy: { inputNeeded: policy.notifyWhenAskPresented, finished: policy.notifyWhenFinished, waiting: policy.notifyWhenWaiting },
    documentBefore, documentAfter: Buffer.from(`${JSON.stringify(after, null, 2)}\n`, "utf8"),
    settingsBefore, settingsAfter,
  };
}

async function publish(path: string, bytes: Buffer, expected: Buffer | null): Promise<void> {
  const current = await readBounded(path);
  if (digest(current) !== digest(expected)) throw new Error(`${path} changed since it was read; rerun with a new backup directory`);
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
  if (!plan.documentBefore || !plan.documentAfter || !plan.settingsAfter) return false;
  await mkdir(backup, { recursive: true, mode: 0o700 });
  if ((await readdir(backup)).length) throw new Error(`Backup directory ${backup} is not empty`);
  await copyFile(plan.documentPath, join(backup, "notifications.json"), constants.COPYFILE_EXCL);
  if (plan.settingsBefore !== null && plan.settingsBefore !== undefined) {
    await copyFile(plan.settingsPath, join(backup, "gateway.json"), constants.COPYFILE_EXCL);
  }
  if (!(await readFile(join(backup, "notifications.json"))).equals(plan.documentBefore)) throw new Error(`${plan.documentPath} changed while it was backed up; rerun with a new backup directory`);
  const manifest: Manifest = {
    version: 1, documentPath: plan.documentPath, settingsPath: plan.settingsPath,
    documentBefore: digest(plan.documentBefore)!, documentAfter: digest(plan.documentAfter)!,
    settingsBefore: digest(plan.settingsBefore ?? null), settingsAfter: digest(plan.settingsAfter)!,
  };
  await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  await publish(plan.settingsPath, plan.settingsAfter, plan.settingsBefore ?? null);
  await publish(plan.documentPath, plan.documentAfter, plan.documentBefore);
  return true;
}

export async function restorePushPolicyMigration(backup: string): Promise<boolean> {
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as Manifest;
  const documentNow = await readBounded(manifest.documentPath);
  const settingsNow = await readBounded(manifest.settingsPath);
  if (digest(documentNow) === manifest.documentBefore && digest(settingsNow) === manifest.settingsBefore) return false;
  if (digest(documentNow) !== manifest.documentAfter || digest(settingsNow) !== manifest.settingsAfter) {
    throw new Error(`${manifest.documentPath} changed after the migration; restore it by hand from ${backup}`);
  }
  const originalDocument = await readFile(join(backup, "notifications.json"));
  if (digest(originalDocument) !== manifest.documentBefore) throw new Error("The backup does not match its manifest");
  if (manifest.settingsBefore !== null) {
    const originalSettings = await readFile(join(backup, "gateway.json"));
    if (digest(originalSettings) !== manifest.settingsBefore) throw new Error("The backup does not match its manifest");
    await publish(manifest.settingsPath, originalSettings, settingsNow);
  } else {
    await rm(manifest.settingsPath, { force: true });
  }
  await publish(manifest.documentPath, originalDocument, documentNow);
  return true;
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
  const { documentBefore: _a, documentAfter: _b, settingsBefore: _c, settingsAfter: _d, ...summary } = plan;
  process.stdout.write(`plan ${JSON.stringify(summary)}\n`);
  if (flags.has("--apply")) process.stdout.write(`${JSON.stringify({ applied: await applyPushPolicyMigration(plan, resolve(backup!)) })}\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
