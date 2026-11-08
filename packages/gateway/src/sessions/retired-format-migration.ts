import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, link, lstat, mkdir, open, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, relative, resolve } from "node:path";
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
 * `publishSession` and `publishProfile` for a Gateway write racing publication). Session files written within
 * `--settle-seconds` are deferred to a later run; run it while Home is idle.
 *
 * A chapter the Home ledger records as sealed is re-sealed, never silently
 * rewritten: Home memory pins its exact bytes (`episodic/home-source.ts`). Before
 * its replacement is renamed into place (staged and fsynced first), one
 * `ChapterReseal` record naming both digests and every changed value is appended
 * to the re-seal ledger and fsynced. Home memory accepts the rewritten chapter
 * only by re-deriving, from its current bytes and that record, the exact bytes it
 * admitted. So an interrupted run leaves either the original chapter or a
 * re-sealable one, and a rerun completes it; `--restore` appends the reverse
 * record the same way. It refuses a configured `sessionDir`, an unsupported Home
 * ledger and an uncommitted Profile organization. The shared Changes record is
 * append-only history and is not rewritten. This module and the re-seal check in
 * Home memory are deleted together once the live run is verified.
 */

const PROFILE_FILE = "workspace/files/Profile.json";
const HOME_LEDGER = "gateway/home/home.json";
/** Append-only: one JSON `ChapterReseal` per line, written only by this tool. */
export const RESEAL_LEDGER = "gateway/home/chapter-reseals.jsonl";
const RETIRED_LABEL = "home-file-";
const SETTINGS_MARK = `"customType":"${SESSION_SETTINGS_ENTRY}"`;

interface Identity { dev: number; ino: number; size: number; mtimeMs: number }
/** One rewritten provenance value: `line` is the 0-based line index; the
 * re-sealed chapter holds `to` where Home memory admitted `from`. */
export interface ResealValue { line: number; field: "fixed" | "requestPins"; key: string; from: string; to: string }
export interface ChapterReseal {
  version: 1;
  sessionId: string;
  /** The chapter file, relative to the Tron home. */
  path: string;
  at: string;
  before: { sha256: string; size: number };
  after: { sha256: string; size: number };
  values: ResealValue[];
}
interface PlannedFile { kind: "session" | "profile"; path: string; identity: Identity; before: Buffer; after: Buffer; changes: number; reseal?: { sessionId: string; values: ResealValue[] } }
export interface MigrationPlan {
  sessions: { scanned: number; files: number; entries: number; values: number; deferred: string[] };
  profile: { notes: number; labels: number; receipts: number };
  /** Sealed Home chapters among `files`: each is re-sealed. */
  sealedHome: string[];
  files: PlannedFile[];
}
interface ManifestFile { path: string; kind: PlannedFile["kind"]; before: string; after: string; changes: number; reseal?: PlannedFile["reseal"] }
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

type SettingsEntry = { type?: unknown; customType?: unknown; data?: Record<string, unknown> | null };
const snapshotFields = ["fixed", "requestPins"] as const;
/** The rewrite pairs, in either direction (a restore runs it backwards). */
const retiredPair = (from: string, to: string) => (Object.hasOwn(RETIRED_SCOPES, from) && RETIRED_SCOPES[from] === to)
  || (Object.hasOwn(RETIRED_SCOPES, to) && RETIRED_SCOPES[to] === from);

/** Current names for one settings entry's snapshot provenance; undefined when already current. */
function currentSettingsLine(line: string, index: number): { line: string; values: ResealValue[] } | undefined {
  if (!line.includes(SETTINGS_MARK)) return undefined;
  const entry = JSON.parse(line) as SettingsEntry;
  if (entry.type !== "custom" || entry.customType !== SESSION_SETTINGS_ENTRY) return undefined;
  if (JSON.stringify(entry) !== line) throw new Error("A settings entry does not re-serialize byte-for-byte; refusing to rewrite its file");
  const values: ResealValue[] = [];
  for (const field of snapshotFields) {
    const snapshots = entry.data?.[field];
    if (!snapshots || typeof snapshots !== "object" || Array.isArray(snapshots)) continue;
    for (const [key, value] of Object.entries(snapshots as Record<string, { from?: unknown }>)) {
      if (value && typeof value.from === "string" && Object.hasOwn(RETIRED_SCOPES, value.from)) {
        values.push({ line: index, field, key, from: value.from, to: RETIRED_SCOPES[value.from]! });
        value.from = RETIRED_SCOPES[value.from];
      }
    }
  }
  return values.length ? { line: JSON.stringify(entry), values } : undefined;
}

