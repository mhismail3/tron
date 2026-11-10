import { realpathSync } from "node:fs";
import { open, stat } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { EXTENSION_LIFECYCLE_ARTIFACT_VERSION, MAX_EXTENSION_ARTIFACT_BYTES, MAX_EXTENSION_RUN_CHILDREN, MAX_EXTENSION_LIFECYCLE_HEADER_BYTES, extensionLifecycleState, hasExtensionLifecycleProjectionProperty, observedPausedProcessTerminalAt, inspectExtensionLifecycleProjection, lifecycleProjectionArtifact, parseExtensionLifecycleProjectionHeader, terminalLifecycleStates, type ExtensionArtifactRejectionReason } from "../projection/extension-run-projection.js";
import { RECOVERY_SESSION_OWNER } from "./child-session-admission.js";
import type { OwnedTurnOwner } from "./owned-turn-owner.js";


const EMBEDDED_LIFECYCLE_ARTIFACT = Symbol("embedded-lifecycle-artifact");

type EmbeddedLifecycleArtifact = Record<string, unknown> & { [EMBEDDED_LIFECYCLE_ARTIFACT]?: true };

export const WORKFLOW_CHILD_ARTIFACT_DIRECTORIES = Symbol("workflow-child-artifact-directories");

const WORKFLOW_CHILD_PROCESS_SETTLED = Symbol("workflow-child-process-settled");


export function detachedWorkflowChildKeys(status: Record<string, unknown>): ReadonlyMap<string, string> {
  const keys = new Map<string, string>();
  const steps = Array.isArray(status.steps) ? status.steps.slice(0, MAX_EXTENSION_RUN_CHILDREN) : [];
  for (const step of steps) {
    const edge = step as Record<string, unknown> | null;
    if (edge?.async === true && typeof edge.workflowKey === "string" && typeof edge.runId === "string"
      && !(edge as Record<PropertyKey, unknown>)[WORKFLOW_CHILD_PROCESS_SETTLED]) keys.set(edge.workflowKey, edge.runId);
  }
  return keys;
}


function markEmbeddedLifecycleArtifact(value: Record<string, unknown>): Record<string, unknown> {
  Object.defineProperty(value, EMBEDDED_LIFECYCLE_ARTIFACT, { configurable: false, enumerable: false, value: true, writable: false });
  return value;
}


export function isEmbeddedLifecycleArtifact(value: unknown): boolean {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    && (value as EmbeddedLifecycleArtifact)[EMBEDDED_LIFECYCLE_ARTIFACT] === true;
}


export function preserveEmbeddedLifecycleMarker(source: unknown, value: Record<string, unknown>): Record<string, unknown> {
  return isEmbeddedLifecycleArtifact(source) ? markEmbeddedLifecycleArtifact(value) : value;
}


type ExtensionArtifactDirectoryIdentity = { dev: number; ino: number };

type OpenedExtensionArtifact = {
  handle: Awaited<ReturnType<typeof open>>;
  directory: ExtensionArtifactDirectoryIdentity;
};


export class OversizedExtensionArtifactError extends Error {
  constructor() {
    super("Extension status artifact exceeds the legacy document limit");
    this.name = "OversizedExtensionArtifactError";
  }
}


export class ForeignExtensionArtifactSessionError extends Error {
  constructor() {
    super("Extension lifecycle projection belongs to another canonical session");
    this.name = "ForeignExtensionArtifactSessionError";
  }
}


export function extensionArtifactReadFailureReason(error: unknown): ExtensionArtifactRejectionReason {
  if (error instanceof OversizedExtensionArtifactError) return "oversized-artifact";
  if (error instanceof ForeignExtensionArtifactSessionError) return "ownership-mismatch";
  if (error instanceof SyntaxError) return "malformed-artifact";
  return "artifact-replacement-in-progress";
}

const EXTENSION_ARTIFACT_DISCOVERY_READ_RETRIES = 3;

