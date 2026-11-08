import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { RETIRED_SCOPES } from "../kernel/settings/tool-contract.js";
import { SESSION_SETTINGS_ENTRY } from "./session-settings.js";

/**
 * One-shot, backed-up rewrite of two retired persisted forms into their current
 * form (#2329), run by the maintainer while the Gateway is listening and never
 * during startup (#1649):
 * - `tron.settings.v1` session entries whose `fixed`/`requestPins` provenance
 *   still names a scope #1634 retired (`RETIRED_SCOPES`);
 * - Profile note tags carrying the retired `home-file-*` placement labels, and
 *   the `beforeFile`/`file` label fields of committed partition receipts.
 *
 * It is idempotent: a second run plans nothing. Every replacement first clones
 * its original into the backup directory with a manifest of both digests, then
 * publishes atomically only if the file is unchanged since it was read (see
 * `publish` for a write racing the rename). Session files written within
 * `--settle-seconds` are deferred to a later run; run it while Home is idle. It
 * refuses a configured `sessionDir` and an uncommitted Profile organization. The
 * shared Changes record is append-only history and is not rewritten. Delete this
 * module with the retired readers once the live run is verified.
 */

const PROFILE_FILE = "workspace/files/Profile.json";
const RETIRED_LABEL = "home-file-";
const SETTINGS_MARK = `"customType":"${SESSION_SETTINGS_ENTRY}"`;

interface Identity { dev: number; ino: number; size: number; mtimeMs: number }
interface PlannedFile { kind: "session" | "profile"; path: string; identity: Identity; before: Buffer; after: Buffer; changes: number }
export interface MigrationPlan {
  sessions: { scanned: number; files: number; entries: number; values: number; deferred: string[] };
  profile: { notes: number; labels: number; receipts: number };
  files: PlannedFile[];
}
interface ManifestFile { path: string; kind: PlannedFile["kind"]; before: string; after: string; changes: number }
interface Manifest { version: 1; tronHome: string; createdAt: string; files: ManifestFile[] }

const digest = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const identity = (info: { dev: number; ino: number; size: number; mtimeMs: number }): Identity => ({ dev: info.dev, ino: info.ino, size: info.size, mtimeMs: info.mtimeMs });
const same = (left: Identity, right: Identity) => left.dev === right.dev && left.ino === right.ino && left.size === right.size && left.mtimeMs === right.mtimeMs;

async function* sessionFiles(directory: string): AsyncGenerator<string> {
  for (const entry of await readdir(directory, { withFileTypes: true }).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* sessionFiles(path);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) yield path;
  }
}

/** Current names for one settings entry's snapshot provenance; undefined when already current. */
function currentSettingsLine(line: string): { line: string; values: number } | undefined {
  if (!line.includes(SETTINGS_MARK)) return undefined;
  const entry = JSON.parse(line) as { type?: unknown; customType?: unknown; data?: Record<string, unknown> | null };
  if (entry.type !== "custom" || entry.customType !== SESSION_SETTINGS_ENTRY) return undefined;
  if (JSON.stringify(entry) !== line) throw new Error("A settings entry does not re-serialize byte-for-byte; refusing to rewrite its file");
  let values = 0;
  for (const field of ["fixed", "requestPins"] as const) {
    const snapshots = entry.data?.[field];
    if (!snapshots || typeof snapshots !== "object" || Array.isArray(snapshots)) continue;
    for (const value of Object.values(snapshots as Record<string, { from?: unknown }>)) {
      if (value && typeof value.from === "string" && Object.hasOwn(RETIRED_SCOPES, value.from)) { value.from = RETIRED_SCOPES[value.from]; values += 1; }
    }
  }
  return values ? { line: JSON.stringify(entry), values } : undefined;
}

async function planSession(path: string, settleBefore: number, plan: MigrationPlan): Promise<void> {
  plan.sessions.scanned += 1;
  const info = await lstat(path);
  const before = await readFile(path);
  if (!before.includes(SETTINGS_MARK)) return;
  const lines = before.toString("utf8").split("\n");
  let entries = 0, values = 0;
  for (const [index, line] of lines.entries()) {
    let current: ReturnType<typeof currentSettingsLine>;
    try { current = currentSettingsLine(line); } catch (error) { throw new Error(`${path}:${index + 1}: ${(error as Error).message}`); }
    if (!current) continue;
    lines[index] = current.line; entries += 1; values += current.values;
  }
  if (!entries) return;
  if (info.mtimeMs > settleBefore) { plan.sessions.deferred.push(path); return; }
  plan.sessions.files += 1; plan.sessions.entries += entries; plan.sessions.values += values;
  plan.files.push({ kind: "session", path, identity: identity(info), before, after: Buffer.from(lines.join("\n"), "utf8"), changes: entries });
}

