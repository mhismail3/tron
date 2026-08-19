// Tron protocol v3 is an intentionally small, versioned mobile contract. Pi
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
      /** Disposable provenance derived from public Pi sourceInfo; absent means unknown/ambiguous. */
      extensionOrigin?: ExtensionToolOrigin | undefined;
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

export interface ExtensionToolOrigin {
  /** Public Pi source identity; package and extension names are intentionally not interpreted by Tron. */
  source: string;
}

export type ExtensionRunStatus = "running" | "completed" | "failed";

/** Structured, bounded progress emitted by an extension-owned delegated run.
 * This is intentionally presentation-neutral: native clients may render it
 * as a live card while the extension remains the authority for execution. */
export interface ExtensionRunChild {
  id: string;
  label: string;
  status: ExtensionRunStatus;
  task?: string;
  lastActivityAt?: string;
  currentTool?: string;
  currentToolStartedAt?: string;
  currentPath?: string;
  toolCount?: number;
  turnCount?: number;
  durationMs?: number;
  output?: string;
  children?: ExtensionRunChild[];
}

export interface ExtensionRunActivity {
  id: string;
  runId?: string;
  toolCallId: string;
  source: ExtensionToolOrigin;
  title: string;
  mode?: string;
  status: ExtensionRunStatus;
  startedAt: string;
  updatedAt: string;
  lastActivityAt?: string;
  currentTool?: string;
  currentToolStartedAt?: string;
  currentPath?: string;
  toolCount?: number;
  turnCount?: number;
  durationMs?: number;
  output?: string;
  children: ExtensionRunChild[];
}

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
  /** Disposable provenance derived from public Pi sourceInfo; absent means unknown/ambiguous. */
  extensionOrigin?: ExtensionToolOrigin | undefined;
  /** Optional structured extension-owned run projection for native clients. */
  extensionActivity?: ExtensionRunActivity;
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
  kind: "prompt" | "command" | "compaction" | "branchSummary" | "bash" | "retry";
  startedAt: string;
  reason?: string;
}

export interface ExtensionQuestionnaireOption {
  label: string;
  description?: string;
  preview?: string;
}

export interface ExtensionQuestionnaireDescriptor {
  version: 1;
  question: string;
  context?: string;
  options: ExtensionQuestionnaireOption[];
  allowMultiple: boolean;
  allowFreeform: boolean;
}

export interface ExtensionQuestionnaireSelection {
  option: number;
  comment?: string;
}

export interface ExtensionQuestionnaireAnswer {
  selections: ExtensionQuestionnaireSelection[];
  freeform?: string;
}

export type ExtensionInteraction = {
  id: string;
  hostEpoch: string;
  presentationRevision: number;
  method: "select" | "confirm" | "input" | "editor";
  title: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  prefill?: string;
  expiresAt?: string;
  /** Additive descriptor; old clients ignore it and answer the primitive dialog. */
  questionnaire?: ExtensionQuestionnaireDescriptor;
};

export interface ExtensionOwner {
  id: string;
  title: string;
  source: string;
}

export interface ExtensionWidget {
  key: string;
  revision: number;
  lines: string[];
  placement: "aboveEditor" | "belowEditor";
  owner?: ExtensionOwner;
}

export interface ExtensionPresentationDiagnostic {
  code: string;
  message: string;
}

export interface ExtensionFrameStyle {
  bold?: true;
  dim?: true;
  italic?: true;
  underline?: true;
  inverse?: true;
  strike?: true;
  foreground?: string;
  background?: string;
  link?: string;
}

export interface ExtensionFrameRun { text: string; style: ExtensionFrameStyle }
export interface ExtensionFrameLine { plainText: string; runs: ExtensionFrameRun[] }
export interface ExtensionFrameCursor { row: number; column: number }
export interface ExtensionFrame {
  width: number;
  height: number;
  lines: ExtensionFrameLine[];
  plainText: string;
  cursor?: ExtensionFrameCursor;
}

export type ExtensionSurfaceKind = "header" | "footer" | "widget" | "custom" | "overlay"
  | "editor" | "toolRenderer" | "messageRenderer" | "entryRenderer" | "markdown" | "unknown";
export type ExtensionSurfacePlacement = "header" | "footer" | "aboveEditor" | "belowEditor"
  | "transcript" | "overlay" | "fullscreen";
