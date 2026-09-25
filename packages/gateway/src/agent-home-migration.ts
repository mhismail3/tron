import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { chmod, copyFile, lchmod, lstat, mkdir, opendir, readFile, readlink, realpath, rename, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { preflightAgentHome } from "./agent-home-preflight.js";

const MAX_ENTRIES = 100_000;
const MAX_FILE_BYTES = 1 * 1024 * 1024 * 1024;
const MARKER_MAX_BYTES = 64 * 1024;
const MARKER_VERSION = 1;
const MARKER_SUFFIX = ".tron-agent-migration.json";
const SETTINGS_MAX_BYTES = 1 * 1024 * 1024;
const LEGACY_ASK_USER_SOURCE = "npm:@zhushanwen/pi-ask-user@7.0.15";

type EntryType = "directory" | "file" | "symlink";

export interface AgentHomeManifestEntry {
  readonly path: string;
  readonly type: EntryType;
  readonly mode: number;
  readonly bytes?: number;
  readonly digest?: string;
  readonly target?: string;
}

export interface AgentHomeManifest {
  readonly version: 1;
  readonly entries: readonly AgentHomeManifestEntry[];
  readonly digest: string;
}

export interface AgentHomeStageOptions {
  readonly source: string;
  readonly destination: string;
  readonly staging: string;
  readonly maxEntries?: number;
  readonly acknowledgeQuiescence: boolean;
  readonly acknowledgeBackup: boolean;
  /** Explicitly removes only the audited legacy Ask User package from staged settings. */
  readonly removeLegacyAskUser?: boolean;
}

export interface AgentHomeStageResult {
  readonly operation: "stage";
  readonly source: string;
  readonly destination: string;
  readonly staging: string;
  readonly sourceManifest: AgentHomeManifest;
  readonly stagedManifest: AgentHomeManifest;
  readonly publicationMode: "same-filesystem-rename" | "cross-filesystem-copy-required";
  readonly legacyAskUserTransform?: AgentHomeLegacyAskUserTransform;
  readonly changesMade: true;
}

export interface AgentHomeVerifyResult {
  readonly operation: "verify";
  readonly source: string;
  readonly destination: string;
  readonly staging: string;
  readonly sourceManifest: AgentHomeManifest;
  readonly stagedManifest: AgentHomeManifest;
  readonly publicationMode: "same-filesystem-rename" | "cross-filesystem-copy-required";
  readonly legacyAskUserTransform?: AgentHomeLegacyAskUserTransform;
  readonly changesMade: false;
}

export interface AgentHomeCleanupResult {
  readonly operation: "cleanup";
  readonly staging: string;
  readonly changesMade: true;
}

export interface AgentHomeLegacyAskUserTransform {
  readonly source: typeof LEGACY_ASK_USER_SOURCE;
  readonly removedCount: number;
  readonly originalSettingsDigest: string;
  readonly transformedSettingsBytes: number;
  readonly transformedSettingsDigest: string;
}

interface StageMarker {
  readonly version: 1;
  readonly operationID: string;
  readonly source: string;
  readonly destination: string;
  readonly staging: string;
  readonly sourceDigest: string;
  readonly entryCount: number;
  readonly phase: "copying" | "complete";
  readonly legacyAskUserTransform?: AgentHomeLegacyAskUserTransform;
}

export class AgentHomeMigrationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AgentHomeMigrationError";
  }
}

function fail(message: string): never {
  throw new AgentHomeMigrationError(message);
}

function assertAbsolute(value: string, label: string): string {
  if (typeof value !== "string" || !isAbsolute(value)) fail(`${label} must be an absolute path`);
  const normalized = resolve(value);
  if (normalized === resolve(sep)) fail(`${label} cannot be the filesystem root`);
  return normalized;
}

function within(root: string, candidate: string): boolean {
  const remainder = relative(root, candidate);
  return remainder === "" || (!remainder.startsWith(`..${sep}`) && remainder !== ".." && !isAbsolute(remainder));
}

