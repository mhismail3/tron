import { createHash, randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const MAX_BYTES = 64 * 1024 * 1024;
const MARKER_VERSION = 1;

export interface InternalMigrationOptions {
  readonly source: string;
  readonly destination: string;
  readonly staging: string;
  readonly acknowledgeQuiescence: boolean;
  readonly acknowledgeBackup: boolean;
}
export interface InternalMigrationManifest {
  readonly version: 1;
  readonly bytes: number;
  readonly mode: number;
  readonly digest: string;
}
interface Marker {
  readonly version: 1;
  readonly operationID: string;
  readonly source: string;
  readonly destination: string;
  readonly staging: string;
  readonly retired: string;
  readonly manifest: InternalMigrationManifest;
  readonly phase: "staged" | "source-retired" | "published";
}

export class InternalMigrationError extends Error {
  constructor(message: string) { super(message); this.name = "InternalMigrationError"; }
}
const fail = (message: string): never => { throw new InternalMigrationError(message); };
const markerPath = (staging: string) => `${staging}.tron-internal-migration.json`;

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
async function regular(path: string, label: string): Promise<import("node:fs").Stats> {
  let entry: import("node:fs").Stats;
  try { entry = await lstat(path); } catch { fail(`${label} is missing or unreadable`); }
  if (!entry!.isFile() || entry!.isSymbolicLink() || entry!.nlink !== 1 || (entry!.mode & 0o077) !== 0) {
    fail(`${label} must be an owner-only regular file`);
  }
  if (entry!.size > MAX_BYTES) fail(`${label} exceeds the bounded migration size`);
  return entry!;
}
async function manifest(path: string): Promise<InternalMigrationManifest> {
  const entry = await regular(path, "migration source");
  const digest = createHash("sha256").update(await readFile(path)).digest("hex");
  return { version: 1, bytes: entry.size, mode: entry.mode & 0o7777, digest };
}
async function assertMissing(path: string, label: string): Promise<void> {
  try {
    await lstat(path);
    fail(`${label} already exists; migration never merges or overwrites`);
  } catch (error) {
    if (error instanceof InternalMigrationError) throw error;
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") fail(`${label} cannot be inspected safely`);
  }
}
async function markerRead(staging: string): Promise<Marker> {
  const path = markerPath(staging);
  const entry = await regular(path, "migration marker");
  if (entry.size > 64 * 1024) fail("migration marker is oversized");
  let value: unknown;
  try { value = JSON.parse(await readFile(path, "utf8")); } catch { fail("migration marker is malformed"); }
  const marker = value as Partial<Marker>;
  if (!marker || marker.version !== MARKER_VERSION || typeof marker.operationID !== "string"
    || typeof marker.source !== "string" || typeof marker.destination !== "string"
    || typeof marker.staging !== "string" || typeof marker.retired !== "string"
    || !marker.manifest || !["staged", "source-retired", "published"].includes(marker.phase ?? "")
    || resolve(marker.staging) !== resolve(staging)) fail("migration marker is malformed");
  return marker as Marker;
}
async function markerWrite(path: string, value: Marker): Promise<void> {
  await writeFile(path, `${JSON.stringify(value)}\n`, { flag: "wx", mode: 0o600 });
}
async function markerReplace(path: string, value: Marker): Promise<void> {
  const temporary = `${path}.${value.operationID}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value)}\n`, { flag: "wx", mode: 0o600 });
  await rename(temporary, path);
}
function validateManifest(actual: InternalMigrationManifest, expected: InternalMigrationManifest): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) fail("migration bytes or permissions changed");
}

export async function preflightInternalLayout(options: Pick<InternalMigrationOptions, "source" | "destination">): Promise<{
  readonly status: "not-required" | "migration-required" | "conflict";
  readonly source: string;
  readonly destination: string;
  readonly sourceManifest?: InternalMigrationManifest;
  readonly changesMade: false;
}> {
  const source = absolute(options.source, "source");
  const destination = absolute(options.destination, "destination");
  if (source === destination || within(source, destination) || within(destination, source)) fail("migration roots overlap");
  let sourceManifest: InternalMigrationManifest | undefined;
  try { sourceManifest = await manifest(source); } catch (error) {
    if (!(error instanceof InternalMigrationError) || !error.message.includes("missing")) throw error;
  }
  let destinationManifest: InternalMigrationManifest | undefined;
  try { destinationManifest = await manifest(destination); } catch (error) {
    if (!(error instanceof InternalMigrationError) || !error.message.includes("missing")) throw error;
  }
  if (!sourceManifest && !destinationManifest) return { status: "not-required", source, destination, changesMade: false };
  if (sourceManifest && destinationManifest) {
    return { status: sourceManifest.digest === destinationManifest.digest && sourceManifest.bytes === destinationManifest.bytes ? "migration-required" : "conflict", source, destination, sourceManifest, changesMade: false };
  }
  return { status: sourceManifest ? "migration-required" : "not-required", source, destination, ...(sourceManifest ? { sourceManifest } : {}), changesMade: false };
}

