import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, open, opendir, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { createInterface } from "node:readline";
import { GatewayError } from "../errors.js";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { SessionCreationOrigin } from "../protocol/types.js";
import { INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "./invocation-receipts.js";
import { isAutomationId, runIdFromAutomationOperationId } from "../automations/automation-contract.js";
import { applyCatalogMetadataEntry, type CatalogMetadataAccumulator } from "./catalog-metadata-index.js";

function isMissingFilesystemError(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}
export const DEFAULT_CATALOG_DISCOVERY_LIMITS = {
  maximumDirectories: 25_001,
  maximumEntries: 50_001,
  maximumTraversalBytes: 8 * 1_024 * 1_024,
  maximumSessions: 25_000,
  maximumRetainedBytes: 8 * 1_024 * 1_024,
  maximumAcquisitionBytes: 4 * 1_024 * 1_024,
  maximumHeaderBytes: 64 * 1_024 * 1_024,
  maximumHeaderBytesPerFile: 64 * 1_024,
  // Ten concurrent streams cap descriptor pressure while keeping metadata I/O independent of folder concurrency.
  metadataReadConcurrency: 10,
  // Match the existing bounded normalization width for folder visits.
  normalizationConcurrency: 16,
};

/** At most one folder batch runs at a time, and a failing visit prevents new
 * assignments while already-admitted filesystem work settles. */
export async function visitConcurrently<T>(
  values: readonly T[],
  concurrency: number,
  visit: (value: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  let failed = false;
  const failures: unknown[] = [];
  const worker = async (): Promise<void> => {
    while (!failed) {
      const index = next++;
      if (index >= values.length) return;
      try { await visit(values[index]!); }
      catch (error) { failed = true; failures.push(error); }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, worker));
  if (failures.length > 0) {
    throw failures.find((error) => error instanceof GatewayError) ?? failures[0];
  }
}

/** Stable hash and materialization order despite concurrent filesystem visits. */
export function sortCatalogPaths(paths: Iterable<string>): string[] {
  return [...paths].sort();
}

/** pi-subagents reserves only the immediate workspace diagnostics directory;
 * deeper project directories with the same basename remain canonical. */
export function isIgnoredCatalogDirectory(directory: string, canonicalRoot: string): boolean {
  const fromRoot = relative(canonicalRoot, resolve(directory));
  if (fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) return true;
  const parts = fromRoot.split(sep);
  return parts.length === 2 && parts[1] === "subagent-artifacts";
}
type SessionInfo = Awaited<ReturnType<typeof SessionManager.listAll>>[number];
export type CatalogSessionInfo = Omit<SessionInfo, "allMessagesText"> & {
  fileIdentity?: string;
  creationOrigin?: SessionCreationOrigin;
};

/** SDK-compatible row metadata without constructing its unused transcript-wide
 * `allMessagesText` accumulator. The complete JSONL remains authoritative for
 * RuntimeSlot.open; this pass is only catalog discovery metadata. */
export async function buildCatalogSessionInfo(filePath: string): Promise<CatalogSessionInfo | null> {
  try {
    const physical = await lstat(filePath);
    if (!physical.isFile() || physical.isSymbolicLink()) return null;
    const stats = await stat(filePath);
    let header: Record<string, unknown> | undefined;
    const metadata: CatalogMetadataAccumulator = {
      messageCount: 0,
      firstMessage: "(no messages)",
      name: undefined,
      updatedAt: "",
    };
    const automationStarts = new Map<string, { automationId: string; sessionId: string }>();
    let sawPrePromptMessage = false;
    let firstUserEntryId: string | undefined;
    let automationCreation: { automationId: string; sessionId: string } | undefined;
    const lines = createInterface({
      input: createReadStream(filePath, { encoding: "utf8" }),
      crlfDelay: Infinity,
    });
    for await (const line of lines) {
      let value: unknown;
      try { value = JSON.parse(line); } catch { continue; }
      if (!value || typeof value !== "object" || Array.isArray(value)) continue;
      const entry = value as Record<string, unknown>;
      if (!header) {
        if (entry.type !== "session") return null;
        header = entry;
        continue;
      }
      if (firstUserEntryId === undefined && entry.type === "message") {
        if (typeof entry.id === "string"
          && entry.message && typeof entry.message === "object" && !Array.isArray(entry.message)
          && (entry.message as Record<string, unknown>).role === "user") {
          firstUserEntryId = entry.id;
        } else {
          // A generated Automation session begins with its invocation receipts
          // and canonical user prompt. Any earlier message proves another owner.
          sawPrePromptMessage = true;
          automationStarts.clear();
        }
      }
      if (entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE) {
        const receipt = parseInvocationReceipt(entry.data);
        if (receipt?.receiptKind === "start" && firstUserEntryId === undefined
          && !sawPrePromptMessage && automationStarts.size < 128
          && receipt.source !== "extension"
          && receipt.origin.kind === "gateway" && receipt.origin.confidence === "boundary"
          && isAutomationId(receipt.origin.ownerId)
          && runIdFromAutomationOperationId(receipt.operationId) !== undefined) {
          automationStarts.set(receipt.invocationId, {
            automationId: receipt.origin.ownerId,
            sessionId: receipt.sessionId,
          });
        } else if (receipt?.receiptKind === "binding"
          && receipt.canonicalEntryId === firstUserEntryId) {
          automationCreation = automationStarts.get(receipt.invocationId);
        }
      }
      applyCatalogMetadataEntry(metadata, entry);
    }
    if (!header || typeof header.id !== "string") return null;
    const cwd = typeof header.cwd === "string" ? header.cwd : "";
    const headerTime = typeof header.timestamp === "string" ? Date.parse(header.timestamp) : NaN;
    const modified = metadata.updatedAt ? new Date(metadata.updatedAt)
      : Number.isFinite(headerTime) ? new Date(headerTime) : stats.mtime;
    return {
      path: filePath,
      id: header.id,
      cwd,
      ...(metadata.name ? { name: metadata.name } : {}),
      ...(typeof header.parentSession === "string" ? { parentSessionPath: header.parentSession } : {}),
      ...(automationCreation?.sessionId === header.id && typeof header.parentSession !== "string"
        ? { creationOrigin: { kind: "automation", automationId: automationCreation.automationId } as const }
        : {}),
      created: new Date(typeof header.timestamp === "string" ? header.timestamp : stats.birthtime),
      modified,
      messageCount: metadata.messageCount,
      firstMessage: metadata.firstMessage,
    };
  } catch {
    return null;
  }
}

export async function buildCatalogSessionInfos(
  files: readonly string[],
  concurrency = DEFAULT_CATALOG_DISCOVERY_LIMITS.metadataReadConcurrency,
): Promise<CatalogSessionInfo[]> {
  const results: Array<CatalogSessionInfo | null> = new Array(files.length).fill(null);
  let next = 0;
  const worker = async (): Promise<void> => {
    while (true) {
      const index = next++;
      if (index >= files.length) return;
      results[index] = await buildCatalogSessionInfo(files[index]!);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, files.length) }, worker));
  return results.filter((info): info is CatalogSessionInfo => info !== null);
}