const MAX_EXTENSION_EVENT_TAIL_BYTES = 64 * 1_024;

const MAX_EXTENSION_EVENT_LINES = 256;
export class SubagentArtifactStatus {
  constructor(readonly turns: OwnedTurnOwner) {}


  async openOwnedExtensionArtifact(
    asyncDir: string,
    name: "status.json" | "events.jsonl" | "recovery-descriptor.json" | "process-terminal.json",
    expectedDirectory?: ExtensionArtifactDirectoryIdentity,
  ): Promise<OpenedExtensionArtifact | undefined> {
    const canonicalAsyncDir = realpathSync(asyncDir);
    if (canonicalAsyncDir !== asyncDir || !this.turns.extensionArtifactPathAllowed(canonicalAsyncDir)) return undefined;
    const directory = await stat(canonicalAsyncDir);
    if (!directory.isDirectory()
      || expectedDirectory && (directory.dev !== expectedDirectory.dev || directory.ino !== expectedDirectory.ino)) return undefined;
    const lexicalPath = join(canonicalAsyncDir, name);
    let canonicalPath: string;
    try {
      canonicalPath = realpathSync(lexicalPath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
    if (dirname(canonicalPath) !== canonicalAsyncDir || !this.turns.extensionArtifactPathAllowed(canonicalPath)) return undefined;
    const handle = await open(lexicalPath, "r");
    try {
      const [opened, observed, observedDirectory] = await Promise.all([
        handle.stat(), stat(canonicalPath), stat(canonicalAsyncDir),
      ]);
      if (!opened.isFile() || !observed.isFile() || !observedDirectory.isDirectory()
        || realpathSync(lexicalPath) !== canonicalPath
        || opened.dev !== observed.dev || opened.ino !== observed.ino
        || directory.dev !== observedDirectory.dev || directory.ino !== observedDirectory.ino) {
        await handle.close();
        return undefined;
      }
      return { handle, directory: { dev: directory.dev, ino: directory.ino } };
    } catch (error) {
      await handle.close();
      throw error;
    }
  }


  async readWorkflowChildDetails(asyncDir: string, status: Record<string, unknown>): Promise<Record<string, unknown>> {
    if (status.mode !== "workflow" || typeof status.runId !== "string" || !Array.isArray(status.steps)) return status;
    const directories: string[] = [];
    let unavailableChildren = 0;
    const steps: unknown[] = [];
    for (const value of status.steps.slice(0, MAX_EXTENSION_RUN_CHILDREN)) {
      if (!value || typeof value !== "object" || Array.isArray(value)) { steps.push(value); continue; }
      const edge = value as Record<string, unknown>;
      steps.push(edge);
      if (edge.async !== true || typeof edge.runId !== "string" || !edge.runId
        || Buffer.byteLength(edge.runId) > 256 || /[\\/\0]/u.test(edge.runId)
        || typeof edge.workflowKey !== "string" || typeof edge.sessionOwnerId !== "string"
        || typeof edge.sessionFile !== "string") continue;
      const directory = join(dirname(asyncDir), edge.runId);
      if (dirname(directory) !== dirname(asyncDir) || directory === asyncDir) continue;
      directories.push(directory);
      unavailableChildren += 1;
      const child = await this.readExtensionStatusArtifactWithReplacementRetry(directory, false).catch(() => undefined);
      if (!child || child.runId !== edge.runId || child.parentWorkflowRunId !== status.runId
        || child.workflowKey !== edge.workflowKey || child.sessionOwnerId !== edge.sessionOwnerId || child.sessionId !== status.sessionId
        || child.mode !== "single" || !Array.isArray(child.steps) || child.steps.length !== 1) continue;
      const detail = child.steps[0];
      if (!detail || typeof detail !== "object" || Array.isArray(detail)) continue;
      const source = detail as Record<string, unknown>;
      if (source.sessionFile !== edge.sessionFile || source.agent !== edge.agent
        || !this.turns.operations.childSessionAdmission.admit(edge.sessionFile, status.runId, edge.workflowKey, edge.sessionOwnerId)) continue;
      unavailableChildren -= 1;
      const projected = { ...edge };
      for (const key of ["model", "thinking", "currentTool", "currentPath", "lastActivityAt", "currentToolStartedAt",
        "toolCount", "turnCount", "recentOutput", "output", "error", "attention", "attentionState", "startedAt", "endedAt", "durationMs", "status"] as const) {
        if (source[key] !== undefined) projected[key] = source[key];
      }
      if (typeof child.state === "string") projected.state = child.state;
      if (observedPausedProcessTerminalAt(child, edge.runId) !== undefined) {
        Object.assign(projected, { [WORKFLOW_CHILD_PROCESS_SETTLED]: true });
      }
      if (source.toolCount === undefined && Array.isArray(source.recentTools) && source.recentTools.length === 0) projected.toolCount = 0;
      steps[steps.length - 1] = projected;
    }
    const omission = status.lifecycleOmissions as { children?: number; byteLimitExceeded?: boolean } | undefined;
    const omittedChildren = typeof omission?.children === "number" && Number.isSafeInteger(omission.children) && omission.children >= 0
      ? omission.children : 0;
    return Object.assign({ ...status, steps: [...steps, ...status.steps.slice(MAX_EXTENSION_RUN_CHILDREN)],
      ...(unavailableChildren > 0 ? { lifecycleOmissions: {
        children: omittedChildren + unavailableChildren,
        byteLimitExceeded: omission?.byteLimitExceeded === true,
      } } : {}),
    }, { [WORKFLOW_CHILD_ARTIFACT_DIRECTORIES]: directories });
  }


  async readExtensionStatusArtifact(asyncDir: string, includeWorkflowChildren = true): Promise<Record<string, unknown> | undefined> {
    if (!this.turns.extensionArtifactPathAllowed(asyncDir)) return undefined;
    const opened = await this.openOwnedExtensionArtifact(asyncDir, "status.json");
    if (!opened) return undefined;
    try {
      const headerBuffer = Buffer.alloc(MAX_EXTENSION_LIFECYCLE_HEADER_BYTES);
      const { bytesRead: headerBytesRead } = await opened.handle.read(headerBuffer, 0, headerBuffer.length, 0);
      const headerBytes = headerBuffer.subarray(0, headerBytesRead);
      const lifecycleHeader = parseExtensionLifecycleProjectionHeader(headerBytes);
      if (lifecycleHeader !== undefined) {
        const projection = inspectExtensionLifecycleProjection(lifecycleHeader);
        if (!projection) throw new SyntaxError("Invalid extension lifecycle projection header");
        const parentIdentity = this.turns.operations.sessionFile ? resolve(this.turns.operations.sessionFile) : this.turns.operations.id;
        if (projection.sessionId !== undefined && projection.sessionId !== parentIdentity) {
          throw new ForeignExtensionArtifactSessionError();
        }
        const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
        const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
        const full: unknown = bytesRead <= MAX_EXTENSION_ARTIFACT_BYTES ? JSON.parse(buffer.subarray(0, bytesRead).toString("utf8")) : undefined;
        if (full !== undefined && (!full || typeof full !== "object" || Array.isArray(full))) throw new SyntaxError("Invalid full extension status");
        const status = full as Record<string, unknown> | undefined;
        if (status && (status.runId !== projection.runId
          || (projection.toolCallId !== undefined && status.toolCallId !== projection.toolCallId))) throw new ForeignExtensionArtifactSessionError();
        const projected = status ? { ...status, lifecycleArtifactVersion: EXTENSION_LIFECYCLE_ARTIFACT_VERSION }
          : lifecycleProjectionArtifact({ ...projection, omitted: { ...projection.omitted, byteLimitExceeded: true } });
        const detailed = includeWorkflowChildren ? await this.readWorkflowChildDetails(asyncDir, projected) : projected;
        const withRecovery = await this.attachRecoverySessionOwner(asyncDir, detailed, opened.directory);
        const withProof = await this.attachProcessTerminalProof(asyncDir, withRecovery, opened.directory);
        return markEmbeddedLifecycleArtifact(withProof);
      }
      if (hasExtensionLifecycleProjectionProperty(headerBytes)) {
        throw new SyntaxError("Incomplete extension lifecycle projection header");
      }
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      const bytes = buffer.subarray(0, bytesRead);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) {
        const terminal = await this.readOversizedTerminalExtensionArtifact(
          asyncDir,
          bytes.subarray(0, MAX_EXTENSION_ARTIFACT_BYTES),
          opened.directory,
        );
        if (!terminal) throw new OversizedExtensionArtifactError();
        return terminal;
      }
      const parsed: unknown = JSON.parse(bytes.toString("utf8"));
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
      const recovered = await this.attachRecoverySessionOwner(asyncDir, parsed as Record<string, unknown>, opened.directory);
      return this.attachProcessTerminalProof(asyncDir, recovered, opened.directory);
    } finally {
      await opened.handle.close();
    }
  }


  async attachProcessTerminalProof(
    asyncDir: string,
    status: Record<string, unknown>,
    directoryIdentity: ExtensionArtifactDirectoryIdentity,
  ): Promise<Record<string, unknown>> {
    const withoutProof = (): Record<string, unknown> => {
      const { processTerminal: _processTerminal, ...remaining } = status;
      return remaining;
    };
    const runId = typeof status.runId === "string" ? status.runId : undefined;
    if (!runId || Buffer.byteLength(runId) > 256 || /[\\/\0]/u.test(runId)) return withoutProof();
    const opened = await this.openOwnedExtensionArtifact(
      asyncDir,
      "process-terminal.json",
      directoryIdentity,
    ).catch(() => undefined);
    if (!opened) return status;
    try {
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return withoutProof();
      const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
        || (parsed as Record<string, unknown>).runId !== runId) return withoutProof();
      return { ...status, processTerminal: parsed as Record<string, unknown> };
    } catch {
      return withoutProof();
    } finally {
      await opened.handle.close();
    }
  }


