import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { GatewayError } from "../errors.js";
import { syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { validateNotificationDocument } from "./grant-store.js";

const BOUNDED_BYTES = 1_048_576;
const hash = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex");
const digest = (bytes: Buffer | null): string | null => bytes === null ? null : hash(bytes);
const encode = (value: unknown): Buffer => Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");

interface Change { path: string; before: Buffer | null; after: Buffer }
interface Manifest { version: 1; files: { path: string; before: string | null; after: string }[] }

function paths(tronHome: string) {
  return {
    document: tronHomePath(tronHome, "state/notifications.json"),
    settings: tronHomePath(tronHome, "state/settings/gateway.json"),
    backup: tronHomePath(tronHome, "state/migrations", "push-policy-v3"),
  };
}

async function readBounded(path: string): Promise<Buffer | null> {
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!info) return null;
  if (!info.isFile() || info.size > BOUNDED_BYTES) throw new GatewayError("conflict", `${path} is not a bounded regular file`);
  return readFile(path);
}

function plan(documentBefore: Buffer, settingsBefore: Buffer | null): Change[] {
  const document = JSON.parse(documentBefore.toString("utf8")) as Record<string, unknown>;
  const policy = document.policy as Record<string, unknown> | undefined;
  if (document.version !== 2 || !policy || typeof policy.notifyWhenAskPresented !== "boolean"
    || typeof policy.notifyWhenFinished !== "boolean" || typeof policy.notifyWhenWaiting !== "boolean") {
    throw new GatewayError("conflict", "Notification state is not a version 2 store with three policy booleans");
  }
  const { policy: _retired, ...rest } = document;
  const settings = settingsBefore === null ? {} : JSON.parse(settingsBefore.toString("utf8")) as Record<string, unknown>;
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
    throw new GatewayError("conflict", "Gateway settings are not a JSON object");
  }
  const notifications = (settings.notifications ?? {}) as Record<string, unknown>;
  const push = {
    ...(notifications.push as Record<string, unknown> | undefined),
    inputNeeded: policy.notifyWhenAskPresented, finished: policy.notifyWhenFinished, waiting: policy.notifyWhenWaiting,
  };
  return [
    { path: "state/settings/gateway.json", before: settingsBefore, after: encode({ ...settings, notifications: { ...notifications, push } }) },
    { path: "state/notifications.json", before: documentBefore, after: encode(validateNotificationDocument({ ...rest, version: 3 })) },
  ];
}

async function writeBackup(tronHome: string, backup: string, changes: Change[]): Promise<void> {
  const manifest: Manifest = {
    version: 1,
    files: changes.map(change => ({ path: change.path, before: digest(change.before), after: hash(change.after) })),
  };
  await rm(backup, { recursive: true, force: true });
  await mkdir(backup, { recursive: true, mode: 0o700 });
  for (const change of changes) {
    if (change.before === null) continue;
    await copyFile(join(tronHome, change.path), join(backup, basename(change.path)), constants.COPYFILE_EXCL);
  }
  await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: "wx" });
}

async function publish(path: string, bytes: Buffer, expected: Buffer | null): Promise<void> {
  if (digest(await readBounded(path)) !== digest(expected)) throw new GatewayError("conflict", `${path} changed during the push policy migration`);
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

export async function migratePushPolicy(tronHome: string): Promise<boolean> {
  const { document, settings, backup } = paths(tronHome);
  const documentBefore = await readBounded(document);
  if (documentBefore === null) return false;
  if ((JSON.parse(documentBefore.toString("utf8")) as { version?: unknown }).version === 3) return false;
  const changes = plan(documentBefore, await readBounded(settings));
  const receipt = await readBounded(join(backup, "manifest.json"));
  const backedUp = receipt !== null && (JSON.parse(receipt.toString("utf8")) as Manifest).files[1]?.before === digest(documentBefore);
  if (!backedUp) await writeBackup(tronHome, backup, changes);
  for (const change of changes) {
    const current = await readBounded(join(tronHome, change.path));
    if (digest(current) === digest(change.after)) continue;
    await publish(join(tronHome, change.path), change.after, change.before);
  }
  return true;
}

export async function restorePushPolicyMigration(tronHome: string, backup: string): Promise<boolean> {
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as Manifest;
  let restored = false;
  for (const file of manifest.files) {
    const target = join(tronHome, file.path);
    const current = await readBounded(target);
    if (digest(current) === file.before) continue;
    if (current === null || digest(current) !== file.after) throw new GatewayError("conflict", `${target} changed after the migration; restore it by hand from ${backup}`);
    if (file.before === null) {
      await rm(target, { force: true });
    } else {
      const original = await readFile(join(backup, basename(file.path)));
      if (hash(original) !== file.before) throw new GatewayError("conflict", "The backup does not match its manifest");
      await publish(target, original, current);
    }
    restored = true;
  }
  return restored;
}

const USAGE = "usage: migrate push-policy --restore --tron-home <dir> --backup <dir>\n";

async function main(argv: readonly string[]): Promise<number> {
  const options = new Map<string, string>();
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (argument === "--restore") continue;
    if ((argument === "--tron-home" || argument === "--backup") && argv[index + 1] !== undefined) options.set(argument, argv[++index]!);
    else { process.stderr.write(`unknown argument ${argument}\n${USAGE}`); return 64; }
  }
  const tronHome = options.get("--tron-home");
  const backup = options.get("--backup");
  if (!argv.includes("--restore") || !tronHome || !backup) { process.stderr.write(USAGE); return 64; }
  process.stdout.write(`${JSON.stringify({ restored: await restorePushPolicyMigration(resolve(tronHome), resolve(backup)) })}\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