/** Strips retired labels wherever a Profile note body lives: section heads and claim anchors. */
async function planProfile(path: string, plan: MigrationPlan): Promise<void> {
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!info) return;
  if (!info.isFile()) throw new Error("Profile.json is not a regular file");
  const before = await readFile(path);
  const file = JSON.parse(before.toString("utf8")) as { format?: unknown; version?: unknown; stateRevision?: unknown; sections?: Record<string, unknown>; anchors?: unknown[];
    control?: { commands?: Record<string, { operation?: unknown; result?: { kind?: unknown; value?: { changes?: Array<Record<string, unknown>> } } }> } };
  if (file.format !== "tron-profile" || file.version !== 2 || !Number.isSafeInteger(file.stateRevision)) throw new Error("Unsupported Profile file format");
  let notes = 0, labels = 0;
  const strip = (note: { content?: { tags?: unknown } }) => {
    const tags = note.content?.tags;
    if (!Array.isArray(tags)) return;
    const kept = tags.filter(tag => !(typeof tag === "string" && tag.startsWith(RETIRED_LABEL)));
    if (kept.length === tags.length) return;
    labels += tags.length - kept.length; notes += 1; note.content!.tags = kept;
  };
  const visit = (section: unknown) => {
    const value = section as { notes?: unknown[]; children?: Record<string, unknown> };
    for (const note of value.notes ?? []) strip(note as never);
    for (const child of Object.values(value.children ?? {})) visit(child);
  };
  for (const section of Object.values(file.sections ?? {})) visit(section);
  for (const anchor of file.anchors ?? []) strip(anchor as never);
  let receipts = 0;
  for (const receipt of Object.values(file.control?.commands ?? {}) as Array<{ operation?: unknown; partition?: unknown; auditPending?: unknown; result?: { kind?: unknown; value?: { changes?: Array<Record<string, unknown>> } } }>) {
    if (receipt.operation === "knowledge.profile.partition" && (receipt.partition !== undefined || receipt.auditPending !== undefined)) throw new Error("A Profile organization is uncommitted or unacknowledged; retry or settle it before migrating");
    if (receipt.operation !== "knowledge.profile.partition" || receipt.result?.kind !== "value") continue;
    const changes = receipt.result.value?.changes ?? [];
    if (!changes.some(change => "beforeFile" in change || "file" in change)) continue;
    for (const change of changes) { delete change.beforeFile; delete change.file; }
    receipts += 1;
  }
  if (!notes && !receipts) return;
  (file as { stateRevision: number }).stateRevision += 1;
  plan.profile = { notes, labels, receipts };
  plan.files.push({ kind: "profile", path, identity: identity(info), before, after: Buffer.from(`${JSON.stringify(file, null, 2)}\n`, "utf8"), changes: notes + receipts });
}

export async function planRetiredFormatMigration(tronHome: string, settleSeconds: number, now = Date.now()): Promise<MigrationPlan> {
  const settings = await readFile(tronHomePath(tronHome, "agent/settings.json"), "utf8").then(text => JSON.parse(text) as { sessionDir?: unknown }, (error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return {} as { sessionDir?: unknown }; throw error; });
  if (settings.sessionDir !== undefined) throw new Error("agent/settings.json sets sessionDir; this migration covers only agent/sessions");
  const plan: MigrationPlan = { sessions: { scanned: 0, files: 0, entries: 0, values: 0, deferred: [] }, profile: { notes: 0, labels: 0, receipts: 0 }, files: [] };
  for await (const path of sessionFiles(tronHomePath(tronHome, "agent/sessions"))) await planSession(path, now - settleSeconds * 1_000, plan);
  await planProfile(tronHomePath(tronHome, PROFILE_FILE), plan);
  return plan;
}

/**
 * Stages the replacement durably, then renames it over the path only while the path
 * is still the original that was read. The original stays open across the rename:
 * a write that reached it after the check (an append by path that opened it first)
 * is detected, and the path is put back to the complete, un-migrated original so
 * nothing is lost; a later run migrates it. Another writer's rename after ours wins
 * and is reported the same way. Both writers here are the Gateway's: Pi appends
 * session entries by path and the Profile owner publishes by rename.
 */
async function publish(file: PlannedFile, raced: string): Promise<void> {
  const original = await open(file.path, "r");
  try {
    if (!same(identity(await original.stat()), file.identity)) throw new Error("changed since it was read; rerun to include it");
    const temporary = `${file.path}.migration-${process.pid}.tmp`;
    const handle = await open(temporary, "wx", (await original.stat()).mode & 0o777);
    try {
      try { await handle.writeFile(file.after); await syncDurably(handle); } finally { await handle.close(); }
      if (!same(identity(await lstat(file.path)), file.identity)) throw new Error("changed since it was read; rerun to include it");
      await rename(temporary, file.path);
    } catch (error) {
      await rm(temporary, { force: true });
      throw error;
    }
    await syncDirectory(file.path);
    const published = identity(await stat(file.path));
    if (same(identity(await original.stat()), file.identity) && digest(await readFile(file.path)) === digest(file.after)) return;
    const late = await original.readFile();
    if (same(identity(await lstat(file.path)), published)) {
      await writeFile(temporary, late, { mode: (await original.stat()).mode & 0o777, flag: "wx" });
      await rename(temporary, file.path);
      await syncDirectory(file.path);
      throw new Error("was written during publication; its complete original was put back unmigrated; rerun");
    }
    await writeFile(raced, late, { mode: 0o600, flag: "wx" });
    throw new Error(`was written during publication; the original's final bytes are kept at ${raced} for a manual merge`);
  } finally { await original.close(); }
}
async function syncDirectory(path: string): Promise<void> {
  const directory = await open(dirname(path), "r");
  try { await syncDurably(directory); } finally { await directory.close(); }
}