function modeOf(mode: number): number {
  return mode & 0o7777;
}

async function hashFile(path: string, bytes: number): Promise<string> {
  if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > MAX_FILE_BYTES) fail("file exceeds the bounded migration size");
  const hash = createHash("sha256");
  await new Promise<void>((resolvePromise, reject) => {
    const stream = createReadStream(path, { highWaterMark: 64 * 1024 });
    stream.on("data", chunk => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolvePromise());
  });
  return hash.digest("hex");
}

async function prepareLegacyAskUserTransform(sourceRoot: string, enabled: boolean): Promise<{ transform?: AgentHomeLegacyAskUserTransform; content?: string }> {
  if (!enabled) return {};
  const settingsPath = join(sourceRoot, "settings.json");
  let entry;
  try { entry = await lstat(settingsPath); } catch { fail("legacy Ask User removal requires a readable settings.json"); }
  if (entry.isSymbolicLink() || !entry.isFile() || entry.size > SETTINGS_MAX_BYTES) fail("legacy Ask User removal requires a bounded regular settings.json");
  let document: unknown;
  let original: string;
  try {
    original = await readFile(settingsPath, "utf8");
    document = JSON.parse(original);
  } catch { fail("legacy Ask User removal requires valid settings.json"); }
  if (!document || typeof document !== "object" || Array.isArray(document)) fail("legacy Ask User removal requires an object settings.json");
  const values = document as Record<string, unknown>;
  if (!Array.isArray(values.packages)) fail("legacy Ask User removal requires a package list in settings.json");
  const packages = values.packages;
  const matches = packages.filter((value) => value === LEGACY_ASK_USER_SOURCE || (value && typeof value === "object" && !Array.isArray(value) && (value as Record<string, unknown>).source === LEGACY_ASK_USER_SOURCE));
  if (matches.length === 0) fail("the audited legacy Ask User package is not configured; refusing an unaccounted settings transform");
  const transformedDocument = { ...values, packages: packages.filter((value) => !matches.includes(value)) };
  const content = `${JSON.stringify(transformedDocument, null, 2)}\n`;
  return {
    content,
    transform: {
      source: LEGACY_ASK_USER_SOURCE,
      removedCount: matches.length,
      originalSettingsDigest: createHash("sha256").update(original).digest("hex"),
      transformedSettingsBytes: Buffer.byteLength(content),
      transformedSettingsDigest: createHash("sha256").update(content).digest("hex"),
    },
  };
}

async function applyLegacyAskUserTransform(stagingRoot: string, transform: AgentHomeLegacyAskUserTransform, content: string): Promise<void> {
  const settingsPath = join(stagingRoot, "settings.json");
  const entry = await lstat(settingsPath);
  if (entry.isSymbolicLink() || !entry.isFile()) fail("staged settings.json changed during the explicit transform");
  await writeFile(settingsPath, content, { flag: "w" });
  await chmod(settingsPath, modeOf(entry.mode));
}

function applySettingsManifestTransform(manifest: AgentHomeManifest, transform: AgentHomeLegacyAskUserTransform): AgentHomeManifest {
  const entries = manifest.entries.map((entry) => entry.path === "settings.json"
    ? { ...entry, bytes: transform.transformedSettingsBytes, digest: transform.transformedSettingsDigest }
    : entry);
  return { version: 1, entries, digest: createHash("sha256").update(JSON.stringify(entries)).digest("hex") };
}

async function safeLinkTarget(root: string, path: string): Promise<string> {
  const target = await readlink(path, "utf8");
  if (target.startsWith("/")) fail("absolute symlinks are not portable across the agent-home move");
  let physical: string;
  try {
    physical = await realpath(path);
  } catch {
    fail("dangling or unresolved symlink prevents a safe staged copy");
  }
  if (!within(root, physical)) fail("symlink escapes the source agent home");
  return target;
}