export interface CatalogHeaderIdentity {
  id: string;
  cwd: string;
  fileIdentity: string;
  size: number;
  mtimeMs: number;
  parentSessionPath?: string;
}

export interface DelegatedSessionTopology {
  parentSessionId?: string;
  contradictoryHeader: boolean;
}

export interface CatalogStructureEvidence {
  digest: string;
  factsDigest: string;
  identitiesByPath: ReadonlyMap<string, CatalogHeaderIdentity>;
  complete: boolean;
  unstableCanonicalFiles: boolean;
  unstableCanonicalPaths?: ReadonlySet<string>;
}

export interface CatalogDiscoveryOptions {
  limits: typeof DEFAULT_CATALOG_DISCOVERY_LIMITS;
  catalogDirectory: () => string;
  catalogCapacityExceeded: () => never;
  isLiveRuntimeOwnedPath: (path: string, sessionID: string) => boolean;
  canonicalSessionPath: (path: string) => Promise<string>;
  delegatedTopologyParentPath: (sessionPath: string, catalogRoot: string) => string | undefined;
  openDirectory?: (directory: string) => Promise<AsyncIterable<import("node:fs").Dirent>>;
}

export class CatalogDiscovery {
  constructor(private readonly options: CatalogDiscoveryOptions) {}