export interface ExtensionSurface {
  id: string;
  kind: ExtensionSurfaceKind;
  placement: ExtensionSurfacePlacement;
  lifecycle: "retained" | "blocking" | "transient" | "restored";
  targetId?: string;
  provenance?: { source?: string; path?: string };
  revision: number;
  focused: boolean;
  inputMode: "none" | "keys" | "textAndKeys";
  frame: ExtensionFrame;
}

export interface ExtensionInputLease {
  id: string;
  connectionId: string;
  surfaceId: string;
  surfaceRevision: number;
  acquiredAt: string;
}

export interface ExtensionSemanticState {
  statuses: Record<string, string>;
  statusOwners: Record<string, ExtensionOwner>;
  working: {
    message?: string;
    visible: boolean;
    indicator: { kind: "default" | "hidden" | "static" | "animated"; frames: string[]; intervalMs?: number };
  };
  hiddenThinkingLabel?: string;
  widgets: ExtensionWidget[];
  title?: string;
  toolsExpanded: boolean;
  editorRevision: number;
  editorText: string;
}

/** Versioned, bounded, disposable projection of one live Pi extension-host epoch. */
export interface ExtensionPresentationState {
  version: 2;
  hostEpoch: string;
  revision: number;
  capabilities: string[];
  diagnostics: ExtensionPresentationDiagnostic[];
  semanticState: ExtensionSemanticState;
  surfaces: ExtensionSurface[];
  pendingInteractions: ExtensionInteraction[];
  inputLease?: ExtensionInputLease;
  projection?: {
    complete: boolean;
    omitted: string[];
    omittedSurfaces?: Array<{ id: string; revision: number }>;
  };
}

export interface ExtensionSemanticPatch {
  statuses?: Record<string, string>;
  statusOwners?: Record<string, ExtensionOwner>;
  working?: ExtensionSemanticState["working"];
  hiddenThinkingLabel?: string | null;
  widgets?: ExtensionWidget[];
  title?: string | null;
  toolsExpanded?: boolean;
  editorRevision?: number;
  editorText?: string;
  editorAction?: "set" | "paste" | "native";
  editorDelta?: string;
  editorOperationId?: string;
}

export interface ExtensionPresentationMutation {
  version: 2;
  hostEpoch: string;
  revision: number;
  semantic?: ExtensionSemanticPatch;
  interactionList?: ExtensionInteraction[];
  surfaceUpserts?: ExtensionSurface[];
  surfaceRemovals?: string[];
  inputLease?: ExtensionInputLease | null;
  capabilities?: string[];
  diagnostics?: ExtensionPresentationDiagnostic[];
  notification?: { message: string; type: "info" | "warning" | "error" };
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
  /** Total uploaded items retained for rolling protocol compatibility. */
  attachmentCount: number;
  /** Optional typed counts added without breaking older clients. */
  photoCount?: number;
  fileAttachmentCount?: number;
}

/** A prompt admitted before its canonical user entry exists, usually while
 * Pi performs automatic compaction during prompt preflight. */
export interface PendingPromptState {
  id: string;
  /** Additive for clients that want to suppress a stale pre-canonical row. */
  createdAt?: string;
  behavior?: "steer" | "followUp";
  text: string;
  /** Total uploaded items retained for rolling protocol compatibility. */
  attachmentCount: number;
  photoCount?: number;
  fileAttachmentCount?: number;
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
  /** Prompt admission awaiting its canonical user transcript entry. */
  pendingPrompt?: PendingPromptState;
  /** Gateway-owned manual compaction waiting for the active run to settle. */
  compactionQueued?: boolean;
  /** Effective runtime setting; optional for rolling protocol compatibility. */
  automaticCompactionEnabled?: boolean;
  transcript: TranscriptItem[];
  transcriptStart: number;
  transcriptTotal: number;
  streaming?: TranscriptItem;
  leafEntryId?: string;
  operation?: SessionOperationState;
  /** Exact Pi extension command handler currently admitted, independent of foreground agent work. */
  extensionCommand?: SessionOperationState;
  retry?: RetryState;
  toolExecutions: ToolExecutionState[];
  /** Bounded recent extension-owned run history. Live entries are also carried
   * on their owning toolExecution so progress can update without a snapshot. */
  extensionActivities?: ExtensionRunActivity[];
  extensionPresentation: ExtensionPresentationState;
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