async function walkManifest(root: string, current: string, output: AgentHomeManifestEntry[], limit: number): Promise<void> {
  if (output.length >= limit) fail("agent home exceeds the bounded entry limit");
  const entry = await lstat(current);
  const path = current === root ? "." : relative(root, current);
  if (entry.isSymbolicLink()) {
    output.push({ path, type: "symlink", mode: modeOf(entry.mode), target: await safeLinkTarget(root, current) });
    return;
  }
  if (entry.isFile()) {
    output.push({ path, type: "file", mode: modeOf(entry.mode), bytes: entry.size, digest: await hashFile(current, entry.size) });
    return;
  }
  if (!entry.isDirectory()) fail("special files are not supported in an agent-home migration");
  output.push({ path, type: "directory", mode: modeOf(entry.mode) });
  const directory = await opendir(current);
  try {
    while (true) {
      const child = await directory.read();
      if (child === null) return;
      await walkManifest(root, join(current, child.name), output, limit);
    }
  } finally {
    await directory.close().catch(() => undefined);
  }
}

export async function createAgentHomeManifest(rootInput: string, maxEntries = MAX_ENTRIES): Promise<AgentHomeManifest> {
  const root = assertAbsolute(rootInput, "source");
  if (!Number.isSafeInteger(maxEntries) || maxEntries < 1 || maxEntries > MAX_ENTRIES) fail("maxEntries is outside the supported bound");
  const rootEntry = await lstat(root);
  if (rootEntry.isSymbolicLink() || !rootEntry.isDirectory()) fail("source must be a real directory");
  const physicalRoot = await realpath(root);
  const entries: AgentHomeManifestEntry[] = [];
  await walkManifest(physicalRoot, physicalRoot, entries, maxEntries);
  entries.sort((left, right) => left.path === right.path ? 0 : left.path < right.path ? -1 : 1);
  const serialized = JSON.stringify(entries);
  return { version: 1, entries, digest: createHash("sha256").update(serialized).digest("hex") };
}

function markerPath(staging: string): string {
  return `${staging}${MARKER_SUFFIX}`;
}

async function requireDirectory(path: string, label: string): Promise<{ dev: number; physical: string }> {
  const entry = await lstat(path);
  if (entry.isSymbolicLink() || !entry.isDirectory()) fail(`${label} must be a real directory`);
  return { dev: entry.dev, physical: await realpath(path) };
}

async function requireMissing(path: string, label: string): Promise<void> {
  try {
    await lstat(path);
    fail(`${label} already exists; migration never merges or overwrites roots`);
  } catch (error) {
    if (error instanceof AgentHomeMigrationError) throw error;
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") fail(`${label} cannot be inspected safely`);
  }
}

async function writeMarker(path: string, marker: StageMarker): Promise<void> {
  await writeFile(path, `${JSON.stringify(marker)}\n`, { flag: "wx", mode: 0o600 });
}

