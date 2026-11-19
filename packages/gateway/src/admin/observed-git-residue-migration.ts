import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const STATE_MAX_BYTES = 16 * 1_048_576;
const RETIRED = ["staged", "head"] as const;
const digest = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

export interface ObservedGitResiduePlan { path: string; stores: number; before?: Buffer; after?: Buffer }
interface Manifest { version: 1; path: string; before: string; after: string }

export async function planObservedGitResidue(tronHome: string): Promise<ObservedGitResiduePlan> {
  const path = tronHomePath(tronHome, "state/settings/observed.json");
  const plan: ObservedGitResiduePlan = { path, stores: 0 };
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!info) return plan;
  if (!info.isFile() || info.size > STATE_MAX_BYTES) throw new Error(`${path} is not a bounded regular file`);
  const before = await readFile(path);
  const document = JSON.parse(before.toString("utf8")) as { version: number; stores: Record<string, Record<string, unknown>> };
  if (document.version !== 1 || !document.stores || typeof document.stores !== "object" || Array.isArray(document.stores)) {
    throw new Error(`${path} is not version 1 observed settings state`);
  }
  for (const store of Object.values(document.stores)) {
    if (!RETIRED.some(field => field in store)) continue;
    for (const field of RETIRED) delete store[field];
    plan.stores += 1;
  }
  if (!plan.stores) return plan;
  return { ...plan, before, after: Buffer.from(JSON.stringify(document), "utf8") };
}

export async function applyObservedGitResidue(plan: ObservedGitResiduePlan, backup: string): Promise<boolean> {
  if (!plan.before || !plan.after) return false;
  await mkdir(backup, { recursive: true, mode: 0o700 });
  if ((await readdir(backup)).length) throw new Error(`Backup directory ${backup} is not empty`);
  const original = join(backup, "observed.json");
  await copyFile(plan.path, original, constants.COPYFILE_EXCL);
  if (!(await readFile(original)).equals(plan.before)) throw new Error(`${plan.path} changed while it was backed up; rerun with a new backup directory`);
  const manifest: Manifest = { version: 1, path: plan.path, before: digest(plan.before), after: digest(plan.after) };
  await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  try { await publish(plan.path, plan.after, plan.before); }
  catch (error) {
    if (!(await readFile(plan.path)).equals(plan.after)) await rm(join(backup, "manifest.json"), { force: true });
    throw error;
  }
  return true;
}

export async function restoreObservedGitResidue(backup: string): Promise<boolean> {
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as Manifest;
  const current = await readFile(manifest.path);
  if (digest(current) === manifest.before) return false;
  if (digest(current) !== manifest.after) throw new Error(`${manifest.path} changed after the migration; restore it by hand from ${backup}`);
  const original = await readFile(join(backup, "observed.json"));
  if (digest(original) !== manifest.before) throw new Error("The backup does not match its manifest");
  await publish(manifest.path, original, current);
  return true;
}

async function publish(path: string, bytes: Buffer, expected: Buffer): Promise<void> {
  const temporary = `${path}.migration-${process.pid}.tmp`;
  const handle = await open(temporary, "wx", 0o600);
  try {
    try { await handle.writeFile(bytes); await syncDurably(handle); } finally { await handle.close(); }
    if (!(await readFile(path)).equals(expected)) throw new Error(`${path} changed since it was read; rerun with a new backup directory`);
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
  const directory = await open(dirname(path), "r");
  try { await syncDurably(directory); } finally { await directory.close(); }
}

const USAGE = "usage: migrate observed-git-residue --tron-home <dir> [--apply --backup <new dir>] | --restore --backup <dir>\n";

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
    process.stdout.write(`${JSON.stringify({ restored: await restoreObservedGitResidue(resolve(backup)) })}\n`);
    return 0;
  }
  const tronHome = options.get("--tron-home");
  if (!tronHome || (flags.has("--apply") && !backup)) { process.stderr.write(USAGE); return 64; }
  const plan = await planObservedGitResidue(resolve(tronHome));
  const { before: _before, after: _after, ...summary } = plan;
  process.stdout.write(`plan ${JSON.stringify(summary)}\n`);
  if (flags.has("--apply")) process.stdout.write(`${JSON.stringify({ applied: await applyObservedGitResidue(plan, resolve(backup!)) })}\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