/**
 * The line Home memory admitted, re-derived from a re-sealed chapter's current
 * line and that line's recorded values; undefined unless the current line is a
 * settings entry that re-serializes byte-for-byte and holds exactly `to` at each
 * recorded value, every pair a retired-name rewrite. Each value changes only its
 * own JSON string, so any other byte that differs from the admitted line fails
 * the caller's digest comparison.
 */
export function admittedSettingsLine(line: string, values: readonly ResealValue[]): string | undefined {
  let entry: SettingsEntry;
  try { entry = JSON.parse(line) as SettingsEntry; } catch { return undefined; }
  if (!entry || entry.type !== "custom" || entry.customType !== SESSION_SETTINGS_ENTRY || JSON.stringify(entry) !== line) return undefined;
  const seen = new Set<string>();
  for (const value of values) {
    const snapshots = entry.data && Object.hasOwn(entry.data, value.field) ? entry.data[value.field] as Record<string, { from?: unknown }> | null : undefined;
    const snapshot = snapshots && typeof snapshots === "object" && Object.hasOwn(snapshots, value.key) ? snapshots[value.key] : undefined;
    const name = `${value.field}\0${value.key}`;
    if (!snapshot || typeof snapshot !== "object" || snapshot.from !== value.to || !retiredPair(value.from, value.to) || seen.has(name)) return undefined;
    seen.add(name);
    snapshot.from = value.from;
  }
  return JSON.stringify(entry);
}

const digestPattern = /^[a-f0-9]{64}$/u;
function admitReseal(value: unknown): ChapterReseal | undefined {
  const record = value as Partial<ChapterReseal> | null;
  const side = (part: unknown) => { const v = part as { sha256?: unknown; size?: unknown } | null;
    return Boolean(v) && typeof v!.sha256 === "string" && digestPattern.test(v!.sha256) && Number.isSafeInteger(v!.size) && (v!.size as number) > 0 && Object.keys(v!).length === 2; };
  if (!record || typeof record !== "object" || record.version !== 1 || typeof record.sessionId !== "string" || !record.sessionId
    || typeof record.path !== "string" || typeof record.at !== "string" || !side(record.before) || !side(record.after)
    || !Array.isArray(record.values) || record.values.length === 0 || Object.keys(record).length !== 7) return undefined;
  for (const item of record.values) {
    if (!item || typeof item !== "object" || !Number.isSafeInteger(item.line) || item.line < 1 || !snapshotFields.includes(item.field)
      || typeof item.key !== "string" || typeof item.from !== "string" || typeof item.to !== "string" || !retiredPair(item.from, item.to)
      || Object.keys(item).length !== 5) return undefined;
  }
  return record as ChapterReseal;
}

/** The re-seal ledger's complete records. A torn trailing line (an interrupted
 * append) is not a record; any malformed complete line refuses the whole ledger. */
export async function readChapterReseals(path: string): Promise<{ records: ChapterReseal[]; completeBytes: number }> {
  const bytes = await readFile(path).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return Buffer.alloc(0); throw error; });
  const completeBytes = bytes.lastIndexOf(0x0a) + 1;
  const records: ChapterReseal[] = [];
  for (const line of bytes.subarray(0, completeBytes).toString("utf8").split("\n")) {
    if (!line) continue;
    let value: unknown;
    try { value = JSON.parse(line); } catch { throw new Error("The chapter re-seal ledger holds a malformed record"); }
    const record = admitReseal(value);
    if (!record) throw new Error("The chapter re-seal ledger holds a malformed record");
    records.push(record);
  }
  return { records, completeBytes };
}