/** Clones every original and writes the manifest before the first replacement. */
async function backUp(tronHome: string, backup: string, files: readonly PlannedFile[]): Promise<Manifest> {
  await mkdir(backup, { recursive: true, mode: 0o700 });
  if ((await readdir(backup)).length) throw new Error(`Backup directory ${backup} is not empty`);
  const manifest: Manifest = { version: 1, tronHome, createdAt: new Date().toISOString(), files: [] };
  for (const file of files) {
    const path = relative(tronHome, file.path), target = join(backup, "files", path);
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    await copyFile(file.path, target, constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE);
    if (digest(await readFile(target)) !== digest(file.before)) throw new Error(`${file.path} changed while it was backed up; rerun`);
    manifest.files.push({ path, kind: file.kind, before: digest(file.before), after: digest(file.after), changes: file.changes });
  }
  await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  return manifest;
}

export async function applyRetiredFormatMigration(tronHome: string, backup: string, plan: MigrationPlan): Promise<{ published: number; failed: string[] }> {
  if (!plan.files.length) return { published: 0, failed: [] };
  await backUp(tronHome, backup, plan.files);
  let published = 0; const failed: string[] = [];
  for (const [index, file] of plan.files.entries()) {
    try { await publish(file, join(backup, `raced-${index}`)); published += 1; }
    catch (error) { failed.push(`${relative(tronHome, file.path)}: ${(error as Error).message}`); }
  }
  return { published, failed };
}

/** Rollback: restores each original whose current bytes are still exactly what this run published. */
export async function restoreRetiredFormatMigration(tronHome: string, backup: string): Promise<{ restored: number; skipped: string[] }> {
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as Manifest;
  if (manifest.tronHome !== tronHome) throw new Error(`Backup ${backup} belongs to ${manifest.tronHome}, not ${tronHome}`);
  let restored = 0; const skipped: string[] = [];
  for (const file of manifest.files) {
    const live = join(manifest.tronHome, file.path), original = join(backup, "files", file.path);
    const current = digest(await readFile(live));
    if (current === file.before) continue;
    if (current !== file.after) { skipped.push(`${file.path}: changed after the migration; restore it by hand from ${original}`); continue; }
    if (digest(await readFile(original)) !== file.before) throw new Error(`Backup of ${file.path} does not match its manifest`);
    const temporary = `${live}.restore-${process.pid}.tmp`;
    await copyFile(original, temporary, constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE);
    await rename(temporary, live);
    restored += 1;
  }
  return { restored, skipped };
}

function summary(plan: MigrationPlan): string {
  return JSON.stringify({ sessions: { ...plan.sessions, deferred: plan.sessions.deferred.length }, profile: plan.profile, files: plan.files.length });
}

async function main(argv: readonly string[]): Promise<number> {
  const options = new Map<string, string>(); const flags = new Set<string>();
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (argument === "--apply" || argument === "--restore") flags.add(argument);
    else if (["--tron-home", "--backup", "--settle-seconds"].includes(argument) && argv[index + 1] !== undefined) options.set(argument, argv[++index]!);
    else { process.stderr.write(`unknown argument ${argument}\nusage: migrate retired-formats --tron-home <dir> [--apply --backup <new dir>] [--settle-seconds N] | --restore --tron-home <dir> --backup <dir>\n`); return 64; }
  }
  if (flags.has("--restore")) {
    if (!options.has("--backup") || !options.has("--tron-home")) { process.stderr.write("--restore needs --tron-home and --backup\n"); return 64; }
    const result = await restoreRetiredFormatMigration(resolve(options.get("--tron-home")!), resolve(options.get("--backup")!));
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return result.skipped.length ? 1 : 0;
  }
  const tronHome = options.get("--tron-home");
  if (!tronHome || (flags.has("--apply") && !options.has("--backup"))) { process.stderr.write("--tron-home is required; --apply also needs --backup\n"); return 64; }
  const settle = Number(options.get("--settle-seconds") ?? "600");
  if (!Number.isInteger(settle) || settle < 0) { process.stderr.write("--settle-seconds must be a non-negative integer\n"); return 64; }
  const plan = await planRetiredFormatMigration(resolve(tronHome), settle);
  process.stdout.write(`plan ${summary(plan)}\n`);
  for (const path of plan.sessions.deferred) process.stdout.write(`deferred (written within ${settle}s) ${path}\n`);
  if (!flags.has("--apply")) return 0;
  const result = await applyRetiredFormatMigration(resolve(tronHome), resolve(options.get("--backup")!), plan);
  process.stdout.write(`applied ${JSON.stringify(result)}\n`);
  const remaining = await planRetiredFormatMigration(resolve(tronHome), settle);
  process.stdout.write(`remaining ${summary(remaining)}\n`);
  return result.failed.length || remaining.files.length ? 1 : 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
