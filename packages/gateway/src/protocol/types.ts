// Tron protocol v2 is an intentionally small, versioned mobile contract. Pi
// objects must be projected into these bounded values rather than serialized
// directly; Pi JSONL and configuration files remain canonical.
export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };

export interface ModelRef {
  provider: string;
  id: string;
}

export type SessionPhase = "idle" | "running" | "compacting" | "retrying" | "interrupted";
export type SessionKind = "user" | "subagent";

export interface SessionSummary {
  id: string;
  name?: string;
  cwd: string;
  kind: SessionKind;
  parentSessionId?: string;
  createdAt: string;
  updatedAt: string;
  messageCount: number;
  firstMessage: string;
  phase: SessionPhase;
  summaryRevision: number;
}

/** Bounded global projection used to update dashboard rows without subscribing
 * every client to every full session transcript. */
export interface SessionSummaryUpdate {
  sessionId: string;
  summaryRevision: number;
  phase: SessionPhase;
  name?: string;
  updatedAt: string;
  messageCount: number;
  firstMessage: string;
}

export type ContentPart =
  | { id: string; type: "text"; text: string; attachment?: { name: string; mimeType: string; size: number } }
  | { id: string; type: "thinking"; text: string; redacted?: boolean }
  | { id: string; type: "image"; mimeType: string; blobId: string }
  | { id: string; type: "toolCall"; toolCallId: string; name: string; arguments: JsonValue };

interface TranscriptBase {
  id: string;
  parentId: string | null;
  timestamp: string;
}

export type TranscriptItem =
  | TranscriptBase & {
      kind: "message";
      role: "user" | "assistant" | "toolResult";
      content: ContentPart[];
      provider?: string;
      modelId?: string;
      stopReason?: string;
      errorMessage?: string;
      toolCallId?: string;
      toolName?: string;
      isError?: boolean;
      details?: JsonValue;
      usage?: JsonValue;
      /** Exact runtime timing when the owning Gateway observed this call. Older
       * canonical entries may omit it and clients derive an observed interval. */
      startedAt?: string;
      completedAt?: string;
      durationMs?: number;
      lastProgressAt?: string;
      progressSequence?: number;
    }
  | TranscriptBase & {
      kind: "bash";
      command: string;
      output: string;
      exitCode?: number;
      cancelled: boolean;
      truncated: boolean;
      fullOutputPath?: string;
      excludeFromContext?: boolean;
    }
  | TranscriptBase & {
      kind: "customMessage";
      customType: string;
      content: ContentPart[];
      details?: JsonValue;
    }
  | TranscriptBase & {
      kind: "customEntry";
      customType: string;
      data?: JsonValue;
    }
  | TranscriptBase & {
      kind: "compaction" | "branchSummary";
      summary: string;
      tokensBefore?: number;
      details?: JsonValue;
      usage?: JsonValue;
      fromHook?: boolean;
    }
  | TranscriptBase & {
      kind: "modelChange";
      modelRef: ModelRef;
    }
  | TranscriptBase & {
      kind: "thinkingChange";
      level: string;
    }
  | TranscriptBase & {
      kind: "label";
      targetId: string;
      label?: string;
    };

export interface ToolExecutionState {
  toolCallId: string;
  toolName: string;
  /** Monotonic within one active run; authoritative tie-breaker for parallel calls. */
  order: number;
  status: "running" | "completed" | "failed";
  arguments: JsonValue;
  partialResult?: JsonValue;
  result?: JsonValue;
  /** Bounded text extracted from Pi's current tool result for immediate audit. */
  output?: string;
  outputTruncated?: boolean;
  isError: boolean;
  startedAt: string;
  updatedAt: string;
  lastProgressAt: string;
  completedAt?: string;
  durationMs?: number;
  /** Monotonic per call; authoritative even when wall-clock timestamps collide. */
  progressSequence: number;
}

export interface RetryState {
  source: "agent" | "compaction" | "branchSummary";
  attempt: number;
  maxAttempts?: number;
  delayMs?: number;
  errorMessage?: string;
}

export interface SessionOperationState {
  id?: string;
  kind: "prompt" | "compaction" | "branchSummary" | "bash" | "retry";
  startedAt: string;
  reason?: string;
}

export type ExtensionInteraction = {
  id: string;
  method: "select" | "confirm" | "input" | "editor";
  title: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  prefill?: string;
  expiresAt?: string;
};

export interface ExtensionWidget {
  key: string;
  lines: string[];
  placement: "aboveEditor" | "belowEditor";
}

export interface ExtensionUIState {
  statuses: Record<string, string>;
  working: { message?: string; visible: boolean };
  hiddenThinkingLabel?: string;
  widgets: ExtensionWidget[];
  title?: string;
  editorRevision: number;
  editorText: string;
  pendingInteractions: ExtensionInteraction[];
}

export interface SessionStats {
  userMessages: number;
  assistantMessages: number;
  toolCalls: number;
  toolResults: number;
  totalMessages: number;
  tokens: { input: number; output: number; cacheRead: number; cacheWrite: number; total: number };
  latestCacheHitRate?: number;
  cost: number;
}

export interface QueuedMessageState {
  id: string;
  behavior: "steer" | "followUp";
  text: string;
  attachmentCount: number;
}

export interface SessionSnapshot {
  sessionId: string;
  runtimeGeneration: string;
  revision: number;
  eventSequence: number;
  phase: SessionPhase;
  name?: string;
  cwd: string;
  parentSessionId?: string;
  model?: ModelRef;
  thinkingLevel: string;
  availableThinkingLevels: string[];
  contextUsage?: { tokens: number | null; contextWindow: number; percent: number | null };
  stats: SessionStats;
  /** Legacy Pi queue projection retained for rolling protocol compatibility. */
  queued: { steering: string[]; followUp: string[] };
  queueRevision?: number;
  queuedItems?: QueuedMessageState[];
  transcript: TranscriptItem[];
  transcriptStart: number;
  transcriptTotal: number;
  streaming?: TranscriptItem;
  leafEntryId?: string;
  operation?: SessionOperationState;
  retry?: RetryState;
  toolExecutions: ToolExecutionState[];
  extensionUI: ExtensionUIState;
  diagnostics: Array<{ type: string; message: string }>;
}

export interface SessionTreeNode {
  id: string;
  parentId: string | null;
  timestamp: string;
  kind: TranscriptItem["kind"] | "sessionInfo";
  label?: string;
  preview: string;
  role?: "user" | "assistant" | "toolResult";
  depth: number;
  childCount: number;
  isCurrentPath: boolean;
}

export interface CommandInfo {
  name: string;
  description?: string;
  argumentHint?: string;
  source: "extension" | "skill" | "prompt";
  sourcePath?: string;
}

export interface ProtocolEvent {
  type: "event";
  topic: string;
  sessionId?: string;
  payload: JsonValue;
}
