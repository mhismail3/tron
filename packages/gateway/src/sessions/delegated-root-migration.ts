import { createHash, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { chmod, lstat, mkdir, opendir, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { durableAtomicWriteJson } from "../util/durable-json.js";

const MAX_ENTRIES = 20_000;
const MAX_FILE_BYTES = 64 * 1024 * 1024;
const MAX_TOTAL_BYTES = 512 * 1024 * 1024;
const MARKER_VERSION = 3;
const RUN_STATES = new Set(["queued", "running", "paused"]);
const TERMINAL_STATES = new Set(["complete", "failed", "partial", "stopped", "rejected"]);
const TERMINAL_PROOF = new Set(["observed"]);

export interface DelegatedRootMigrationOptions {
  readonly legacyRoots: readonly string[];
  readonly destinationRoot: string;
}
export interface DelegatedRootMigrationStageOptions extends DelegatedRootMigrationOptions {
  readonly staging: string;
  readonly acknowledgeQuiescence: boolean;
  readonly acknowledgeBackup: boolean;
}
export interface DelegatedRootEntryManifest {
  readonly source: string;
  readonly path: string;
  readonly bytes: number;
  readonly mode: number;
  readonly uid: number;
  /** Digest of the unchanged source bytes. */
  readonly digest: string;
  /** Digest of the staged bytes after approved provider-root rewriting. */
  readonly stagedDigest: string;
}
export interface DelegatedRootDirectoryManifest {
  readonly source?: string;
  readonly path: string;
  readonly mode: number;
  readonly uid: number;
}
interface DelegatedRootMarker {
  readonly version: 3;
  readonly operationID: string;
  readonly sources: readonly string[];
  readonly destination: string;
  readonly staging: string;
  readonly retired: readonly string[];
  readonly entries: readonly DelegatedRootEntryManifest[];
  /** Exact staged directory inventory, including the staging root at path "". */
  readonly directories: readonly DelegatedRootDirectoryManifest[];
  /** Source directory metadata is kept separate from the rewritten staged tree. */
  readonly sourceDirectories: readonly DelegatedRootDirectoryManifest[];
  readonly phase: "staged" | "source-retired" | "published";
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
function markerPath(staging: string): string { return `${staging}.tron-delegated-cutover.json`; }
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
async function regular(path: string, label: string): Promise<{ bytes: number; mode: number; uid: number }> {
  await rejectRedirectedParents(path);
  let entry;
  try { entry = await lstat(path); } catch { fail(`${label} is missing or unreadable`); }
  if (!entry!.isFile() || entry!.isSymbolicLink() || entry!.nlink !== 1 || !privateMode(entry!.mode)
    || process.getuid?.() !== undefined && entry!.uid !== process.getuid?.()) {
    fail(`${label} must be a private owner-only regular file`);
  }
  if (entry!.size > MAX_FILE_BYTES) fail(`${label} exceeds the bounded migration size`);
  return { bytes: entry!.size, mode: entry!.mode & 0o7777, uid: entry!.uid };
}
async function assertMissing(path: string, label: string): Promise<void> {
  try { await lstat(path); fail(`${label} already exists; migration never merges or overwrites`); }
  catch (error) {
    if (error instanceof DelegatedRootMigrationError) throw error;
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") fail(`${label} cannot be inspected safely`);
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

function rewritten(bytes: Buffer, sourceRoots: readonly string[], destination: string): Buffer {
  if (bytes.length === 0) return bytes;
  let text: string;
  try { text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); } catch { return bytes; }
  for (const source of sourceRoots) {
    // Only exact provider-root references are rewritten. Session transcripts
    // and arbitrary paths outside the provider roots remain byte-for-byte.
    const escaped = source.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
    text = text.replace(new RegExp(`${escaped}(?=/|[\\s"'\\\\]|$)`, "gu"), () => destination);
  }
  return Buffer.from(text, "utf8");
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
  // pi-subagents 0.59.0 scopes its Mac temporary store to the current UID.
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

async function markerRead(stagingInput: string): Promise<DelegatedRootMarker> {
  const staging = absolute(stagingInput, "staging");
  const path = markerPath(staging);
  const metadata = await regular(path, "migration marker");
  if (metadata.bytes > 256 * 1024) fail("migration marker is oversized");
  let value: unknown; try { value = JSON.parse(await readFile(path, "utf8")); } catch { fail("migration marker is malformed"); }
  const marker = value as Partial<DelegatedRootMarker>;
  if (marker.version !== MARKER_VERSION || typeof marker.operationID !== "string" || !Array.isArray(marker.sources)
    || typeof marker.destination !== "string" || typeof marker.staging !== "string" || !Array.isArray(marker.retired)
    || !Array.isArray(marker.entries) || !Array.isArray(marker.directories) || !Array.isArray(marker.sourceDirectories)
    || !["staged", "source-retired", "published"].includes(marker.phase ?? "")
    || resolve(marker.staging) !== staging) fail("migration marker is malformed");
  return marker as DelegatedRootMarker;
}
async function copyTree(sources: readonly string[], staging: string, destinationRoot: string): Promise<{ manifests: DelegatedRootEntryManifest[]; directories: DelegatedRootDirectoryManifest[] }> {
  const manifests: DelegatedRootEntryManifest[] = [];
  const occupied = new Set<string>();
  const directories: DelegatedRootDirectoryManifest[] = [];
  const directoryModes = new Map<string, { mode: number; uid: number }>();
  for (const source of sources) {
    const inventory = await walk(source, true);
    for (const directory of inventory.directories) {
      const path = directory.relativePath;
      const prior = directoryModes.get(path);
      if (prior && (prior.mode !== directory.mode || prior.uid !== directory.uid)) fail(`delegated directory metadata collision during staging: ${path}`);
      if (!prior) {
        directoryModes.set(path, { mode: directory.mode, uid: directory.uid });
        directories.push({ source, path, mode: directory.mode & 0o700, uid: directory.uid });
      }
      await mkdir(join(staging, path), { recursive: true, mode: directory.mode & 0o700 });
      await chmod(join(staging, path), directory.mode & 0o700);
    }
    for (const file of inventory.files) {
      const path = file.relativePath;
      if (occupied.has(path)) fail(`delegated artifact path collision during staging: ${path}`);
      occupied.add(path);
      const destination = join(staging, path);
      await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
      const original = await readFile(file.absolutePath);
      const bytes = rewritten(original, sources, destinationRoot);
      await writeFile(destination, bytes, { flag: "wx", mode: file.mode & 0o700 });
      await chmod(destination, file.mode & 0o700);
      manifests.push({ source, path, bytes: original.byteLength, mode: file.mode, uid: file.uid,
        digest: createHash("sha256").update(original).digest("hex"), stagedDigest: createHash("sha256").update(bytes).digest("hex") });
    }
  }
  return { manifests, directories };
}

export async function stageDelegatedRootCutover(options: DelegatedRootMigrationStageOptions): Promise<DelegatedRootMarker> {
  if (!options.acknowledgeQuiescence || !options.acknowledgeBackup) fail("staging requires explicit quiescence and backup acknowledgements");
  const destination = absolute(options.destinationRoot, "destination root");
  const staging = absolute(options.staging, "staging");
  if ([destination, ...options.legacyRoots].some(root => within(resolve(root), staging) || within(staging, resolve(root)))) fail("delegated staging overlaps an authority");
  await rejectRedirectedParents(staging);
  const preflight = await preflightDelegatedRootCutover(options);
  if (preflight.status === "not-required") fail("no retained delegated artifacts require migration");
  if (preflight.status === "conflict") fail("delegated cutover preflight found an active, unresumable, overlapping, or conflicting authority");
  await assertMissing(destination, "destination root");
  await assertMissing(staging, "staging root");
  await assertMissing(markerPath(staging), "staging marker");
  await mkdir(dirname(staging), { recursive: true, mode: 0o700 });
  await mkdir(staging, { recursive: true, mode: 0o700 });
  const sources = preflight.roots.filter(root => root.entries > 0).map(root => root.root);
  const operationID = randomUUID();
  const retired = sources.map(source => `${source}.retired-${operationID}`);
  const marker: DelegatedRootMarker = { version: 3, operationID, sources, destination, staging, retired, entries: [], directories: [], sourceDirectories: [], phase: "staged" };
  await writeFile(markerPath(staging), `${JSON.stringify(marker)}\n`, { flag: "wx", mode: 0o600 });
  const copied = await copyTree(sources, staging, destination);
  const sourceDirectories: DelegatedRootDirectoryManifest[] = [];
  for (const source of sources) {
    const inventory = await walk(source, true);
    sourceDirectories.push(...inventory.directories.map(directory => ({ source, path: directory.relativePath, mode: directory.mode, uid: directory.uid })));
  }
  const completed = { ...marker, entries: copied.manifests, directories: copied.directories, sourceDirectories };
  await replaceMarker(completed);
  return completed;
}

function safeManifestPath(path: string, label: string, allowRoot = false): void {
  if ((!allowRoot && !path) || isAbsolute(path) || path === ".." || path.startsWith(`..${sep}`)) fail(`${label} contains an unsafe relative path`);
}
async function verifySourceRoot(marker: DelegatedRootMarker, index: number): Promise<void> {
  const sourceRoot = marker.sources[index] ?? fail("delegated source manifest is malformed");
  const source = sourceRoot;
  const inventory = await walk(sourceRoot, true);
  const files = marker.entries.filter(entry => entry.source === source);
  const directories = marker.sourceDirectories.filter(entry => entry.source === source);
  if (new Set(files.map(entry => entry.path)).size !== files.length || new Set(directories.map(entry => entry.path)).size !== directories.length) fail("delegated source manifest contains duplicate paths");
  if (files.length !== inventory.files.length || directories.length !== inventory.directories.length) fail(`delegated source inventory changed: ${source}`);
  for (const file of inventory.files) {
    const entry = files.find(candidate => candidate.path === file.relativePath);
    if (!entry || entry.bytes !== file.bytes || entry.mode !== file.mode || entry.uid !== file.uid
      || entry.digest !== createHash("sha256").update(await readFile(file.absolutePath)).digest("hex")) fail(`delegated source changed: ${source}/${file.relativePath}`);
  }
  for (const directory of inventory.directories) {
    const entry = directories.find(candidate => candidate.path === directory.relativePath);
    if (!entry || entry.mode !== directory.mode || entry.uid !== directory.uid) fail(`delegated source directory changed: ${source}/${directory.relativePath}`);
  }
}
async function verifySourceTree(marker: DelegatedRootMarker): Promise<void> {
  for (let index = 0; index < marker.sources.length; index += 1) await verifySourceRoot(marker, index);
}
async function verifyStagedContents(marker: DelegatedRootMarker): Promise<void> {
  const inventory = await walk(marker.staging);
  if (new Set(marker.entries.map(entry => entry.path)).size !== marker.entries.length || new Set(marker.directories.map(entry => entry.path)).size !== marker.directories.length) fail("staged delegated manifest contains duplicate paths");
  if (inventory.files.length !== marker.entries.length || inventory.directories.length !== marker.directories.length) fail("staged delegated inventory contains missing or extra entries");
  for (const directory of inventory.directories) {
    safeManifestPath(directory.relativePath, "staged directory manifest", true);
    const expected = marker.directories.find(candidate => candidate.path === directory.relativePath);
    if (!expected || expected.mode !== directory.mode || expected.uid !== directory.uid) fail(`staged delegated directory changed: ${directory.relativePath}`);
  }
  for (const entry of marker.entries) {
    if (!marker.sources.includes(entry.source)) fail("staged file manifest references an unlisted source");
    safeManifestPath(entry.path, "staged file manifest");
    const file = inventory.files.find(candidate => candidate.relativePath === entry.path);
    const stagedFile = file ?? fail(`staged delegated artifact is missing: ${entry.path}`);
    const metadata = await regular(stagedFile.absolutePath, `staged delegated artifact ${entry.path}`);
    const digest = createHash("sha256").update(await readFile(stagedFile.absolutePath)).digest("hex");
    if (metadata.bytes !== stagedFile.bytes || metadata.mode !== (entry.mode & 0o700) || metadata.uid !== entry.uid || digest !== entry.stagedDigest) fail(`staged delegated artifact changed: ${entry.path}`);
  }
}
async function verifyStaged(marker: DelegatedRootMarker): Promise<void> {
  if (marker.phase !== "staged") fail("delegated migration has already started publication");
  await assertMissing(marker.destination, "destination root");
  await verifySourceTree(marker);
  await verifyStagedContents(marker);
}
async function verifyRetiredTree(marker: DelegatedRootMarker, index: number): Promise<void> {
  const retiredRoot = marker.retired[index] ?? fail("delegated retirement manifest is malformed");
  const sourceRoot = marker.sources[index] ?? fail("delegated retirement manifest is malformed");
  const root = retiredRoot;
  const source = sourceRoot;
  const inventory = await walk(retiredRoot, true);
  const expectedFiles = marker.entries.filter(entry => entry.source === source);
  const expectedDirectories = marker.sourceDirectories.filter(entry => entry.source === source);
  if (new Set(expectedFiles.map(entry => entry.path)).size !== expectedFiles.length || new Set(expectedDirectories.map(entry => entry.path)).size !== expectedDirectories.length) fail("retired delegated manifest contains duplicate paths");
  if (inventory.files.length !== expectedFiles.length || inventory.directories.length !== expectedDirectories.length) fail(`retired delegated inventory changed: ${root}`);
  for (const file of inventory.files) {
    const entry = expectedFiles.find(candidate => candidate.path === file.relativePath);
    if (!entry || entry.bytes !== file.bytes || entry.mode !== file.mode || entry.uid !== file.uid
      || entry.digest !== createHash("sha256").update(await readFile(file.absolutePath)).digest("hex")) fail(`retired delegated artifact changed: ${root}/${file.relativePath}`);
  }
  for (const directory of inventory.directories) {
    const entry = expectedDirectories.find(candidate => candidate.path === directory.relativePath);
    if (!entry || entry.mode !== directory.mode || entry.uid !== directory.uid) fail(`retired delegated directory changed: ${root}/${directory.relativePath}`);
  }
}
async function verifyPublishedTree(marker: DelegatedRootMarker): Promise<void> {
  const inventory = await walk(marker.destination);
  if (new Set(marker.entries.map(entry => entry.path)).size !== marker.entries.length || new Set(marker.directories.map(entry => entry.path)).size !== marker.directories.length) fail("published delegated manifest contains duplicate paths");
  if (inventory.files.length !== marker.entries.length || inventory.directories.length !== marker.directories.length) fail("published delegated inventory contains missing or extra entries");
  for (const directory of inventory.directories) {
    const expected = marker.directories.find(candidate => candidate.path === directory.relativePath);
    if (!expected || expected.mode !== directory.mode || expected.uid !== directory.uid) fail(`published delegated directory changed: ${directory.relativePath}`);
  }
  for (const entry of marker.entries) {
    const file = inventory.files.find(candidate => candidate.relativePath === entry.path);
    if (!file || entry.uid !== file.uid || (entry.mode & 0o700) !== file.mode || entry.stagedDigest !== createHash("sha256").update(await readFile(file.absolutePath)).digest("hex")) fail(`published delegated artifact changed: ${entry.path}`);
  }
}
async function ensureDestinationParent(destination: string): Promise<void> {
  const parent = dirname(destination);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  let resolvedParent = "";
  try {
    resolvedParent = await realpath(parent);
    const resolvedAncestor = await realpath(dirname(parent));
    if (resolvedParent !== join(resolvedAncestor, basename(parent))) fail("delegated destination parent resolves through a substitution");
  } catch { fail("delegated destination parent cannot be inspected safely"); }
  await ownerDirectory(parent, "delegated destination parent");
}
async function replaceMarker(marker: DelegatedRootMarker): Promise<void> {
  await durableAtomicWriteJson(markerPath(marker.staging), marker, 0o600);
}
export async function verifyDelegatedRootCutover(staging: string): Promise<DelegatedRootMarker> {
  const marker = await markerRead(staging); await verifyStaged(marker); return marker;
}
export async function publishDelegatedRootCutover(staging: string): Promise<DelegatedRootMarker> {
  const marker = await markerRead(staging); await verifyStaged(marker);
  // The parent is checked before journaling retirement, so a missing or
  // substituted destination cannot leave sources retired with nowhere to publish.
  await ensureDestinationParent(marker.destination);
  // Record the publication phase before the first source rename. If the
  // process dies between roots, recovery can finish the exact remaining
  // renames instead of mistaking a partially retired set for corruption.
  const retiringMarker = { ...marker, phase: "source-retired" as const };
  await replaceMarker(retiringMarker);
  for (let index = 0; index < marker.sources.length; index += 1) {
    const sourceExists = await lstat(marker.sources[index]!).then(() => true).catch(() => false);
    const retiredExists = await lstat(marker.retired[index]!).then(() => true).catch(() => false);
    if (sourceExists && retiredExists) fail("delegated source and retired root both exist during publication");
    if (sourceExists) { await assertMissing(marker.retired[index]!, "retired legacy root"); await rename(marker.sources[index]!, marker.retired[index]!); }
    else if (!retiredExists) fail("delegated source disappeared before publication completed");
  }
  await rename(marker.staging, marker.destination);
  const published = { ...retiringMarker, phase: "published" as const };
  await verifyPublishedTree(published);
  await replaceMarker(published);
  return published;
}
export async function recoverDelegatedRootCutover(staging: string): Promise<{ readonly action: "none" | "finish-publication" | "conflict"; readonly marker: DelegatedRootMarker }> {
  const marker = await markerRead(staging);
  if (marker.phase === "published") { await verifyPublishedTree(marker); return { action: "none", marker }; }
  const destinationExists = await lstat(marker.destination).then(() => true).catch(() => false);
  const stagingExists = await lstat(marker.staging).then(() => true).catch(() => false);
  const sourceStates = await Promise.all(marker.sources.map(source => lstat(source).then(() => true).catch(() => false)));
  if (marker.phase === "staged" && sourceStates.every(Boolean) && !destinationExists && stagingExists) {
    const published = await publishDelegatedRootCutover(staging); return { action: "finish-publication", marker: published };
  }
  if (marker.phase === "source-retired" && !destinationExists && stagingExists) {
    await verifyStagedContents(marker);
    await ensureDestinationParent(marker.destination);
    for (let index = 0; index < marker.sources.length; index += 1) {
      const sourceExists = await lstat(marker.sources[index]!).then(() => true).catch(() => false);
      const retiredExists = await lstat(marker.retired[index]!).then(() => true).catch(() => false);
      if (sourceExists && retiredExists) return { action: "conflict", marker };
      if (sourceExists) { await verifySourceRoot(marker, index); await assertMissing(marker.retired[index]!, "retired legacy root"); await rename(marker.sources[index]!, marker.retired[index]!); }
      else if (!retiredExists) return { action: "conflict", marker };
      await verifyRetiredTree(marker, index);
    }
    await rename(marker.staging, marker.destination);
    const published = { ...marker, phase: "published" as const }; await verifyPublishedTree(published); await replaceMarker(published);
    return { action: "finish-publication", marker: published };
  }
  if (marker.phase === "source-retired" && destinationExists && !stagingExists) {
    await verifyPublishedTree(marker);
    const published = { ...marker, phase: "published" as const }; await replaceMarker(published); return { action: "none", marker: published };
  }
  return { action: "conflict", marker };
}
export async function cleanupDelegatedRootCutover(staging: string): Promise<void> {
  const marker = await markerRead(staging); if (marker.phase !== "staged") fail("only an unpublished delegated staging tree may be cleaned");
  await rm(marker.staging, { recursive: true, force: false }); await rm(markerPath(marker.staging), { force: false });
}

export async function assertDelegatedRootCutoverReady(tronHome: string): Promise<void> {
  const destinationRoot = join(resolve(tronHome), "internal", "subagents");
  const legacyRoots = discoverDelegatedLegacyRoots({ destinationRoot, legacyRoot: process.env.PI_SUBAGENTS_TEMP_ROOT });
  const preflight = await preflightDelegatedRootCutover({ legacyRoots, destinationRoot });
  if (preflight.status !== "not-required") {
    const roots = preflight.roots.filter(root => root.entries > 0).map(root => root.root).join(", ");
    throw new DelegatedRootMigrationError(`delegated artifact migration required before startup; retained provider roots outside ${destinationRoot}: ${roots || "conflicting destination"}. Quiesce all delegated runs, then run scripts/tron delegated-migrate preflight --destination-root ${destinationRoot} --legacy-root <root> and the documented stage/verify/publish workflow`);
  }
}

function argument(args: readonly string[], name: string): string | undefined { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; }
function allArguments(args: readonly string[], name: string): string[] { const values: string[] = []; for (let index = 0; index < args.length; index += 1) if (args[index] === name && args[index + 1]) values.push(args[index + 1]!); return values; }
function usage(): never { console.error("Usage: scripts/tron delegated-migrate <preflight|stage|verify|publish|recover|cleanup> --destination-root <path> [--legacy-root <path> ...] --staging <path>"); process.exit(64); }
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [operation, ...args] = process.argv.slice(2); const destinationRoot = argument(args, "--destination-root"); const staging = argument(args, "--staging"); const legacyRoots = allArguments(args, "--legacy-root");
  try {
    if (!operation || !destinationRoot || operation === "preflight" && !legacyRoots.length || !["preflight", "stage", "verify", "publish", "recover", "cleanup"].includes(operation)) usage();
    let result: unknown;
    if (operation === "preflight") result = await preflightDelegatedRootCutover({ destinationRoot, legacyRoots });
    else if (operation === "stage") result = await stageDelegatedRootCutover({ destinationRoot, legacyRoots, staging: staging ?? usage(), acknowledgeQuiescence: args.includes("--acknowledge-quiescence"), acknowledgeBackup: args.includes("--acknowledge-backup") });
    else if (operation === "verify") result = await verifyDelegatedRootCutover(staging ?? usage());
    else if (operation === "publish") result = await publishDelegatedRootCutover(staging ?? usage());
    else if (operation === "recover") result = await recoverDelegatedRootCutover(staging ?? usage());
    else result = await cleanupDelegatedRootCutover(staging ?? usage());
    process.stdout.write(`${JSON.stringify(await result, null, 2)}\n`);
  } catch (error) { console.error(error instanceof DelegatedRootMigrationError ? error.message : "delegated artifact migration failed"); process.exitCode = 2; }
}
