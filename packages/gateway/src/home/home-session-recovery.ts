import { lstat, open, readdir } from "node:fs/promises";
import { resolve } from "node:path";

const MAXIMUM_SESSION_FILES = 100_000;
const MAXIMUM_ADOPTION_BYTES = 200 * 1_024 * 1_024;

const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const string = (value: unknown): value is string => typeof value === "string";
const id = (value: unknown): value is string => string(value) && value.length > 0;
const number = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0;
const instant = (value: unknown): boolean => string(value) && Number.isFinite(Date.parse(value));
const optional = (value: unknown, validate: (value: unknown) => boolean): boolean => value === undefined || validate(value);
const strings = (record: Record<string, unknown>, keys: string[]): boolean => keys.every(key => optional(record[key], string));
const boolean = (value: unknown): value is boolean => typeof value === "boolean";

function usage(value: unknown): boolean {
  return object(value) && ["input", "output", "cacheRead", "cacheWrite", "totalTokens"].every(key => number(value[key]))
    && optional(value.cacheWrite1h, number) && optional(value.reasoning, number) && object(value.cost)
    && ["input", "output", "cacheRead", "cacheWrite", "total"].every(key => number((value.cost as Record<string, unknown>)[key]));
}

function content(value: unknown, types: readonly string[], allowString = false): boolean {
  return allowString && string(value) || Array.isArray(value) && value.every(part => {
    if (!object(part) || !types.includes(String(part.type))) return false;
    switch (part.type) {
      case "text": return string(part.text) && optional(part.textSignature, string);
      case "image": return string(part.data) && string(part.mimeType);
      case "thinking": return string(part.thinking) && optional(part.thinkingSignature, string) && optional(part.redacted, boolean);
      case "toolCall": return id(part.id) && string(part.name) && object(part.arguments)
        && strings(part, ["thoughtSignature", "namespace"]);
      default: return false;
    }
  });
}
const userContent = (value: unknown): boolean => content(value, ["text", "image"], true);
const assistantContent = (value: unknown): boolean => content(value, ["text", "thinking", "toolCall"]);

function systemMessage(value: unknown): boolean {
  return object(value) && value.role === "system" && number(value.timestamp) && content(value.content, ["text"], true)
    && optional(value.sections, sections => object(sections) && Object.values(sections).every(section => section === null || string(section)))
    && optional(value.toolsAdded, tools => Array.isArray(tools) && tools.every(tool => object(tool)
      && string(tool.name) && string(tool.description) && object(tool.parameters)
      && optional(tool.constrainedSampling, sampling => sampling === false || object(sampling)
        && (sampling.type === "json_schema" && (sampling.strict === "prefer" || sampling.strict === "require")
          || sampling.type === "grammar" && object(sampling.variants)
            && Object.entries(sampling.variants).every(([key, grammar]) => ["openai_lark", "openai_regex"].includes(key) && string(grammar))))))
    && optional(value.toolsRemoved, tools => Array.isArray(tools) && tools.every(tool => object(tool) && string(tool.name)));
}

/** Version-3 SDK messages, including coding-agent roles; arbitrary extension
 * data is JSON, but context-bearing content must have a supported shape. */
function message(value: unknown): boolean {
  if (!object(value) || !number(value.timestamp)) return false;
  switch (value.role) {
    case "system": return systemMessage(value);
    case "user": return userContent(value.content);
    case "assistant": return assistantContent(value.content) && string(value.api) && string(value.provider) && string(value.model)
      && usage(value.usage) && string(value.stopReason) && ["pending", "stop", "length", "toolUse", "error", "aborted", "deferred"].includes(value.stopReason)
      && strings(value, ["responseModel", "responseId", "providerThinkingLevel", "thinkingLevel", "errorMessage", "rawStopReason"])
      && optional(value.endTurn, boolean)
      && optional(value.diagnostics, diagnostics => Array.isArray(diagnostics) && diagnostics.every(diagnostic => object(diagnostic)
        && string(diagnostic.type) && number(diagnostic.timestamp) && optional(diagnostic.details, object)
        && optional(diagnostic.error, error => object(error) && string(error.message) && strings(error, ["name", "stack"])
          && optional(error.code, code => string(code) || typeof code === "number" && Number.isFinite(code)))))
      && optional(value.deferred, deferred => object(deferred) && ["provider", "modelId", "api", "id"].every(key => string(deferred[key]))
        && optional(deferred.expiresAt, number) && optional(deferred.pollAfterMs, number));
    case "toolResult": return id(value.toolCallId) && string(value.toolName) && content(value.content, ["text", "image"])
      && boolean(value.isError) && optional(value.usage, usage)
      && optional(value.nestedCalls, nested => object(nested) && boolean(nested.complete) && Array.isArray(nested.calls)
        && nested.calls.every(call => object(call) && id(call.id) && string(call.name)
          && string(call.status) && ["ok", "error", "unfinished"].includes(call.status) && optional(call.arguments, object)
          && optional(call.argumentsBytes, number) && optional(call.durationMs, number) && optional(call.error, string)));
    case "bashExecution": return string(value.command) && string(value.output) && optional(value.exitCode, exit => typeof exit === "number" && Number.isFinite(exit))
      && boolean(value.cancelled) && boolean(value.truncated) && optional(value.fullOutputPath, string) && optional(value.excludeFromContext, boolean);
    case "custom": return string(value.customType) && userContent(value.content) && boolean(value.display);
    case "branchSummary": return string(value.summary) && (value.fromId === null || id(value.fromId));
    case "compactionSummary": return string(value.summary) && number(value.tokensBefore);
    default: return false;
  }
}

