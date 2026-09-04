import { spawn } from "node:child_process";
import { createWriteStream, lstatSync, readFileSync, realpathSync } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import { open, rm, stat, statfs } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { GatewayError } from "../errors.js";

export const SESSION_EXPORT_MAX_ITEM_BYTES = 2 * 1_024 * 1_024 * 1_024;
export const SESSION_EXPORT_MAX_ITEMS = 8;
export const SESSION_EXPORT_MAX_TOTAL_BYTES = 4 * 1_024 * 1_024 * 1_024;
export const SESSION_EXPORT_MAX_READERS = 4;
// A generation may temporarily own a snapshot, rendered output, and store
// staging copy. Serialize generation so independent capacity probes cannot
// overcommit physical disk while completed artifacts remain concurrently readable.
export const SESSION_EXPORT_MAX_PRODUCTIONS = 1;

const COPY_BUFFER_BYTES = 1 * 1_024 * 1_024;
const HTML_EXPORT_TIMEOUT_MS = 15 * 60_000;
const MAXIMUM_EXPORT_ERROR_BYTES = 8 * 1_024;
const PACKAGE_JSON_MAX_BYTES = 64 * 1024;
export const SESSION_EXPORT_MINIMUM_FREE_BYTES = 64 * 1_024 * 1_024;
const PROJECTION_DISK_RESERVATION_BYTES = 64 * 1_024 * 1_024;

export interface CanonicalSessionFileCut {
  handle: FileHandle;
  size: number;
}

export async function requireSessionExportDiskCapacity(
  path: string,
  additionalBytes: number,
): Promise<void> {
  if (!Number.isSafeInteger(additionalBytes) || additionalBytes < 0) {
    throw new GatewayError("internal", "Session export requested an invalid disk reservation");
  }
  const filesystem = await statfs(path);
  const available = filesystem.bavail * filesystem.bsize;
  if (!Number.isSafeInteger(available)
    || available < additionalBytes + SESSION_EXPORT_MINIMUM_FREE_BYTES) {
    throw new GatewayError("busy", "The Mac does not have enough free space to prepare this session export", true);
  }
}

/** Copy one immutable byte cut from an already-open canonical descriptor. */
export async function copyCanonicalSessionCut(
  cut: CanonicalSessionFileCut,
  destination: string,
): Promise<void> {
  const output = await open(destination, "wx", 0o600);
  const buffer = Buffer.allocUnsafe(COPY_BUFFER_BYTES);
  let offset = 0;
  try {
    while (offset < cut.size) {
      const length = Math.min(buffer.length, cut.size - offset);
      const { bytesRead } = await cut.handle.read(buffer, 0, length, offset);
      if (bytesRead <= 0) {
        throw new GatewayError("conflict", "Canonical session changed while its export snapshot was being captured", true);
      }
      let written = 0;
      while (written < bytesRead) {
        const result = await output.write(buffer, written, bytesRead - written, offset + written);
        if (result.bytesWritten <= 0) throw new GatewayError("internal", "Session export snapshot could not be written");
        written += result.bytesWritten;
      }
      offset += bytesRead;
    }
    await output.sync();
  } finally {
    await output.close();
  }
  const copied = await stat(destination);
  if (!copied.isFile() || copied.size !== cut.size) {
    throw new GatewayError("conflict", "Session export snapshot did not match its captured canonical size", true);
  }
}

/**
 * Serialize a captured public SessionManager projection one entry at a time.
 * This covers first-turn JSONL before Pi creates its file and preserves the
 * exact selected branch for standalone HTML rendering.
 */
export async function writeSessionProjectionCut(
  snapshot: { header: unknown; entries: readonly unknown[] },
  destination: string,
): Promise<number> {
  if (!snapshot.header) throw new GatewayError("conflict", "Session has no canonical header to export");
  const { header, entries } = snapshot;
  const output = await open(destination, "wx", 0o600);
  let offset = 0;
  let reservedWritableBytes = 0;
  try {
    for (let index = -1; index < entries.length; index += 1) {
      const entry = index < 0 ? header : entries[index];
      const line = Buffer.from(`${JSON.stringify(entry)}\n`, "utf8");
      if (line.length > SESSION_EXPORT_MAX_ITEM_BYTES - offset) {
        throw new GatewayError("conflict", "Session export exceeds the 2 GiB export limit");
      }
      if (line.length > reservedWritableBytes) {
        reservedWritableBytes = Math.max(PROJECTION_DISK_RESERVATION_BYTES, line.length);
        await requireSessionExportDiskCapacity(dirname(destination), reservedWritableBytes);
      }
      let written = 0;
      while (written < line.length) {
        const result = await output.write(line, written, line.length - written, offset + written);
        if (result.bytesWritten <= 0) throw new GatewayError("internal", "Session export snapshot could not be written");
        written += result.bytesWritten;
      }
      offset += line.length;
      reservedWritableBytes -= line.length;
    }
    await output.sync();
  } finally {
    await output.close();
  }
  return offset;
}

/**
 * Use Pi's documented standalone `--export` command against the immutable cut.
 * Running it out of process prevents the SDK's current whole-document HTML
 * renderer from blocking the Gateway event loop or retaining its temporary
 * strings in the live runtime heap.
 */