  private openDirectory(directory: string): Promise<AsyncIterable<import("node:fs").Dirent>> {
    return this.options.openDirectory?.(directory) ?? opendir(directory);
  }

  async catalogStructureEvidence(): Promise<CatalogStructureEvidence> {
    const limits = this.options.limits;
    const catalogRoot = await realpath(resolve(this.options.catalogDirectory())).catch(() => resolve(this.options.catalogDirectory()));
    const pending = [catalogRoot];
    const seenDirectories = new Set<string>();
    const candidatePaths = new Set<string>();
    let entriesExamined = 0;
    let traversalBytes = Buffer.byteLength(pending[0]!);
    let complete = true;
    let unstableCanonicalFiles = false;
    const unstableCanonicalPaths = new Set<string>();
    let frontier = pending;
    while (frontier.length > 0) {
      const nextFrontier: string[] = [];
      try {
        await visitConcurrently(frontier, limits.normalizationConcurrency, async (candidate) => {
          let directory: string;
          try { directory = await realpath(candidate); }
          catch (error) {
            if (isMissingFilesystemError(error)) return;
            throw error;
          }
          if (isIgnoredCatalogDirectory(directory, catalogRoot)) return;
          if (!seenDirectories.add(directory)) return;
          traversalBytes += Buffer.byteLength(directory);
          if (seenDirectories.size > limits.maximumDirectories
            || traversalBytes > limits.maximumTraversalBytes) this.options.catalogCapacityExceeded();
          const entries = await this.openDirectory(directory);
          for await (const entry of entries) {
            entriesExamined += 1;
            if (entriesExamined > limits.maximumEntries) this.options.catalogCapacityExceeded();
            const child = join(directory, entry.name);
            if (entry.isDirectory()) {
              if (isIgnoredCatalogDirectory(child, catalogRoot)) continue;
              traversalBytes += Buffer.byteLength(child);
              if (traversalBytes > limits.maximumTraversalBytes) this.options.catalogCapacityExceeded();
              nextFrontier.push(child);
              continue;
            }
            if (!entry.name.endsWith(".jsonl") || (!entry.isFile() && !entry.isSymbolicLink())) continue;
            // Symlinked JSONL is never canonical authority. A regular file in a
            // canonical folder is canonical; the header read fences its inode.
            if (entry.isSymbolicLink()) continue;
            const fromRoot = relative(catalogRoot, child);
            if (fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) continue;
            traversalBytes += Buffer.byteLength(child);
            if (traversalBytes > limits.maximumTraversalBytes) this.options.catalogCapacityExceeded();
            candidatePaths.add(child);
            if (candidatePaths.size > limits.maximumSessions) this.options.catalogCapacityExceeded();
          }
        });
      } catch (error) {
        if (error instanceof GatewayError) throw error;
        complete = false;
        break;
      }
      frontier = nextFrontier;
    }

    const paths = sortCatalogPaths(candidatePaths);
    let remainingHeaderBytes = limits.maximumHeaderBytes;
    const perCandidateHeaderBytes = Math.min(
      limits.maximumHeaderBytesPerFile,
      Math.floor(limits.maximumHeaderBytes / Math.max(1, paths.length)),
    );
    let retainedIdentityBytes = 0;
    const reserveHeaderBytes = (count: number): boolean => {
      if (count > remainingHeaderBytes) return false;
      remainingHeaderBytes -= count;
      return true;
    };
    const refundHeaderBytes = (count: number): void => { remainingHeaderBytes += count; };
    const digest = createHash("sha256");
    const factsDigest = createHash("sha256");
    const identitiesByPath = new Map<string, CatalogHeaderIdentity>();
    digest.update(`count:${paths.length}\n`);
    factsDigest.update(`count:${paths.length}\n`);
    let headerFailure = false;
    for (let start = 0; start < paths.length && !headerFailure; start += limits.normalizationConcurrency) {
      const batchPaths = paths.slice(start, start + limits.normalizationConcurrency);
      const identities = await Promise.all(batchPaths.map(async (path) => {
        try {
          const header = await this.readCatalogHeader(
            path,
            perCandidateHeaderBytes,
            reserveHeaderBytes,
            refundHeaderBytes,
            true,
          );
          if (header.unstable) {
            unstableCanonicalFiles = true;
            unstableCanonicalPaths.add(path);
          }
          const identity = header.identity;
          if (!identity) return undefined;
          return identity.parentSessionPath
            ? { ...identity, parentSessionPath: await this.options.canonicalSessionPath(identity.parentSessionPath) }
            : identity;
        } catch {
          headerFailure = true;
          return undefined;
        }
      }));
      for (let index = 0; index < batchPaths.length; index += 1) {
        const path = batchPaths[index]!;
        let identity = identities[index];
        if (identity) {
          const identityBytes = Buffer.byteLength(JSON.stringify({ path, ...identity }));
          if (retainedIdentityBytes + identityBytes > limits.maximumAcquisitionBytes) identity = undefined;
          else retainedIdentityBytes += identityBytes;
        }
        if (!identity) complete = false;
        digest.update(path).update("\0")
          .update(identity?.id ?? "").update("\0")
          .update(identity?.cwd ?? "").update("\0")
          .update(identity?.fileIdentity ?? "").update("\0")
          .update(identity?.parentSessionPath ?? "").update("\n");
        const liveOwner = identity !== undefined && this.options.isLiveRuntimeOwnedPath(path, identity.id);
        factsDigest.update(path).update("\0")
          .update(identity?.id ?? "").update("\0")
          .update(identity?.cwd ?? "").update("\0")
          .update(identity?.fileIdentity ?? "").update("\0")
          // A Gateway-owned JSONL may grow while its header is being read. Its
          // inode and identity remain structural authority; cold/unowned files
          // retain size/mtime validation so external rewrites cannot slip by.
          .update(identity ? (liveOwner ? "live-append" : String(identity.size)) : "").update("\0")
          .update(identity ? (liveOwner ? "live-append" : String(identity.mtimeMs)) : "").update("\n");
        if (identity) identitiesByPath.set(path, identity);
      }
    }
    return {
      digest: digest.digest("base64url"),
      factsDigest: factsDigest.digest("base64url"),
      identitiesByPath,
      complete,
      unstableCanonicalFiles,
      unstableCanonicalPaths,
    };
  }

