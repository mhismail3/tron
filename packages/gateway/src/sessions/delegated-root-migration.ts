import { tmpdir } from "node:os";
import { lstat, opendir, readFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

const MAX_ENTRIES = 20_000;
const MAX_FILE_BYTES = 64 * 1024 * 1024;
const MAX_TOTAL_BYTES = 512 * 1024 * 1024;
const RUN_STATES = new Set(["queued", "running", "paused"]);
const TERMINAL_STATES = new Set(["complete", "failed", "partial", "stopped", "rejected"]);
const TERMINAL_PROOF = new Set(["observed"]);

export interface DelegatedRootMigrationOptions {
  readonly legacyRoots: readonly string[];
  readonly destinationRoot: string;
}
export interface DelegatedRootInventory {
  readonly root: string;
  readonly entries: number;
  readonly bytes: number;
  readonly activeRuns: readonly string[];
  readonly resumabilityRefusals: readonly string[];
  readonly absoluteReferences: readonly string[];
}
export interface DelegatedRootPreflight {
  readonly status: "not-required" | "migration-required" | "conflict";
  readonly destinationRoot: string;
  readonly roots: readonly DelegatedRootInventory[];
  readonly changesMade: false;
}

export class DelegatedRootMigrationError extends Error {
  constructor(message: string) { super(message); this.name = "DelegatedRootMigrationError"; }
}
const fail = (message: string): never => { throw new DelegatedRootMigrationError(message); };

function absolute(value: string, label: string): string {
  if (!isAbsolute(value)) fail(`${label} must be absolute`);
  const normalized = resolve(value);
  if (normalized === sep) fail(`${label} cannot be filesystem root`);
  return normalized;
}
function within(root: string, candidate: string): boolean {
  const rest = relative(root, candidate);
  return rest === "" || (!isAbsolute(rest) && rest !== ".." && !rest.startsWith(`..${sep}`));
}
function privateMode(mode: number): boolean { return (mode & 0o077) === 0; }
async function rejectRedirectedParents(path: string): Promise<void> {
  for (let current = resolve(path); current !== sep; current = dirname(current)) {
    const entry = await lstat(current).catch(error => {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    });
    // These two aliases belong to macOS, not a migration owner.
    if (entry?.isSymbolicLink() && !["/var", "/tmp"].includes(current)) fail(`migration path contains a symlink: ${current}`);
  }
}
async function ownerDirectory(path: string, label: string, legacy = false): Promise<void> {
  await rejectRedirectedParents(path);
  let entry;
  try { entry = await lstat(path); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    fail(`${label} cannot be inspected safely`);
  }
  if (!entry!.isDirectory() || entry!.isSymbolicLink() || !(legacy ? sourceMode(entry!.mode, true) : privateMode(entry!.mode))
    || process.getuid?.() !== undefined && entry!.uid !== process.getuid?.()) {
    fail(`${label} must be an owned, non-writable-by-others directory${legacy ? "" : " with private permissions"}`);
  }
}

function absoluteStrings(value: unknown, result: Set<string>): void {
  if (typeof value === "string") {
    if (isAbsolute(value)) result.add(value);
  } else if (Array.isArray(value)) value.forEach(item => absoluteStrings(item, result));
  else if (value && typeof value === "object") Object.values(value).forEach(item => absoluteStrings(item, result));
}
async function readJson(path: string): Promise<unknown | undefined> {
  try { return JSON.parse(await readFile(path, "utf8")); } catch { return undefined; }
}
interface TreeFile { relativePath: string; absolutePath: string; bytes: number; mode: number; uid: number; }
interface TreeDirectory { relativePath: string; absolutePath: string; mode: number; uid: number; }
interface TreeInventory { files: TreeFile[]; directories: TreeDirectory[]; }
// The pinned provider used the process umask (usually 0755/0644). Admit
// owner-controlled legacy bytes, preserve their source proof, and publish a
// private copy. Never chmod or weaken integrity checks on the live source.
function sourceMode(mode: number, directory: boolean): boolean {
  return (mode & 0o7022) === 0 && (mode & (directory ? 0o700 : 0o400)) === (directory ? 0o700 : 0o400);
}
function owned(uid: number): boolean { return process.getuid?.() === undefined || uid === process.getuid(); }
async function walk(root: string, legacy = false): Promise<TreeInventory> {
  const files: TreeFile[] = [];
  const directories: TreeDirectory[] = [];
  let total = 0;
  let examined = 0;
  async function visit(current: string): Promise<void> {
    const directory = await lstat(current);
    if (directory.isSymbolicLink() || !directory.isDirectory() || !owned(directory.uid) || !(legacy ? sourceMode(directory.mode, true) : privateMode(directory.mode))) fail(`delegated tree contains an unsafe directory: ${current}`);
    directories.push({ relativePath: relative(root, current), absolutePath: current, mode: directory.mode & 0o7777, uid: directory.uid });
    const handle = await opendir(current);
    for await (const entry of handle) {
      if (++examined > MAX_ENTRIES) fail("delegated artifact tree exceeds the entry bound");
      const child = join(current, entry.name);
      const childStat = await lstat(child);
      if (childStat.isSymbolicLink()) fail(`delegated tree contains a symlink: ${child}`);
      if (childStat.isDirectory()) { await visit(child); continue; }
      if (!childStat.isFile() || childStat.nlink !== 1 || !owned(childStat.uid) || !(legacy ? sourceMode(childStat.mode, false) : privateMode(childStat.mode))) fail(`delegated artifact is not a private owner-only regular file: ${child}`);
      if (basename(child) === "session.jsonl") fail(`canonical transcript is inside delegated provider root and cannot be cut over: ${child}`);
      if (childStat.size > MAX_FILE_BYTES || (total += childStat.size) > MAX_TOTAL_BYTES) fail("delegated artifact tree exceeds the bounded size");
      files.push({ relativePath: relative(root, child), absolutePath: child, bytes: childStat.size, mode: childStat.mode & 0o7777, uid: childStat.uid });
    }
  }
  await rejectRedirectedParents(root);
  try { await lstat(root); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { files: [], directories: [] };
    throw error;
  }
  // A child disappearing is a changed source, never proof of an empty root.
  await visit(root);
  return { files, directories };
}

async function inventoryRoot(rootInput: string, allRoots: readonly string[]): Promise<DelegatedRootInventory> {
  const root = absolute(rootInput, "legacy root");
  await ownerDirectory(root, "legacy root", true);
  const inventory = await walk(root, true);
  const files = inventory.files;
  const references = new Set<string>();
  for (const file of files) {
    if (!/\.jsonl?$/u.test(file.relativePath)) continue;
    const value = await readJson(file.absolutePath);
    if (value !== undefined) absoluteStrings(value, references);
    else {
      const text = await readFile(file.absolutePath, "utf8");
      for (const candidate of text.match(/(?:\/(?:[^\s"'\\]|\\.)+){2,}/gu) ?? []) references.add(candidate);
    }
  }
  const asyncRoot = join(root, "async-subagent-runs");
  const activeRuns: string[] = [];
  const resumabilityRefusals: string[] = [];
  const statusFiles = files.filter(file => within(asyncRoot, file.absolutePath) && file.relativePath.endsWith("status.json"));
  for (const file of statusFiles) {
    const status = await readJson(file.absolutePath);
    if (!status || typeof status !== "object" || Array.isArray(status)) {
      resumabilityRefusals.push(`${file.absolutePath}: malformed status; inspect or retire this run before cutover`);
      continue;
    }
    const record = status as Record<string, unknown>;
    const state = typeof record.state === "string" ? record.state : undefined;
    if (!state || !RUN_STATES.has(state) && !TERMINAL_STATES.has(state)
      || record.lifecycleArtifactVersion !== undefined && record.lifecycleArtifactVersion !== 3) {
      resumabilityRefusals.push(`${file.absolutePath}: unknown provider state/version; inspect before cutover`);
      continue;
    }
    const proof = record.processTerminal && typeof record.processTerminal === "object"
      ? (record.processTerminal as Record<string, unknown>).state : undefined;
    if (state && RUN_STATES.has(state) && !TERMINAL_PROOF.has(String(proof))) activeRuns.push(file.absolutePath);
    if (state && RUN_STATES.has(state) && TERMINAL_PROOF.has(String(proof))) {
      const steps = Array.isArray(record.steps) ? record.steps : [];
      const sessionFile = steps.length === 1 && steps[0] && typeof steps[0] === "object"
        ? (steps[0] as Record<string, unknown>).sessionFile : record.sessionFile;
      if (typeof sessionFile === "string" && (!isAbsolute(sessionFile) || !(await lstat(sessionFile).then(s => s.isFile()).catch(() => false)))) {
        resumabilityRefusals.push(`${file.absolutePath}: retained resumable sessionFile is missing; restore it or retire the run before cutover`);
      }
    }
  }
  return { root, entries: files.length, bytes: files.reduce((sum, file) => sum + file.bytes, 0), activeRuns, resumabilityRefusals,
    absoluteReferences: [...references].filter(value => allRoots.some(source => within(source, resolve(value)))) };
}

export function discoverDelegatedLegacyRoots(input: { destinationRoot: string; tempDirectory?: string; legacyRoot?: string | undefined }): string[] {
  // pi-subagents scopes its Mac temporary store to the current UID.
  // Project/session artifact history is a separate configured destination;
  // moving it would strand references and the provider would recreate it.
  // Prefix scans also capture unrelated test fixtures and retired stores.
  const uid = process.getuid?.();
  if (uid === undefined) fail("delegated legacy discovery requires a reviewed user scope");
  const root = input.legacyRoot === undefined
    ? join(input.tempDirectory ?? tmpdir(), `pi-subagents-uid-${uid}`)
    : absolute(input.legacyRoot, "legacy provider override");
  return resolve(root) === resolve(input.destinationRoot) ? [] : [resolve(root)];
}

export async function preflightDelegatedRootCutover(options: DelegatedRootMigrationOptions): Promise<DelegatedRootPreflight> {
  const destinationRoot = absolute(options.destinationRoot, "destination root");
  await ownerDirectory(destinationRoot, "destination root");
  const roots = [...new Set(options.legacyRoots.map(root => absolute(root, "legacy root")))].filter(root => root !== destinationRoot);
  if (roots.some((root, index) => roots.some((other, otherIndex) => index !== otherIndex && within(root, other)))) fail("delegated legacy roots overlap");
  if (roots.some(root => within(root, destinationRoot) || within(destinationRoot, root))) fail("delegated source and destination overlap");
  const inventories = await Promise.all(roots.map(root => inventoryRoot(root, roots)));
  const retained = inventories.filter(item => item.entries > 0);
  let destinationEntries: Array<{ relativePath: string }> = [];
  try { if (retained.length) destinationEntries = (await walk(destinationRoot)).files.map(file => ({ relativePath: file.relativePath })); } catch (error) { if (!(error instanceof DelegatedRootMigrationError) || !error.message.includes("missing")) throw error; }
  if (retained.length && destinationEntries.length) return { status: "conflict", destinationRoot, roots: inventories, changesMade: false };
  if (inventories.some(item => item.activeRuns.length || item.resumabilityRefusals.length)) {
    return { status: "conflict", destinationRoot, roots: inventories, changesMade: false };
  }
  return { status: retained.length ? "migration-required" : "not-required", destinationRoot, roots: inventories, changesMade: false };
}

export async function assertDelegatedRootCutoverReady(tronHome: string): Promise<void> {
  const destinationRoot = join(resolve(tronHome), "internal", "subagents");
  const legacyRoots = discoverDelegatedLegacyRoots({ destinationRoot, legacyRoot: process.env.PI_SUBAGENTS_TEMP_ROOT });
  const preflight = await preflightDelegatedRootCutover({ legacyRoots, destinationRoot });
  if (preflight.status !== "not-required") {
    const roots = preflight.roots.filter(root => root.entries > 0).map(root => root.root).join(", ");
    throw new DelegatedRootMigrationError(`delegated artifact migration required before startup; retained provider roots outside ${destinationRoot}: ${roots}. Quiesce all delegated runs and move the retained work into ${destinationRoot} before starting Tron`);
  }
}