/** Appends one durable record unless an identical transition is already recorded
 * (a rerun after an interruption). A torn tail from an interrupted append is cut
 * first: its rename never happened, because every rename follows its record. */
async function appendReseal(tronHome: string, record: ChapterReseal): Promise<void> {
  const path = tronHomePath(tronHome, RESEAL_LEDGER);
  const { records, completeBytes } = await readChapterReseals(path);
  if (records.some(existing => existing.sessionId === record.sessionId && existing.before.sha256 === record.before.sha256 && existing.after.sha256 === record.after.sha256)) return;
  const created = !await present(path);
  const handle = await open(path, constants.O_WRONLY | constants.O_CREAT, 0o600);
  try {
    await handle.truncate(completeBytes);
    await handle.write(`${JSON.stringify(record)}\n`, completeBytes);
    await syncDurably(handle);
  } finally { await handle.close(); }
  if (created) await syncDirectory(path);
}

/** Session IDs of the chapters the Home ledger has sealed. */
async function sealedHomeChapters(tronHome: string): Promise<ReadonlySet<string>> {
  const text = await readFile(tronHomePath(tronHome, HOME_LEDGER), "utf8").catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  if (text === undefined) return new Set();
  const ledger = JSON.parse(text) as { version?: unknown; chapters?: unknown };
  if (ledger.version !== 2 || !Array.isArray(ledger.chapters)) throw new Error("Unsupported Home ledger format");
  const sealed = new Set<string>();
  for (const chapter of ledger.chapters as Array<{ sessionId?: unknown; state?: unknown }>) {
    if (typeof chapter?.sessionId !== "string" || typeof chapter.state !== "string") throw new Error("Unsupported Home ledger format");
    if (chapter.state === "sealed") sealed.add(chapter.sessionId);
  }
  return sealed;
}

async function planSession(path: string, settleBefore: number, sealedHome: ReadonlySet<string>, plan: MigrationPlan): Promise<void> {
  plan.sessions.scanned += 1;
  const info = await lstat(path);
  const before = await readFile(path);
  if (!before.includes(SETTINGS_MARK)) return;
  const lines = before.toString("utf8").split("\n");
  let entries = 0;
  const values: ResealValue[] = [];
  for (const [index, line] of lines.entries()) {
    let current: ReturnType<typeof currentSettingsLine>;
    try { current = currentSettingsLine(line, index); } catch (error) { throw new Error(`${path}:${index + 1}: ${(error as Error).message}`); }
    if (!current) continue;
    lines[index] = current.line; entries += 1; values.push(...current.values);
  }
  if (!entries) return;
  const sessionId = (JSON.parse(lines[0]!) as { id?: unknown }).id;
  // A sealed chapter is never written by the Gateway, so it is not deferred.
  const sealed = typeof sessionId === "string" && sealedHome.has(sessionId);
  if (!sealed && info.mtimeMs > settleBefore) { plan.sessions.deferred.push(path); return; }
  plan.sessions.files += 1; plan.sessions.entries += entries; plan.sessions.values += values.length;
  if (sealed) plan.sealedHome.push(path);
  plan.files.push({ kind: "session", path, identity: identity(info), before, after: Buffer.from(lines.join("\n"), "utf8"), changes: entries,
    ...(sealed ? { reseal: { sessionId: sessionId as string, values } } : {}) });
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
  const sealedHome = await sealedHomeChapters(tronHome);
  const plan: MigrationPlan = { sessions: { scanned: 0, files: 0, entries: 0, values: 0, deferred: [] }, profile: { notes: 0, labels: 0, receipts: 0 }, sealedHome: [], files: [] };
  for await (const path of sessionFiles(tronHomePath(tronHome, "agent/sessions"))) await planSession(path, now - settleSeconds * 1_000, sealedHome, plan);
  await planProfile(tronHomePath(tronHome, PROFILE_FILE), plan);
  return plan;
}