async function replaceMarker(path: string, marker: StageMarker): Promise<void> {
  const temporary = `${path}.${marker.operationID}.tmp`;
  await writeFile(temporary, `${JSON.stringify(marker)}\n`, { flag: "wx", mode: 0o600 });
  try {
    await rename(temporary, path);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
}

async function readMarker(stagingInput: string): Promise<StageMarker> {
  const staging = assertAbsolute(stagingInput, "staging");
  const path = markerPath(staging);
  let parsed: unknown;
  try {
    const markerEntry = await lstat(path);
    if (markerEntry.isSymbolicLink() || !markerEntry.isFile() || (markerEntry.mode & 0o077) !== 0) fail("migration marker is not a private regular file");
    const text = await readFile(path, "utf8");
    if (Buffer.byteLength(text) > MARKER_MAX_BYTES) fail("migration marker is oversized");
    parsed = JSON.parse(text);
  } catch (error) {
    if (error instanceof AgentHomeMigrationError) throw error;
    fail("migration marker is missing or malformed");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) fail("migration marker is malformed");
  const value = parsed as Record<string, unknown>;
  const expectedKeys = ["version", "operationID", "source", "destination", "staging", "sourceDigest", "entryCount", "phase"];
  const transformAllowed = value.legacyAskUserTransform === undefined ? expectedKeys : [...expectedKeys, "legacyAskUserTransform"];
  if (Object.keys(value).length !== transformAllowed.length || !Object.keys(value).every(key => transformAllowed.includes(key))
    || value.version !== MARKER_VERSION || value.phase !== "complete" && value.phase !== "copying"
    || typeof value.operationID !== "string" || value.operationID.length < 1 || value.operationID.length > 128
    || typeof value.source !== "string" || typeof value.destination !== "string" || typeof value.staging !== "string"
    || typeof value.sourceDigest !== "string" || !/^[0-9a-f]{64}$/u.test(value.sourceDigest)
    || !Number.isSafeInteger(value.entryCount) || (value.entryCount as number) < 1 || (value.entryCount as number) > MAX_ENTRIES) {
    fail("migration marker is malformed");
  }
  if (resolve(value.staging) !== staging) fail("migration marker does not belong to this staging root");
  if (value.legacyAskUserTransform !== undefined) {
    const transform = value.legacyAskUserTransform;
    if (!transform || typeof transform !== "object" || Array.isArray(transform)) fail("migration marker settings transform is malformed");
    const component = transform as Record<string, unknown>;
    if (Object.keys(component).length !== 5 || component.source !== LEGACY_ASK_USER_SOURCE || !Number.isSafeInteger(component.removedCount) || (component.removedCount as number) < 1 || typeof component.originalSettingsDigest !== "string" || !/^[0-9a-f]{64}$/u.test(component.originalSettingsDigest) || !Number.isSafeInteger(component.transformedSettingsBytes) || (component.transformedSettingsBytes as number) < 1 || (component.transformedSettingsBytes as number) > SETTINGS_MAX_BYTES || typeof component.transformedSettingsDigest !== "string" || !/^[0-9a-f]{64}$/u.test(component.transformedSettingsDigest)) fail("migration marker settings transform is malformed");
  }
  return value as unknown as StageMarker;
}

async function copyEntry(sourceRoot: string, stagingRoot: string, entry: AgentHomeManifestEntry): Promise<void> {
  const source = entry.path === "." ? sourceRoot : join(sourceRoot, entry.path);
  const destination = entry.path === "." ? stagingRoot : join(stagingRoot, entry.path);
  if (entry.type === "directory") {
    if (entry.path !== ".") await mkdir(destination, { mode: entry.mode });
    await chmod(destination, entry.mode);
    return;
  }
  await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
  if (entry.type === "file") {
    await copyFile(source, destination);
    await chmod(destination, entry.mode);
    return;
  }
  await symlink(entry.target!, destination);
  // macOS assigns link permissions from the caller's umask. Restore the link
  // itself, never its target; chmod would follow it and corrupt target modes.
  if (modeOf((await lstat(destination)).mode) !== entry.mode) {
    await lchmod(destination, entry.mode);
  }
}

function manifestMatches(expected: AgentHomeManifest, actual: AgentHomeManifest): boolean {
  return expected.digest === actual.digest && JSON.stringify(expected.entries) === JSON.stringify(actual.entries);
}

async function publicationMode(staging: string, destination: string): Promise<"same-filesystem-rename" | "cross-filesystem-copy-required"> {
  const stagingParent = await requireDirectory(dirname(staging), "staging parent");
  const destinationParent = await requireDirectory(dirname(destination), "destination parent");
  return stagingParent.dev === destinationParent.dev ? "same-filesystem-rename" : "cross-filesystem-copy-required";
}

function stageMarker(operationID: string, options: AgentHomeStageOptions, sourceDigest: string, entryCount: number, phase: StageMarker["phase"], legacyAskUserTransform?: AgentHomeLegacyAskUserTransform): StageMarker {
  return {
    version: 1, operationID, source: resolve(options.source), destination: resolve(options.destination), staging: resolve(options.staging), sourceDigest, entryCount, phase,
    ...(legacyAskUserTransform ? { legacyAskUserTransform } : {}),
  };
}

export async function stageAgentHome(options: AgentHomeStageOptions): Promise<AgentHomeStageResult> {
  if (!options.acknowledgeQuiescence || !options.acknowledgeBackup) fail("staging requires explicit quiescence and protected-backup acknowledgements");
  const source = assertAbsolute(options.source, "source");
  const destination = assertAbsolute(options.destination, "destination");
  const staging = assertAbsolute(options.staging, "staging");
  if (within(source, staging) || within(staging, source) || within(source, destination) || within(destination, source)) fail("source, destination, and staging roots overlap");
  const sourceDirectory = await requireDirectory(source, "source");
  await requireMissing(destination, "destination");
  await requireMissing(staging, "staging");
  await requireMissing(markerPath(staging), "staging marker");
  const stagingParent = await requireDirectory(dirname(staging), "staging parent");
  const stagingPhysical = join(stagingParent.physical, basename(staging));
  if (within(sourceDirectory.physical, stagingPhysical) || within(stagingPhysical, sourceDirectory.physical)) fail("source and staging roots overlap physically");
  const legacyAskUser = await prepareLegacyAskUserTransform(source, options.removeLegacyAskUser ?? false);
  const preflight = await preflightAgentHome(options.maxEntries === undefined
    ? { source, destination }
    : { source, destination, maxEntries: options.maxEntries });
  if (preflight.status !== "assessment-only") fail("read-only preflight requires explicit owner decisions before staging");
  const sourceManifest = await createAgentHomeManifest(source, options.maxEntries);
  const operationID = randomUUID();
  const marker = markerPath(staging);
  await writeMarker(marker, stageMarker(operationID, options, sourceManifest.digest, sourceManifest.entries.length, "copying", legacyAskUser.transform));
  try {
    await mkdir(staging, { mode: 0o700 });
    for (const entry of sourceManifest.entries) await copyEntry(source, staging, entry);
    if (legacyAskUser.transform && legacyAskUser.content) await applyLegacyAskUserTransform(staging, legacyAskUser.transform, legacyAskUser.content);
    const stagedManifest = await createAgentHomeManifest(staging, options.maxEntries);
    const sourceAfter = await createAgentHomeManifest(source, options.maxEntries);
    const expectedStaged = legacyAskUser.transform ? applySettingsManifestTransform(sourceAfter, legacyAskUser.transform) : sourceAfter;
    if (!manifestMatches(sourceManifest, sourceAfter) || !manifestMatches(expectedStaged, stagedManifest)) fail("source changed or staged manifest does not match; do not publish");
    await replaceMarker(marker, stageMarker(operationID, options, sourceManifest.digest, sourceManifest.entries.length, "complete", legacyAskUser.transform));
    return { operation: "stage", source, destination, staging, sourceManifest, stagedManifest, ...(legacyAskUser.transform ? { legacyAskUserTransform: legacyAskUser.transform } : {}), publicationMode: await publicationMode(staging, destination), changesMade: true };
  } catch (error) {
    // Leave the marked staging tree for explicit verify/cleanup; never delete a
    // partially copied agent home implicitly after a disk or process failure.
    throw error;
  }
}

export async function verifyStagedAgentHome(stagingInput: string, maxEntries = MAX_ENTRIES): Promise<AgentHomeVerifyResult> {
  const marker = await readMarker(stagingInput);
  if (marker.phase !== "complete") fail("staging was interrupted before verification completed; inspect or clean it explicitly");
  const source = assertAbsolute(marker.source, "source");
  const destination = assertAbsolute(marker.destination, "destination");
  const staging = assertAbsolute(marker.staging, "staging");
  await requireDirectory(source, "source");
  await requireDirectory(staging, "staging");
  await requireMissing(destination, "destination");
  const sourceManifest = await createAgentHomeManifest(source, maxEntries);
  const stagedManifest = await createAgentHomeManifest(staging, maxEntries);
  if (sourceManifest.digest !== marker.sourceDigest || sourceManifest.entries.length !== marker.entryCount) fail("source no longer matches the verified manifest");
  let expectedStaged = sourceManifest;
  if (marker.legacyAskUserTransform) {
    const currentTransform = await prepareLegacyAskUserTransform(source, true);
    if (!currentTransform.transform || currentTransform.transform.removedCount !== marker.legacyAskUserTransform.removedCount || currentTransform.transform.originalSettingsDigest !== marker.legacyAskUserTransform.originalSettingsDigest || currentTransform.transform.transformedSettingsBytes !== marker.legacyAskUserTransform.transformedSettingsBytes || currentTransform.transform.transformedSettingsDigest !== marker.legacyAskUserTransform.transformedSettingsDigest) fail("source settings no longer match the verified legacy Ask User transform");
    expectedStaged = applySettingsManifestTransform(sourceManifest, marker.legacyAskUserTransform);
  }
  if (!manifestMatches(expectedStaged, stagedManifest)) fail("staging no longer matches the verified manifest");
  return { operation: "verify", source, destination, staging, sourceManifest, stagedManifest, ...(marker.legacyAskUserTransform ? { legacyAskUserTransform: marker.legacyAskUserTransform } : {}), publicationMode: await publicationMode(staging, destination), changesMade: false };
}

export async function cleanupStagedAgentHome(stagingInput: string): Promise<AgentHomeCleanupResult> {
  const marker = await readMarker(stagingInput);
  const staging = assertAbsolute(marker.staging, "staging");
  let entry;
  try {
    entry = await lstat(staging);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    await unlink(markerPath(staging));
    return { operation: "cleanup", staging, changesMade: true };
  }
  if (entry.isSymbolicLink() || !entry.isDirectory()) fail("staging root is not a removable migration directory");
  await rm(staging, { recursive: true, force: false });
  await unlink(markerPath(staging));
  return { operation: "cleanup", staging, changesMade: true };
}

function usage(): never {
  console.error("Usage: scripts/tron agent-home-migrate <stage|verify|cleanup> ...");
  console.error("stage accepts --remove-legacy-ask-user");
  process.exit(64);
}

function validateMigrationStageArguments(args: readonly string[]): void {
  if (args.includes("--browser-config-source")) {
    throw new AgentHomeMigrationError("--browser-config-source was removed; browser configuration remains outside the agent-home migration");
  }
}

function argument(args: readonly string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index < 0 ? undefined : args[index + 1];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [operation, ...args] = process.argv.slice(2);
  try {
    let result: AgentHomeStageResult | AgentHomeVerifyResult | AgentHomeCleanupResult;
    if (operation === "stage") {
      const source = argument(args, "--source");
      const destination = argument(args, "--destination");
      const staging = argument(args, "--staging");
      validateMigrationStageArguments(args);
      if (!source || !destination || !staging) usage();
      const rawLimit = argument(args, "--max-entries");
      const maxEntries = rawLimit === undefined ? undefined : Number(rawLimit);
      result = await stageAgentHome({
        source,
        destination,
        staging,
        ...(maxEntries === undefined ? {} : { maxEntries }),
        acknowledgeQuiescence: args.includes("--acknowledge-quiescence"),
        acknowledgeBackup: args.includes("--acknowledge-backup"),
        ...(args.includes("--remove-legacy-ask-user") ? { removeLegacyAskUser: true } : {}),
      });
    } else if (operation === "verify") {
      const staging = argument(args, "--staging");
      if (!staging) usage();
      result = await verifyStagedAgentHome(staging, argument(args, "--max-entries") === undefined ? MAX_ENTRIES : Number(argument(args, "--max-entries")));
    } else if (operation === "cleanup") {
      const staging = argument(args, "--staging");
      if (!staging) usage();
      result = await cleanupStagedAgentHome(staging);
    } else usage();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) {
    console.error(error instanceof AgentHomeMigrationError ? error.message : "migration operation failed");
    process.exitCode = 2;
  }
}