function isCanonicalEntry(record: Record<string, unknown>, previousIds: Set<string>): boolean {
  if (!id(record.id) || !(record.parentId === null || id(record.parentId)) || !instant(record.timestamp)) return false;
  switch (record.type) {
    case "message": return message(record.message);
    case "thinking_level_change": return string(record.thinkingLevel);
    case "model_change": return string(record.provider) && string(record.modelId);
    case "usage": return string(record.kind) && string(record.provider) && string(record.model) && usage(record.usage) && optional(record.note, string);
    case "compaction": return string(record.summary) && id(record.firstKeptEntryId) && previousIds.has(record.firstKeptEntryId)
      && number(record.tokensBefore) && optional(record.usage, usage) && optional(record.fromHook, boolean) && optional(record.systemMessage, systemMessage);
    case "branch_summary": return id(record.fromId) && previousIds.has(record.fromId) && string(record.summary)
      && optional(record.usage, usage) && optional(record.fromHook, boolean);
    case "custom": return string(record.customType);
    case "custom_message": return string(record.customType) && userContent(record.content) && boolean(record.display);
    case "context_edit": return id(record.targetId) && previousIds.has(record.targetId)
      && (record.replacement === null || object(record.replacement)
        && (userContent(record.replacement.content) || assistantContent(record.replacement.content)));
    case "label": return id(record.targetId) && previousIds.has(record.targetId) && optional(record.label, string);
    case "session_info": return optional(record.name, string);
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
      if (!info.isFile() || info.size === 0) return { action: "blocked" };
      const handle = await open(path, "r");
      let header: Record<string, unknown> | undefined;
      try {
        const afterOpen = await handle.stat();
        if (!afterOpen.isFile() || afterOpen.dev !== info.dev || afterOpen.ino !== info.ino || afterOpen.size !== info.size) {
          return { action: "blocked" };
        }
        const seen = new Set<string>();
        let tip: string | null = null;
        const parseLine = (bytes: Buffer): boolean => {
          if (bytes.length === 0) return false;
          const parsed: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
          if (!object(parsed)) return false;
          if (!header) {
            if (parsed.type !== "session" || parsed.version !== 3 || !id(parsed.id) || !instant(parsed.timestamp)
              || !string(parsed.cwd) || !optional(parsed.parentSession, string)) return false;
            header = parsed;
            // A stopped predecessor can legitimately retain >200 MiB including
            // abort settlement. The byte limit guards adoption, not evidence.
            return !(path === expectedPath || header.id === input.sessionId) || info.size <= MAXIMUM_ADOPTION_BYTES;
          }
          // One append-ordered chain proves parent membership and acyclicity in
          // O(entries), before Pi can follow any parent pointer. No graph walk.
          if (!isCanonicalEntry(parsed, seen) || seen.has(parsed.id as string) || parsed.id === header.id || parsed.parentId !== tip) return false;
          tip = parsed.id as string;
          seen.add(tip);
          return true;
        };
        // Retain only one line plus IDs, never the complete chapter. Read exactly
        // the finite stat cut; appends/replacements during the scan block below.
        let parts: Buffer[] = [];
        let lineBytes = 0;
        let readBytes = 0;
        const stream = handle.createReadStream({ autoClose: false, end: info.size - 1, highWaterMark: 64 * 1_024 });
        for await (const chunk of stream) {
          const bytes = chunk as Buffer;
          readBytes += bytes.length;
          let start = 0;
          for (let end = bytes.indexOf(0x0a, start); end !== -1; end = bytes.indexOf(0x0a, start)) {
            parts.push(bytes.subarray(start, end));
            lineBytes += end - start;
            if (!parseLine(Buffer.concat(parts, lineBytes))) return { action: "blocked" };
            parts = [];
            lineBytes = 0;
            start = end + 1;
          }
          if (start < bytes.length) {
            parts.push(bytes.subarray(start));
            lineBytes += bytes.length - start;
          }
        }
        if (!header || lineBytes !== 0 || readBytes !== info.size) return { action: "blocked" };
        const afterRead = await handle.stat();
        if (afterRead.dev !== afterOpen.dev || afterRead.ino !== afterOpen.ino || afterRead.size !== afterOpen.size
          || afterRead.mtimeMs !== afterOpen.mtimeMs || afterRead.ctimeMs !== afterOpen.ctimeMs) return { action: "blocked" };
      } finally {
        await handle.close();
      }
      if (header?.id === input.sessionId) matches.push(path);
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