  async readCatalogHeader(
    path: string,
    maximumBytes: number,
    reserveBytes: (count: number) => boolean,
    refundBytes: (count: number) => void,
    allowAppendOnlyLiveOwner = false,
  ): Promise<{ identity?: CatalogHeaderIdentity; unstable?: boolean }> {
    const firstReadLength = Math.min(512, maximumBytes);
    if (!reserveBytes(firstReadLength)) return {};
    let handle: Awaited<ReturnType<typeof open>>;
    try { handle = await open(path, "r"); }
    catch (error) {
      refundBytes(firstReadLength);
      throw error;
    }
    let opened: Awaited<ReturnType<typeof handle.stat>>;
    try { opened = await handle.stat(); }
    catch (error) {
      refundBytes(firstReadLength);
      await handle.close().catch(() => {});
      throw error;
    }
    if (!opened.isFile()) {
      refundBytes(firstReadLength);
      await handle.close();
      return {};
    }
    const fileIdentity = `${opened.dev}:${opened.ino}`;
    if (opened.size === 0) {
      refundBytes(firstReadLength);
      await handle.close();
      return {};
    }
    try {
      const finalByte = Buffer.alloc(1);
      const finalRead = await handle.read(finalByte, 0, 1, opened.size - 1);
      // A stable header remains identity evidence while this file has a partial
      // tail. Transcript/catalog readers separately enforce their selected scope.
      const incompleteTail = finalRead.bytesRead !== 1 || finalByte[0] !== 0x0a;
      const buffer = Buffer.allocUnsafe(maximumBytes);
      const parseHeader = (line: Buffer): CatalogHeaderIdentity | undefined => {
        if (line.length === 0 || !line.toString("utf8").trim()) return undefined;
        let value: unknown;
        try { value = JSON.parse(line.toString("utf8")); }
        catch { return undefined; }
        if (!value || typeof value !== "object") return undefined;
        const record = value as Record<string, unknown>;
        if (record.type !== "session" || typeof record.id !== "string") return undefined;
        return {
          id: record.id,
          cwd: typeof record.cwd === "string" ? record.cwd : "",
          fileIdentity,
          size: opened.size,
          mtimeMs: opened.mtimeMs,
          ...(typeof record.parentSession === "string"
            ? { parentSessionPath: record.parentSession }
            : {}),
        };
      };
      const stableIdentity = async (identity: CatalogHeaderIdentity | undefined): Promise<CatalogHeaderIdentity | undefined> => {
        if (!identity) return undefined;
        const after = await handle.stat();
        const afterPath = await lstat(path);
        const sameFile = after.isFile() && after.dev === opened.dev && after.ino === opened.ino
          && afterPath.isFile() && !afterPath.isSymbolicLink()
          && afterPath.dev === opened.dev && afterPath.ino === opened.ino;
        const unchanged = after.size === opened.size && after.mtimeMs === opened.mtimeMs
          && afterPath.size === opened.size && afterPath.mtimeMs === opened.mtimeMs;
        const appendOnly = allowAppendOnlyLiveOwner
          && this.options.isLiveRuntimeOwnedPath(path, identity.id)
          && (after.size > opened.size || afterPath.size > opened.size);
        if (!sameFile || (!unchanged && !appendOnly)) return undefined;
        return identity;
      };
      let bytesReadTotal = 0;
      let lineStart = 0;
      while (bytesReadTotal < maximumBytes) {
        const readLength = Math.min(512, maximumBytes - bytesReadTotal);
        if (bytesReadTotal > 0 && !reserveBytes(readLength)) return {};
        let bytesRead: number;
        try {
          ({ bytesRead } = await handle.read(buffer, bytesReadTotal, readLength, bytesReadTotal));
        } catch (error) {
          refundBytes(readLength);
          throw error;
        }
        refundBytes(readLength - bytesRead);
        if (bytesRead === 0) {
          if (lineStart >= bytesReadTotal) return {};
          const identity = parseHeader(buffer.subarray(lineStart, bytesReadTotal));
          const stable = await stableIdentity(identity);
          return stable ? { identity: stable, ...(incompleteTail ? { unstable: true } : {}) } : {};
        }
        bytesReadTotal += bytesRead;
        const newline = buffer.indexOf(0x0a, lineStart);
        if (newline >= 0 && newline < bytesReadTotal) {
          const identity = parseHeader(buffer.subarray(lineStart, newline));
          const stable = await stableIdentity(identity);
          return stable ? { identity: stable, ...(incompleteTail ? { unstable: true } : {}) } : {};
        }
      }
      return {};
    } finally {
      await handle.close();
    }
  }