/** Removes the staged replacements an interrupted run left beside `path`. */
async function removeStaleTemporaries(path: string): Promise<void> {
  const name = basename(path);
  for (const entry of await readdir(dirname(path))) {
    if (entry.startsWith(`${name}.`) && /^\.(?:migration|restore)-\d+\.tmp$/u.test(entry.slice(name.length))) await rm(join(dirname(path), entry), { force: true });
  }
}

async function stage(path: string, bytes: Buffer, mode: number): Promise<string> {
  await removeStaleTemporaries(path);
  const temporary = `${path}.migration-${process.pid}.tmp`;
  const handle = await open(temporary, "wx", mode);
  try { await handle.writeFile(bytes); await syncDurably(handle); } catch (error) { await handle.close(); await rm(temporary, { force: true }); throw error; }
  await handle.close();
  return temporary;
}
const unchanged = "changed since it was read; rerun to include it";

/**
 * Pi appends session entries by path. The replacement is renamed over the path only
 * while the path is still the original, and the original stays open across the
 * rename: an append that reached it after the last check is detected, and if the
 * migrated file is still exactly as published the complete original is put back
 * un-migrated for a later run; otherwise its final bytes are kept for a manual
 * merge. Appends after the rename land in the migrated file and are kept. A
 * sealed Home chapter's re-seal record is durable before its rename.
 */
async function publishSession(file: PlannedFile, raced: string, tronHome: string): Promise<void> {
  const original = await open(file.path, "r");
  try {
    const info = await original.stat();
    if (!same(identity(info), file.identity)) throw new Error(unchanged);
    const temporary = await stage(file.path, file.after, info.mode & 0o777);
    try {
      if (file.reseal) await appendReseal(tronHome, resealRecord(tronHome, file.path, file.before, file.after, file.reseal));
      if (!same(identity(await lstat(file.path)), file.identity)) throw new Error(unchanged);
      await rename(temporary, file.path);
    } catch (error) { await rm(temporary, { force: true }); throw error; }
    const published = await lstat(file.path);
    await syncDirectory(file.path);
    if (same(identity(await original.stat()), file.identity)) return;
    const late = await original.readFile();
    const now = await lstat(file.path);
    if (now.ino === published.ino && now.size === file.after.length) {
      const restore = await stage(file.path, late, info.mode & 0o777);
      const again = await lstat(file.path);
      if (again.ino === published.ino && again.size === file.after.length) {
        await rename(restore, file.path); await syncDirectory(file.path);
        throw new Error("was written during publication; its complete original was put back unmigrated; rerun");
      }
      await rm(restore, { force: true });
    }
    await writeFile(raced, late, { mode: 0o600, flag: "wx" });
    throw new Error(`was written during publication; the original's final bytes are kept at ${raced} for a manual merge`);
  } finally { await original.close(); }
}

/**
 * The Profile owner publishes by rename, so a rename over it could silently replace
 * a concurrent owner write. Instead the original is moved aside and the replacement
 * is linked into the empty path: link refuses when an owner publication already
 * took the path, and that publication is kept. While the path is briefly empty an
 * owner read refuses rather than writes.
 */
async function publishProfile(file: PlannedFile, raced: string): Promise<void> {
  const info = await lstat(file.path);
  if (!same(identity(info), file.identity) || !(await readFile(file.path)).equals(file.before)) throw new Error(unchanged);
  const temporary = await stage(file.path, file.after, info.mode & 0o777);
  const held = `${file.path}.migration-held-${process.pid}`;
  try {
    if (!same(identity(await lstat(file.path)), file.identity)) throw new Error(unchanged);
    await rename(file.path, held);
  } catch (error) { await rm(temporary, { force: true }); throw error; }
  if (!same(identity(await lstat(held)), file.identity)) {
    await rm(temporary, { force: true });
    await link(held, file.path).then(() => rm(held), async () => { await rename(held, raced); });
    throw new Error(`was replaced during publication; that write was kept${await present(raced) ? ` at ${raced} for a manual merge` : ""}; rerun`);
  }
  try { await link(temporary, file.path); }
  catch (error) {
    await rm(temporary, { force: true }); await rename(held, raced);
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error(`was written during publication; that write was kept, the original is at ${raced}; rerun`);
    throw error;
  }
  await rm(temporary); await rm(held); await syncDirectory(file.path);
}
const present = (path: string) => lstat(path).then(() => true, () => false);
async function syncDirectory(path: string): Promise<void> {
  const directory = await open(dirname(path), "r");
  try { await syncDurably(directory); } finally { await directory.close(); }
}

