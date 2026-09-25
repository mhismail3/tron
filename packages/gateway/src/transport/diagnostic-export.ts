import { chmod, lstat, mkdir, readdir, rm, stat, writeFile } from "node:fs/promises";
import type { Stats } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { LogRecord } from "./logger.js";

const MAX_EXPORT_BYTES = 512 * 1024;
const MAX_RETAINED_EXPORTS = 10;
/** Newest Gateway debug records appended to an export, bounded separately
 * from the client's own content. */
const MAX_DEBUG_SECTION_BYTES = 1_024 * 1_024;
const diagnosticExportMutex = new AsyncMutex();

/** Writes an explicitly requested, bounded diagnostic snapshot outside the
 * canonical data directory. The path is server-owned and never client input. */
export function exportDiagnosticSnapshot(
  content: string,
  debugRecords: readonly LogRecord[],
  now: Date,
  directory: string,
  deviceIdentity: string,
): Promise<{ path: string; exportedAt: string }> {
  return diagnosticExportMutex.run(() => exportDiagnosticSnapshotImpl(content, debugRecords, now, directory, deviceIdentity));
}

/** The Gateway's debug buffer never reaches its persisted log; exports are
 * the one place it is kept. Newest records win when the section is full. */
function debugSection(records: readonly LogRecord[]): string {
  if (records.length === 0) return "";
  const lines: string[] = [];
  let bytes = 0;
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const line = JSON.stringify(records[index]);
    const lineBytes = Buffer.byteLength(line) + 1;
    if (bytes + lineBytes > MAX_DEBUG_SECTION_BYTES) break;
    lines.push(line);
    bytes += lineBytes;
  }
  lines.reverse();
  return `${lines.length === 0 ? "" : "\n"}${lines.join("\n")}\n`;
}

async function exportDiagnosticSnapshotImpl(
  content: string,
  debugRecords: readonly LogRecord[],
  now: Date,
  directory: string,
  deviceIdentity: string,
): Promise<{ path: string; exportedAt: string }> {
  if (Buffer.byteLength(content, "utf8") > MAX_EXPORT_BYTES) {
    throw new GatewayError("invalid_request", "Diagnostic snapshot exceeds the size limit");
  }
  let directoryStat: Stats;
  try {
    directoryStat = await lstat(directory);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    directoryStat = await lstat(directory);
  }
  const ownerUID = process.getuid?.();
  if (!directoryStat.isDirectory()
    || directoryStat.isSymbolicLink()
    || (directoryStat.mode & 0o077) !== 0
    || ownerUID === undefined
    || directoryStat.uid !== ownerUID) {
    throw new GatewayError("conflict", "Diagnostic export storage is not private", true);
  }
  await chmod(directory, 0o700);
  const deviceHash = createHash("sha256").update(deviceIdentity).digest("hex").slice(0, 32);
  const timestamp = now.toISOString().replace(/[:.]/g, "-");
  const path = join(directory, `${deviceHash}-${timestamp}.jsonl`);
  try {
    await writeFile(path, content + debugSection(debugRecords), { encoding: "utf8", flag: "wx", mode: 0o600 });
    await chmod(path, 0o600);
    await pruneDiagnosticSnapshots(path, directory);
    return { path, exportedAt: now.toISOString() };
  } catch {
    // Never unlink a replacement symlink or a file not owned by this process
    // if exclusive creation or pruning races with another actor.
    try {
      const candidate = await lstat(path);
      if (candidate.isFile() && !candidate.isSymbolicLink()
        && (ownerUID === undefined || candidate.uid === ownerUID)) {
        await rm(path, { force: true });
      }
    } catch { /* the failed write may not have created a candidate */ }
    throw new GatewayError("conflict", "Diagnostic snapshot could not be written", true);
  }
}

async function pruneDiagnosticSnapshots(newPath: string, directory: string): Promise<void> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries
    .filter((entry) => entry.isFile() && /^[a-f0-9]{32}-.*\.jsonl$/.test(entry.name))
    .map(async (entry) => {
      const path = join(directory, entry.name);
      try { return { path, mtime: (await stat(path)).mtimeMs }; }
      catch { return undefined; }
    }));
  const stale = files.filter((file): file is { path: string; mtime: number } => file !== undefined)
    .sort((a, b) => b.mtime - a.mtime || b.path.localeCompare(a.path))
    .slice(MAX_RETAINED_EXPORTS);
  await Promise.all(stale.filter((file) => file.path !== newPath).map((file) => rm(file.path, { force: true })));
}