  async sessionInfos(scope: "user" | "all" = "all") {
    const limits = this.options.limits;
    const catalogRoot = await realpath(resolve(this.options.catalogDirectory())).catch(() => resolve(this.options.catalogDirectory()));
    let frontier = [catalogRoot];
    const seen = new Set<string>();
    const files: string[] = [];
    let entriesExamined = 0;
    let traversalBytes = Buffer.byteLength(catalogRoot);
    while (frontier.length > 0) {
      const nextFrontier: string[] = [];
      await visitConcurrently(frontier, limits.normalizationConcurrency, async (candidate) => {
        let directory: string;
        try { directory = await realpath(candidate); }
        catch (error) {
          if (isMissingFilesystemError(error)) return;
          throw new GatewayError("busy", "Session catalog directory could not be validated", true);
        }
        if (isIgnoredCatalogDirectory(directory, catalogRoot) || !seen.add(directory)) return;
        traversalBytes += Buffer.byteLength(directory);
        if (seen.size > limits.maximumDirectories
          || traversalBytes > limits.maximumTraversalBytes) this.options.catalogCapacityExceeded();
        try {
          const entries = await this.openDirectory(directory);
          for await (const entry of entries) {
            entriesExamined += 1;
            if (entriesExamined > limits.maximumEntries) this.options.catalogCapacityExceeded();
            const child = join(directory, entry.name);
            if (entry.isDirectory()) {
              if (isIgnoredCatalogDirectory(child, catalogRoot)) continue;
              traversalBytes += Buffer.byteLength(child);
              if (traversalBytes > limits.maximumTraversalBytes) this.options.catalogCapacityExceeded();
              nextFrontier.push(child);
            } else if (entry.name.endsWith(".jsonl") && entry.isFile()) files.push(child);
          }
        } catch (error) {
          if (error instanceof GatewayError) throw error;
          if (!isMissingFilesystemError(error)) {
            throw new GatewayError("busy", "Session catalog directory could not be enumerated", true);
          }
        }
      });
      frontier = nextFrontier;
    }

    // Header-based delegated classification excludes child files from user rows;
    // full metadata reads remain globally bounded to ten concurrent files.
    const metadataFiles = scope === "user"
      ? files.filter((file) => this.options.delegatedTopologyParentPath(file, catalogRoot) === undefined)
      : files;
    const sessions = await buildCatalogSessionInfos(metadataFiles, limits.metadataReadConcurrency);
    if (sessions.length > limits.maximumSessions) this.options.catalogCapacityExceeded();
    let retainedBytes = 0;
    for (const session of sessions) {
      retainedBytes += Buffer.byteLength(JSON.stringify(session));
      if (retainedBytes > limits.maximumRetainedBytes) this.options.catalogCapacityExceeded();
    }

    const normalized = new Array<CatalogSessionInfo>(sessions.length);
    let nextIndex = 0;
    const normalize = async () => {
      while (true) {
        const index = nextIndex;
        nextIndex += 1;
        const session = sessions[index];
        if (!session) return;
        const path = await this.options.canonicalSessionPath(session.path);
        normalized[index] = {
          ...session,
          path,
          ...(session.parentSessionPath
            ? { parentSessionPath: await this.options.canonicalSessionPath(session.parentSessionPath) }
            : {}),
        };
      }
    };
    await Promise.all(Array.from(
      { length: Math.min(limits.normalizationConcurrency, sessions.length) },
      normalize,
    ));
    // Overlapping recursive discovery roots may report the same canonical file
    // more than once. Canonical path aliases are one file, not an ID collision.
    const byPath = new Map(normalized.map((session) => [resolve(session.path), session]));
    return sortCatalogPaths(byPath.keys()).map((path) => byPath.get(path)!);
  }

}