function resealRecord(tronHome: string, path: string, before: Buffer, after: Buffer, reseal: NonNullable<PlannedFile["reseal"]>): ChapterReseal {
  return { version: 1, sessionId: reseal.sessionId, path: relative(tronHome, path), at: new Date().toISOString(),
    before: { sha256: digest(before), size: before.length }, after: { sha256: digest(after), size: after.length }, values: reseal.values };
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
    manifest.files.push({ path, kind: file.kind, before: digest(file.before), after: digest(file.after), changes: file.changes, ...(file.reseal ? { reseal: file.reseal } : {}) });
  }
  await writeFile(join(backup, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  return manifest;
}

export async function applyRetiredFormatMigration(tronHome: string, backup: string, plan: MigrationPlan): Promise<{ published: number; failed: string[] }> {
  if (!plan.files.length) return { published: 0, failed: [] };
  await backUp(tronHome, backup, plan.files);
  let published = 0; const failed: string[] = [];
  for (const [index, file] of plan.files.entries()) {
    try {
      if (file.kind === "profile") await publishProfile(file, join(backup, `raced-${index}`));
      else await publishSession(file, join(backup, `raced-${index}`), tronHome);
      published += 1;
    }
    catch (error) { failed.push(`${relative(tronHome, file.path)}: ${(error as Error).message}`); }
  }
  return { published, failed };
}

/** Rollback: restores each original whose current bytes are still exactly what this
 * run published. A re-sealed chapter's reverse record is durable before its rename. */
export async function restoreRetiredFormatMigration(tronHome: string, backup: string): Promise<{ restored: number; skipped: string[] }> {
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as Manifest;
  if (manifest.tronHome !== tronHome) throw new Error(`Backup ${backup} belongs to ${manifest.tronHome}, not ${tronHome}`);
  let restored = 0; const skipped: string[] = [];
  for (const file of manifest.files) {
    const live = join(manifest.tronHome, file.path), original = join(backup, "files", file.path);
    const current = digest(await readFile(live));
    if (current === file.before) continue;
    if (current !== file.after) { skipped.push(`${file.path}: changed after the migration; restore it by hand from ${original}`); continue; }
    const bytes = await readFile(original);
    if (digest(bytes) !== file.before) throw new Error(`Backup of ${file.path} does not match its manifest`);
    await removeStaleTemporaries(live);
    const temporary = `${live}.restore-${process.pid}.tmp`;
    const handle = await open(temporary, "wx", (await lstat(live)).mode & 0o777);
    try { await handle.writeFile(bytes); await syncDurably(handle); } finally { await handle.close(); }
    if (file.reseal) {
      const migrated = await readFile(live);
      const reverse = { sessionId: file.reseal.sessionId, values: file.reseal.values.map(value => ({ ...value, from: value.to, to: value.from })) };
      await appendReseal(manifest.tronHome, resealRecord(manifest.tronHome, live, migrated, bytes, reverse));
    }
    if (digest(await readFile(live)) !== file.after) { await rm(temporary); skipped.push(`${file.path}: changed during the restore; restore it by hand from ${original}`); continue; }
    await rename(temporary, live);
    await syncDirectory(live);
    restored += 1;
  }
  return { restored, skipped };
}

function summary(plan: MigrationPlan): string {
  return JSON.stringify({ sessions: { ...plan.sessions, deferred: plan.sessions.deferred.length }, profile: plan.profile, sealedHome: plan.sealedHome.length, files: plan.files.length });
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
  return result.failed.length || remaining.files.length || remaining.sessions.deferred.length ? 1 : 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => { process.stderr.write(`${(error as Error).stack ?? error}\n`); process.exitCode = 1; });
}
