import { chmod, lstat, mkdir, readdir, rm, stat, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";

const DIAGNOSTIC_DIRECTORY = "/tmp/tron-diagnostics";
const MAX_EXPORT_BYTES = 512 * 1024;
const MAX_RETAINED_EXPORTS = 10;
const diagnosticExportMutex = new AsyncMutex();

/** Writes an explicitly requested, bounded diagnostic snapshot outside the
 * canonical data directory. The path is server-owned and never client input. */
export function exportDiagnosticSnapshot(
  content: string,
  now = new Date(),
  directory = DIAGNOSTIC_DIRECTORY,
): Promise<{ path: string; exportedAt: string }> {
  return diagnosticExportMutex.run(() => exportDiagnosticSnapshotImpl(content, now, directory));
}

async function exportDiagnosticSnapshotImpl(
  content: string,
  now: Date,
  directory: string,
): Promise<{ path: string; exportedAt: string }> {
  if (Buffer.byteLength(content, "utf8") > MAX_EXPORT_BYTES) {
    throw new GatewayError("invalid_request", "Diagnostic snapshot exceeds the size limit");
  }
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const directoryStat = await lstat(directory);
  const ownerUID = process.getuid?.();
  if (!directoryStat.isDirectory()
    || directoryStat.isSymbolicLink()
    || (directoryStat.mode & 0o077) !== 0
    || ownerUID === undefined
    || directoryStat.uid !== ownerUID) {
    throw new GatewayError("conflict", "Diagnostic export storage is not private", true);
  }
  await chmod(directory, 0o700);
  const path = `${directory}/logs-${now.getTime()}-${randomUUID()}.txt`;
  try {
    await writeFile(path, content, { encoding: "utf8", flag: "wx", mode: 0o600 });
    await chmod(path, 0o600);
    await pruneDiagnosticSnapshots(path, directory);
    return { path, exportedAt: now.toISOString() };
  } catch {
    await rm(path, { force: true }).catch(() => {});
    throw new GatewayError("conflict", "Diagnostic snapshot could not be written", true);
  }
}

async function pruneDiagnosticSnapshots(newPath: string, directory: string): Promise<void> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries
    .filter((entry) => entry.isFile() && entry.name.startsWith("logs-") && entry.name.endsWith(".txt"))
    .map(async (entry) => {
      const path = `${directory}/${entry.name}`;
      try { return { path, mtime: (await stat(path)).mtimeMs }; }
      catch { return undefined; }
    }));
  const stale = files.filter((file): file is { path: string; mtime: number } => file !== undefined)
    .sort((a, b) => b.mtime - a.mtime || b.path.localeCompare(a.path))
    .slice(MAX_RETAINED_EXPORTS);
  await Promise.all(stale.filter((file) => file.path !== newPath).map((file) => rm(file.path, { force: true })));
}

export const diagnosticExportPolicy = {
  directory: DIAGNOSTIC_DIRECTORY,
  maxBytes: MAX_EXPORT_BYTES,
  maxRetained: MAX_RETAINED_EXPORTS,
};
