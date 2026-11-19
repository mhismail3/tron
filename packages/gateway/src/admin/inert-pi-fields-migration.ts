import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { isDeepStrictEqual } from "node:util";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import lockfile from "proper-lockfile";
import { durableAtomicWriteText } from "../foundation/durable-json.js";
import { updateJsonLocked } from "../foundation/json.js";

const SETTINGS_MAX_BYTES = 4 * 1_048_576;
const INERT = ["theme", "hideThinkingBlock"] as const;
const digest = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
type Settings = Record<string, unknown>;

export interface InertPiFieldsPlan { path: string; fields: string[]; before?: Settings }
interface Manifest { version: 1; path: string; before: string }

function parse(bytes: Buffer, path: string): Settings {
  const value = JSON.parse(bytes.toString("utf8")) as unknown;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path} is not a JSON object`);
  return value as Settings;
}

function without(settings: Settings): Settings {
  const next = { ...settings };
  for (const field of INERT) delete next[field];
  return next;
}

export async function planInertPiFields(agentDir: string): Promise<InertPiFieldsPlan> {
  const path = join(agentDir, "settings.json");
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!info) return { path, fields: [] };
  if (!info.isFile() || info.size > SETTINGS_MAX_BYTES) throw new Error(`${path} is not a bounded regular file`);
  const before = parse(await readFile(path), path);
  const fields = INERT.filter(field => field in before);
  return fields.length ? { path, fields, before } : { path, fields };
}

export async function applyInertPiFields(plan: InertPiFieldsPlan, backup: string): Promise<boolean> {
  if (!plan.before || !plan.fields.length) return false;
  await mkdir(backup, { recursive: true, mode: 0o700 });
  if ((await readdir(backup)).length) throw new Error(`Backup directory ${backup} is not empty`);
  const original = join(backup, "settings.json");
  await copyFile(plan.path, original, constants.COPYFILE_EXCL);
  const saved = await readFile(original);
  if (!isDeepStrictEqual(parse(saved, original), plan.before)) throw new Error(`${plan.path} changed while it was backed up; rerun with a new backup directory`);
  const manifest: Manifest = { version: 1, path: plan.path, before: digest(saved) };
  await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  await updateJsonLocked<Settings>(plan.path, {}, current => {
    if (!isDeepStrictEqual(current, plan.before)) throw new Error(`${plan.path} changed since it was read; rerun with a new backup directory`);
    return without(current);
  }, SETTINGS_MAX_BYTES);
  await verify(plan.path, without(plan.before));
  return true;
}

export async function restoreInertPiFields(backup: string): Promise<boolean> {
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as Manifest;
  const original = await readFile(join(backup, "settings.json"));
  if (digest(original) !== manifest.before) throw new Error("The backup does not match its manifest");
  const before = parse(original, manifest.path);
  const release = await lockfile.lock(manifest.path, { realpath: false, retries: { retries: 10, minTimeout: 20, maxTimeout: 100 } });
  try {
    const info = await lstat(manifest.path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
    if (!info?.isFile() || info.size > SETTINGS_MAX_BYTES) throw new Error(`${manifest.path} is missing or not a bounded regular file; restore it by hand from ${backup}`);
    const current = parse(await readFile(manifest.path), manifest.path);
    if (isDeepStrictEqual(current, before)) return false;
    if (!isDeepStrictEqual(current, without(before))) throw new Error(`${manifest.path} changed after the migration; restore it by hand from ${backup}`);
    await durableAtomicWriteText(manifest.path, original.toString("utf8"));
    if (!(await readFile(manifest.path)).equals(original)) throw new Error(`${manifest.path} does not hold the backup bytes after the write`);
    return true;
  } finally {
    await release();
  }
}

async function verify(path: string, expected: Settings): Promise<void> {
  if (!isDeepStrictEqual(parse(await readFile(path), path), expected)) throw new Error(`${path} does not hold the expected settings after the write`);
}

const USAGE = "usage: migrate inert-pi-fields --agent-dir <dir> [--apply --backup <new dir>] | --restore --backup <dir>\n";

async function main(argv: readonly string[]): Promise<number> {
  const options = new Map<string, string>(); const flags = new Set<string>();
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (argument === "--apply" || argument === "--restore") flags.add(argument);
    else if ((argument === "--agent-dir" || argument === "--backup") && argv[index + 1] !== undefined) options.set(argument, argv[++index]!);
    else { process.stderr.write(`unknown argument ${argument}\n${USAGE}`); return 64; }
  }
  const backup = options.get("--backup");
  if (flags.has("--restore")) {
    if (!backup) { process.stderr.write(USAGE); return 64; }
    process.stdout.write(`${JSON.stringify({ restored: await restoreInertPiFields(resolve(backup)) })}\n`);
    return 0;
  }
  const agentDir = options.get("--agent-dir");
  if (!agentDir || (flags.has("--apply") && !backup)) { process.stderr.write(USAGE); return 64; }
  const plan = await planInertPiFields(resolve(agentDir));
  process.stdout.write(`plan ${JSON.stringify({ path: plan.path, fields: plan.fields })}\n`);
  if (flags.has("--apply")) process.stdout.write(`${JSON.stringify({ applied: await applyInertPiFields(plan, resolve(backup!)) })}\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