  private async attachRecoverySessionOwner(
    asyncDir: string,
    status: Record<string, unknown>,
    directoryIdentity: ExtensionArtifactDirectoryIdentity,
  ): Promise<Record<string, unknown>> {
    if (status.mode !== "single" || typeof status.runId !== "string" || !status.runId
      || Buffer.byteLength(status.runId) > 256 || /[\\/\0]/u.test(status.runId)
      || !Array.isArray(status.steps) || status.steps.length !== 1) return status;
    const step = status.steps[0];
    if (!step || typeof step !== "object" || Array.isArray(step)) return status;
    const stepRecord = step as Record<string, unknown>;
    const sessionFile = typeof stepRecord.sessionFile === "string" ? stepRecord.sessionFile : undefined;
    if (!sessionFile || !isAbsolute(sessionFile)) return status;
    const opened = await this.openOwnedExtensionArtifact(
      asyncDir,
      "recovery-descriptor.json",
      directoryIdentity,
    ).catch(() => undefined);
    if (!opened) return status;
    try {
      const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return status;
      const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return status;
      const descriptor = parsed as Record<string, unknown>;
      const budget = descriptor.runFanoutBudget;
      if (descriptor.version !== 1 || descriptor.sourceRunId !== status.runId
        || descriptor.sessionFile !== sessionFile
        || !budget || typeof budget !== "object" || Array.isArray(budget)) return status;
      const budgetRecord = budget as Record<string, unknown>;
      const sessionOwnerId = budgetRecord.rootRunId;
      if (budgetRecord.version !== 1 || typeof sessionOwnerId !== "string" || !sessionOwnerId
        || Buffer.byteLength(sessionOwnerId) > 256 || /[\\/\0]/u.test(sessionOwnerId)) return status;
      return {
        ...status,
        steps: [{ ...stepRecord, [RECOVERY_SESSION_OWNER]: sessionOwnerId }],
      };
    } catch {
      return status;
    } finally {
      await opened.handle.close();
    }
  }


