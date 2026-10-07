import { lstat, open, readdir } from "node:fs/promises";
import { resolve } from "node:path";

const MAXIMUM_SESSION_FILES = 100_000;
const MAXIMUM_SESSION_BYTES = 200 * 1_024 * 1_024;
const MAXIMUM_LINE_BYTES = 8 * 1_024 * 1_024;
const SESSION_ENTRY_TYPES = new Set([
  "message", "thinking_level_change", "model_change", "usage", "compaction",
  "branch_summary", "custom", "custom_message", "context_edit", "label", "session_info",
]);

function isCanonicalEntry(record: Record<string, unknown>): boolean {
  if (!SESSION_ENTRY_TYPES.has(String(record.type)) || typeof record.id !== "string"
    || !(record.parentId === null || typeof record.parentId === "string")
    || typeof record.timestamp !== "string") return false;
  switch (record.type) {
    case "message": return !!record.message && typeof record.message === "object";
    case "thinking_level_change": return typeof record.thinkingLevel === "string";
    case "model_change": return typeof record.provider === "string" && typeof record.modelId === "string";
    case "usage": return typeof record.kind === "string" && typeof record.provider === "string"
      && typeof record.model === "string" && !!record.usage && typeof record.usage === "object";
    case "compaction": return typeof record.summary === "string" && typeof record.firstKeptEntryId === "string"
      && typeof record.tokensBefore === "number";
    case "branch_summary": return typeof record.fromId === "string" && typeof record.summary === "string";
    case "custom": return typeof record.customType === "string";
    case "custom_message": return typeof record.customType === "string" && record.content !== undefined
      && typeof record.display === "boolean";
    case "context_edit": return typeof record.targetId === "string" && record.replacement !== undefined;
    case "label": return typeof record.targetId === "string";
    case "session_info": return true;
    default: return false;
  }
}

export type ReservedHomeSessionScan =
  | { action: "absent" }
  | { action: "adopt"; path: string }
  | { action: "blocked" };

/**
 * Establish whether a reserved session can be adopted or safely created. Unlike
 * SessionManager.findById this scans every candidate and treats any uncertain
 * candidate as evidence that absence has not been proven. It never repairs or
 * mutates a canonical file.
 */
export async function scanReservedHomeSession(input: {
  directory: string;
  expectedPath: string;
  sessionId: string;
}): Promise<ReservedHomeSessionScan> {
  try {
    const expectedPath = resolve(input.expectedPath);
    const names = await readdir(input.directory);
    if (names.length > MAXIMUM_SESSION_FILES) return { action: "blocked" };
    const matches: string[] = [];
    for (const name of names) {
      const path = resolve(input.directory, name);
      const info = await lstat(path);
      if (info.isSymbolicLink()) return { action: "blocked" };
      if (!name.endsWith(".jsonl")) continue;
      if (!info.isFile() || info.size === 0 || info.size > MAXIMUM_SESSION_BYTES) return { action: "blocked" };
      const handle = await open(path, "r");
      let bytes: Buffer;
      try {
        const afterOpen = await handle.stat();
        if (!afterOpen.isFile() || afterOpen.dev !== info.dev || afterOpen.ino !== info.ino || afterOpen.size !== info.size) {
          return { action: "blocked" };
        }
        bytes = Buffer.alloc(info.size);
        let offset = 0;
        while (offset < bytes.length) {
          const read = await handle.read(bytes, offset, bytes.length - offset, offset);
          if (read.bytesRead === 0) return { action: "blocked" };
          offset += read.bytesRead;
        }
        const afterRead = await handle.stat();
        if (afterRead.dev !== afterOpen.dev || afterRead.ino !== afterOpen.ino || afterRead.size !== afterOpen.size
          || afterRead.mtimeMs !== afterOpen.mtimeMs || afterRead.ctimeMs !== afterOpen.ctimeMs) return { action: "blocked" };
      } finally {
        await handle.close();
      }
      if (bytes.length === 0 || bytes[bytes.length - 1] !== 0x0a) return { action: "blocked" };
      const lines = bytes.toString("utf8").slice(0, -1).split("\n");
      if (lines.length === 0) return { action: "blocked" };
      let header: Record<string, unknown> | undefined;
      for (let index = 0; index < lines.length; index += 1) {
        const line = lines[index]!;
        if (line.length === 0 || Buffer.byteLength(line) > MAXIMUM_LINE_BYTES) return { action: "blocked" };
        let parsed: unknown;
        try { parsed = JSON.parse(line); } catch { return { action: "blocked" }; }
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { action: "blocked" };
        const record = parsed as Record<string, unknown>;
        if (index === 0) header = record;
        else if (!isCanonicalEntry(record)) return { action: "blocked" };
      }
      if (header?.type !== "session" || header.version !== 3 || typeof header.id !== "string") {
        return { action: "blocked" };
      }
      if (header.id === input.sessionId) matches.push(path);
    }
    if (matches.length === 0) {
      // A path reserved before the scan is part of the evidence even when an
      // unexpected non-JSONL object occupies it.
      const expectedInfo = await lstat(expectedPath).catch(error => {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
        throw error;
      });
      if (expectedInfo) return { action: "blocked" };
      return { action: "absent" };
    }
    if (matches.length !== 1 || matches[0] !== expectedPath) return { action: "blocked" };
    return { action: "adopt", path: expectedPath };
  } catch {
    return { action: "blocked" };
  }
}