export async function stageInternalLayout(options: InternalMigrationOptions): Promise<Marker> {
  if (!options.acknowledgeQuiescence || !options.acknowledgeBackup) fail("staging requires explicit quiescence and backup acknowledgements");
  const source = absolute(options.source, "source");
  const destination = absolute(options.destination, "destination");
  const staging = absolute(options.staging, "staging");
  if (within(source, staging) || within(staging, source) || within(source, destination) || within(destination, source)) fail("migration roots overlap");
  const sourceEntry = await regular(source, "migration source");
  await assertMissing(destination, "destination");
  await assertMissing(staging, "staging");
  await assertMissing(markerPath(staging), "staging marker");
  await mkdir(dirname(staging), { recursive: true, mode: 0o700 });
  const sourceManifest = await manifest(source);
  const operationID = randomUUID();
  const retired = `${source}.retired-${operationID}`;
  const value: Marker = { version: 1, operationID, source, destination, staging, retired, manifest: sourceManifest, phase: "staged" };
  await markerWrite(markerPath(staging), value);
  try {
    await mkdir(dirname(staging), { recursive: true, mode: 0o700 });
    const bytes = await readFile(source);
    if (bytes.byteLength !== sourceEntry.size) fail("source changed during staging");
    await writeFile(staging, bytes, { flag: "wx", mode: sourceManifest.mode });
    await chmod(staging, sourceManifest.mode);
    validateManifest(await manifest(source), sourceManifest);
    validateManifest(await manifest(staging), sourceManifest);
    return value;
  } catch (error) {
    // Preserve the marker and partial staging for explicit recovery/cleanup.
    throw error;
  }
}

export async function verifyInternalLayout(stagingInput: string): Promise<Marker> {
  const staging = absolute(stagingInput, "staging");
  const marker = await markerRead(staging);
  if (marker.phase !== "staged") fail("migration has already published or was interrupted during publication");
  validateManifest(await manifest(marker.source), marker.manifest);
  validateManifest(await manifest(marker.staging), marker.manifest);
  await assertMissing(marker.destination, "destination");
  return marker;
}

/** Publication is explicit and never called by Gateway startup. */
export async function publishInternalLayout(stagingInput: string): Promise<Marker> {
  const marker = await verifyInternalLayout(stagingInput);
  await assertMissing(marker.retired, "retired source");
  await rename(marker.source, marker.retired);
  await markerReplace(markerPath(marker.staging), { ...marker, phase: "source-retired" });
  await rename(marker.staging, marker.destination);
  const published = { ...marker, phase: "published" as const };
  await writeFile(markerPath(marker.staging), `${JSON.stringify(published)}\n`, { flag: "w", mode: 0o600 });
  return published;
}

export async function recoverInternalLayout(stagingInput: string): Promise<{ readonly action: "none" | "finish-publication" | "conflict"; readonly marker: Marker }> {
  const staging = absolute(stagingInput, "staging");
  const marker = await markerRead(staging);
  if (marker.phase === "published") return { action: "none", marker };
  const sourceExists = await lstat(marker.source).then(() => true).catch(() => false);
  const destinationExists = await lstat(marker.destination).then(() => true).catch(() => false);
  const stagingExists = await lstat(marker.staging).then(() => true).catch(() => false);
  if ((marker.phase === "staged" || marker.phase === "source-retired") && !sourceExists && !destinationExists && stagingExists) {
    const retired = { ...marker, phase: "source-retired" as const };
    if (marker.phase === "staged") await markerReplace(markerPath(marker.staging), retired);
    return { action: "finish-publication", marker: retired };
  }
  if (marker.phase === "source-retired" && !sourceExists && destinationExists && !stagingExists) {
    validateManifest(await manifest(marker.destination), marker.manifest);
    const published = { ...marker, phase: "published" as const };
    await writeFile(markerPath(marker.staging), `${JSON.stringify(published)}\n`, { flag: "w", mode: 0o600 });
    return { action: "none", marker: published };
  }
  if (sourceExists && destinationExists) return { action: "conflict", marker };
  return { action: "none", marker };
}

export async function cleanupInternalLayout(stagingInput: string): Promise<void> {
  const marker = await markerRead(stagingInput);
  if (marker.phase !== "staged") fail("only an un published staging tree may be cleaned");
  await rm(marker.staging, { force: false });
  await rm(markerPath(marker.staging), { force: false });
}

function argument(args: readonly string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index < 0 ? undefined : args[index + 1];
}
function usage(): never {
  console.error("Usage: scripts/tron internal-migrate <preflight|stage|verify|publish|recover|cleanup> --source <path> --destination <path> --staging <path>");
  process.exit(64);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [operation, ...args] = process.argv.slice(2);
  const source = argument(args, "--source");
  const destination = argument(args, "--destination");
  const staging = argument(args, "--staging");
  try {
    if (!operation || !staging || operation === "preflight" && (!source || !destination)) usage();
    let result: unknown;
    if (operation === "preflight") result = await preflightInternalLayout({ source: source!, destination: destination! });
    else if (operation === "stage") result = await stageInternalLayout({ source: source!, destination: destination!, staging, acknowledgeQuiescence: args.includes("--acknowledge-quiescence"), acknowledgeBackup: args.includes("--acknowledge-backup") });
    else if (operation === "verify") result = await verifyInternalLayout(staging);
    else if (operation === "publish") result = publishInternalLayout(staging);
    else if (operation === "recover") result = recoverInternalLayout(staging);
    else if (operation === "cleanup") result = cleanupInternalLayout(staging);
    else usage();
    process.stdout.write(`${JSON.stringify(await result, null, 2)}\n`);
  } catch (error) {
    console.error(error instanceof InternalMigrationError ? error.message : "internal migration failed");
    process.exitCode = 2;
  }
}