export function validatePiCliPackageRoot(packageRoot: string, nodeModulesRoot: string): string {
  const nodeModulesReal = realpathSync(nodeModulesRoot);
  const expected = join(nodeModulesReal, "@earendil-works", "pi-coding-agent");
  const expectedInfo = lstatSync(expected);
  if (!expectedInfo.isDirectory() || expectedInfo.isSymbolicLink()) {
    throw new Error("pi-coding-agent package root is substituted");
  }
  const expectedReal = realpathSync(expected);
  const packageReal = realpathSync(packageRoot);
  const fromNodeModules = relative(nodeModulesReal, packageReal);
  if (packageReal !== expectedReal || fromNodeModules.startsWith("..") || isAbsolute(fromNodeModules)) {
    throw new Error("pi-coding-agent package root is outside the Gateway node_modules");
  }
  return packageReal;
}

export function resolvePiCliExecutable(): string {
  const packageEntry = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"));
  const nodeModulesRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..", "node_modules");
  let packageRoot = dirname(packageEntry);
  for (;;) {
    const packageJsonPath = join(packageRoot, "package.json");
    try {
      const packageJsonInfo = lstatSync(packageJsonPath);
      if (!packageJsonInfo.isFile() || packageJsonInfo.isSymbolicLink() || packageJsonInfo.size > PACKAGE_JSON_MAX_BYTES) {
        throw new Error("package.json is missing, substituted, or oversized");
      }
      const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8")) as { name?: unknown; bin?: unknown };
      if (packageJson.name === "@earendil-works/pi-coding-agent") {
        const bin = typeof packageJson.bin === "object" && packageJson.bin !== null
          ? (packageJson.bin as { pi?: unknown }).pi : undefined;
        if (typeof bin !== "string" || !bin || isAbsolute(bin) || bin.split(/[\\/]/u).includes("..")) {
          throw new Error("declared bin.pi is unsafe or missing");
        }
        const executable = resolve(packageRoot, bin);
        const packageReal = validatePiCliPackageRoot(packageRoot, nodeModulesRoot);
        const executableReal = realpathSync(executable);
        const info = lstatSync(executable);
        if (!executableReal.startsWith(`${packageReal}/`) || !info.isFile() || info.isSymbolicLink()) {
          throw new Error("declared bin.pi is not an executable regular file inside its package");
        }
        if ((info.mode & 0o111) === 0) throw new Error("declared bin.pi is not executable");
        return executable;
      }
    } catch (error) {
      if (error instanceof Error && /declared bin\.pi|not an executable|not executable|package root/u.test(error.message)) throw error;
    }
    const parent = dirname(packageRoot);
    if (parent === packageRoot) break;
    packageRoot = parent;
  }
  throw new Error("could not locate pi-coding-agent package metadata");
}

export async function renderSessionCutToHtml(snapshot: string, output: string): Promise<number> {
  const cli = resolvePiCliExecutable();
  let errorOutput = Buffer.alloc(0);
  let outputBytes = 0;
  let reservedWritableBytes = 0;
  let timedOut = false;
  const child = spawn(process.execPath, [cli, "--export", snapshot, "/dev/fd/3"], {
    cwd: dirname(snapshot),
    stdio: ["ignore", "ignore", "pipe", "pipe"],
  });
  const renderedOutput = child.stdio[3];
  if (!(renderedOutput instanceof Readable)) {
    child.kill("SIGKILL");
    throw new GatewayError("internal", "HTML export renderer did not provide a bounded output stream");
  }
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill("SIGKILL");
  }, HTML_EXPORT_TIMEOUT_MS);
  timer.unref();
  child.stderr?.on("data", (chunk: Buffer) => {
    if (errorOutput.length >= MAXIMUM_EXPORT_ERROR_BYTES) return;
    errorOutput = Buffer.concat([
      errorOutput,
      chunk.subarray(0, MAXIMUM_EXPORT_ERROR_BYTES - errorOutput.length),
    ]);
  });
  const completion = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  const limiter = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      if (chunk.length > SESSION_EXPORT_MAX_ITEM_BYTES - outputBytes) {
        callback(new GatewayError("conflict", "Session export exceeds the 2 GiB export limit"));
        return;
      }
      const admit = async () => {
        if (chunk.length > reservedWritableBytes) {
          reservedWritableBytes = Math.max(PROJECTION_DISK_RESERVATION_BYTES, chunk.length);
          await requireSessionExportDiskCapacity(dirname(output), reservedWritableBytes);
        }
        outputBytes += chunk.length;
        reservedWritableBytes -= chunk.length;
      };
      void admit().then(
        () => callback(null, chunk),
        (error: unknown) => callback(error instanceof Error ? error : new Error(String(error))),
      );
    },
  });

  try {
    const transfer = pipeline(
      renderedOutput,
      limiter,
      createWriteStream(output, { flags: "wx", mode: 0o600 }),
    );
    let result: { code: number | null; signal: NodeJS.Signals | null };
    try {
      [result] = await Promise.all([completion, transfer]);
    } catch (error) {
      child.kill("SIGKILL");
      await completion.catch(() => {});
      throw error;
    }
    if (timedOut) {
      throw new GatewayError("busy", "HTML export generation exceeded its bounded time limit", true);
    }
    if (result.code !== 0) {
      throw new GatewayError(
        "internal",
        `HTML export generation failed${result.signal ? ` (${result.signal})` : ""}${errorOutput.length > 0 ? `: ${errorOutput.toString("utf8").trim()}` : ""}`,
      );
    }
    const metadata = await stat(output);
    if (!metadata.isFile() || metadata.size !== outputBytes) {
      throw new GatewayError("conflict", "Session export output did not match its bounded stream");
    }
    return metadata.size;
  } catch (error) {
    await rm(output, { force: true }).catch(() => {});
    throw error;
  } finally {
    clearTimeout(timer);
  }
}