  async readOversizedTerminalExtensionArtifact(
    asyncDir: string,
    headerBytes: Buffer,
    directoryIdentity: ExtensionArtifactDirectoryIdentity,
  ): Promise<Record<string, unknown> | undefined> {
    const headerText = headerBytes.toString("utf8");
    const steps = /,\s*"steps"\s*:/u.exec(headerText);
    if (!steps) return undefined;
    let header: unknown;
    try {
      header = JSON.parse(`${headerText.slice(0, steps.index)}\n}`);
    } catch {
      return undefined;
    }
    if (!header || typeof header !== "object" || Array.isArray(header)) return undefined;
    const candidate = header as Record<string, unknown>;
    const runId = typeof candidate.runId === "string" ? candidate.runId : undefined;
    const headerState = extensionLifecycleState(candidate.state ?? candidate.status);
    if (!runId || !terminalLifecycleStates.has(headerState)) return undefined;

    const openedEvents = await this.openOwnedExtensionArtifact(asyncDir, "events.jsonl", directoryIdentity);
    if (!openedEvents) return undefined;
    try {
      const metadata = await openedEvents.handle.stat();
      if (!metadata.isFile()) return undefined;
      const length = Math.min(metadata.size, MAX_EXTENSION_EVENT_TAIL_BYTES);
      const offset = Math.max(0, metadata.size - length);
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await openedEvents.handle.read(buffer, 0, length, offset);
      let text = buffer.subarray(0, bytesRead).toString("utf8");
      if (offset > 0) {
        const firstNewline = text.indexOf("\n");
        if (firstNewline < 0) return undefined;
        text = text.slice(firstNewline + 1);
      }
      const lines = text.split("\n").filter(Boolean).slice(-MAX_EXTENSION_EVENT_LINES);
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const line = lines[index]!;
        if (Buffer.byteLength(line) > MAX_EXTENSION_EVENT_TAIL_BYTES) continue;
        let event: unknown;
        try { event = JSON.parse(line); } catch { continue; }
        if (!event || typeof event !== "object" || Array.isArray(event)) continue;
        const value = event as Record<string, unknown>;
        if (value.runId !== runId || !Number.isSafeInteger(value.ts) || (value.ts as number) < 0) continue;
        const recognizedTerminalEvent = value.type === "subagent.workflow.completed"
          || value.type === "subagent.run.completed" || value.type === "subagent.run.stopped";
        if (!recognizedTerminalEvent) continue;
        const eventState = value.type === "subagent.workflow.completed"
          ? extensionLifecycleState(value.state)
          : value.type === "subagent.run.completed"
            ? extensionLifecycleState(value.status)
            : "stopped";
        if (eventState !== headerState || !terminalLifecycleStates.has(eventState)) return undefined;
        const persistedAt = typeof candidate.lastUpdate === "number" && Number.isSafeInteger(candidate.lastUpdate)
          ? Math.max(candidate.lastUpdate, value.ts as number)
          : value.ts;
        return { ...candidate, state: eventState, endedAt: value.ts, lastUpdate: persistedAt };
      }
      return undefined;
    } finally {
      await openedEvents.handle.close();
    }
  }


  async readExtensionStatusArtifactWithReplacementRetry(
    asyncDir: string,
    includeWorkflowChildren = true,
  ): Promise<Record<string, unknown> | undefined> {
    let value = await this.readExtensionStatusArtifact(asyncDir, includeWorkflowChildren);
    for (let attempt = 0; value === undefined && attempt < EXTENSION_ARTIFACT_DISCOVERY_READ_RETRIES; attempt += 1) {
      value = await this.readExtensionStatusArtifact(asyncDir, includeWorkflowChildren);
    }
    return value;
  }
}
