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

export type AdministrativeDrainPhase = "idle" | "preparing" | "waiting" | "complete" | "failed";
export type AdministrativeDrainBlockerCategory =
  | "slot-admission"
  | "prompt-preflight"
  | "foreground-agent-operation"
  | "queued-mutation"
  | "compaction-export"
  | "detached-extension-run"
  | "terminal-receipt-persistence"
  | "extension-command-prompt-ui"
  | "administrative-provider-package-operation";

export interface AdministrativeDrainBlockerSummary {
  /** Per-drain opaque identity. It is not a session, run, path, or token ID. */
  id: string;
  category: AdministrativeDrainBlockerCategory;
  state: "active" | "settling" | "suspect";
  admittedAt?: string;
  ageMs?: number;
}

/** Bounded process-local diagnostic projection. It is never liveness authority. */
export interface AdministrativeDrainSnapshot {
  drainId: string;
  revision: number;
  phase: AdministrativeDrainPhase;
  startedAt?: string;
  lastProgressAt?: string;
  blockerCount: number;
  blockerCounts: Partial<Record<AdministrativeDrainBlockerCategory, number>>;
  oldestAdmissionAt?: string;
  oldestAdmissionAgeMs?: number;
  blockers: AdministrativeDrainBlockerSummary[];
  omittedCount: number;
  suspectProjectionCount: number;
}

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
  /** Gateway-canonical cross-client attention projection. Missing only during a rolling upgrade. */
  completionRevision?: number;
  attentionRevision?: number;
  isUnread?: boolean;
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
  completionRevision?: number;
  attentionRevision?: number;
  isUnread?: boolean;
}

export type ContentPart =
  | { id: string; ordinal: number; type: "text"; text: string; attachment?: { name: string; mimeType: string; size: number } }
  | { id: string; ordinal: number; thinkingRunOrdinal: number; type: "thinking"; text: string; redacted?: boolean }
  | { id: string; ordinal: number; type: "image"; mimeType: string; blobId: string }
  | {
      id: string;
      ordinal: number;
      type: "toolCall";
      toolCallId: string;
      name: string;
      /** Extension-authored human-readable label from Pi's registered tool definition. */
      label?: string;
      arguments: JsonValue;
      /** Gateway-owned active-turn identity. Equal values may share one display run. */
      toolSegmentId?: string;
      /** Disposable declaration metadata; never persisted to Pi JSONL. */
      groupId?: string;
      groupIndex?: number;
      groupCount?: number;
      groupFinalized?: boolean;
    };

interface TranscriptBase {
  id: string;
  parentId: string | null;
  timestamp: string;
}

export type TranscriptItem =
  | TranscriptBase & {
      kind: "message";
      role: "user" | "assistant" | "toolResult";
      /** Stable presentation identity for this runtime epoch. Canonical entry id remains authoritative. */
      presentationId: string;
      content: ContentPart[];
      provider?: string;
      modelId?: string;
      stopReason?: string;
      errorMessage?: string;
      toolCallId?: string;
      toolName?: string;
      /** Extension-authored human-readable label from the mounted runtime. */
      toolLabel?: string;
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
      /** Gateway-owned active-turn identity for an orphan canonical result. */
      toolSegmentId?: string;
      groupId?: string;
      groupIndex?: number;
      groupCount?: number;
      groupFinalized?: boolean;
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
      /** Producer-authored evidence that this custom message was delivered as
       * session input and caused or continued an agent turn. */
      sessionInput?: SessionInputMetadata;
    }
  | TranscriptBase & {
      kind: "customEntry";
      customType: string;
      data?: JsonValue;
    }
  | TranscriptBase & {
      kind: "compaction" | "branchSummary";
      /** Stable live-to-canonical presentation identity when the Gateway
       * observed the producing operation. Canonical entry id remains truth. */
      presentationId?: string;
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
  /** Bounded producer source attribution. This is required even when owner is present. */
  source: string;
  /** Exact opaque owner attribution captured at the extension boundary. */
  owner?: ExtensionOwner;
}

export interface SessionInputMetadata {
  source: "extension";
  trigger: "turn";
  /** Exact extension attribution when the callback or registered renderer
   * supplied one. Absence remains unknown rather than inferred from text. */
  origin?: ExtensionToolOrigin;
}

export type ExtensionRunStatus = "running" | "completed" | "failed";

/** Rich lifecycle state. `status` remains the coarse compatibility field above. */
export type ExtensionRunLifecycleState =
  | "queued" | "running" | "paused" | "completed" | "failed" | "stopped" | "rejected" | "unknown";
export type ExtensionRunAttention = "none" | "activeLongRunning" | "needsAttention";
export type ExtensionRunVisibility = "current" | "recent" | "historical" | "unknown";

export interface ExtensionRunLifecycle {
  version: 1;
  state: ExtensionRunLifecycleState;
  attention: ExtensionRunAttention;
  /** Monotonic Gateway projection sequence, not producer wall time. */
  sequence: number;
  observedAt: string;
  producerUpdatedAt?: string;
  terminalAt?: string;
  recentUntil?: string;
  visibility?: ExtensionRunVisibility;
  remainingMs?: number;
}

/** Structured, bounded progress emitted by an extension-owned delegated run.
 * This is intentionally presentation-neutral: native clients may render it
 * as a live card while the extension remains the authority for execution. */
export interface ExtensionRunChild {
  id: string;
  /** Exact producer identity. Absent when `id` is only a compatibility display fallback. */
  producerId?: string;
  label: string;
  /** Opaque validated child-session identity. Absolute paths never cross the wire. */
  childSessionRef?: string;
  /** Coarse compatibility status retained for older native clients. */
  status: ExtensionRunStatus;
  /** Rich delegated-run state, independent of the parent tool status. */
  lifecycle?: ExtensionRunLifecycleState;
  attention?: ExtensionRunAttention;
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
  /** Compatibility row identity. New clients use activityId when present. */
  id: string;
  /** Deterministic identity derived from canonical session + real tool call. */
  activityId?: string;
  runId?: string;
  toolCallId: string;
  source: ExtensionToolOrigin;
  title: string;
  mode?: string;
  status: ExtensionRunStatus;
  startedAt: string;
  updatedAt: string;
  completedAt?: string;
  lastActivityAt?: string;
  currentTool?: string;
  currentToolStartedAt?: string;
  currentPath?: string;
  toolCount?: number;
  turnCount?: number;
  durationMs?: number;
  output?: string;
  children: ExtensionRunChild[];
  /** Additive rich lifecycle projection; absent on old Gateway snapshots. */
  lifecycle?: ExtensionRunLifecycle;
}

export interface ExtensionActivityDelta {
  activity: ExtensionRunActivity;
  liveActivityRevision: number;
  extensionActivityAsOf: string;
}

export type SessionProcessKind = "command" | "subagent";
export type SessionProcessExecutionMode = "foreground" | "background" | "synchronous" | "asynchronous" | "unknown";
export type SessionProcessSource = "mainAssistant" | "delegatedAgent" | "admittedExtension";
export type SessionProcessState =
  | "queued" | "running" | "paused"
  | "completed" | "failed" | "stopped" | "rejected" | "interrupted" | "unknown";
export type SessionProcessAttention = "none" | "activeLongRunning" | "needsAttention";
export type SessionProcessVisibility = "active" | "recent" | "historical" | "unknown";

export interface SessionProcessLifecycle {
  version: 1;
  state: SessionProcessState;
  attention: SessionProcessAttention;
  /** Monotonic within one runtime's process projection. */
  sequence: number;
  observedAt: string;
  producerUpdatedAt?: string;
  terminalAt?: string;
  recentUntil?: string;
}

/** Package-agnostic bounded projection of process activity Tron already observes.
 * It never implies that Tron owns or can control the underlying process. */
export interface SessionProcessActivity {
  version: 1;
  processId: string;
  kind: SessionProcessKind;
  executionMode: SessionProcessExecutionMode;
  source: SessionProcessSource;
  parentProcessId?: string;
  lifecycle: SessionProcessLifecycle;
  visibility: SessionProcessVisibility;
  startedAt?: string;
  /** Bounded producer/canonical elapsed time; absent when no authoritative interval exists. */
  durationMs?: number;
  title: string;
  command?: string;
  currentTool?: string;
  currentPathBasename?: string;
  outputTail?: string;
  outputTruncated: boolean;
  toolCount?: number;
  turnCount?: number;
  childCount?: number;
  toolCallId?: string;
  runId?: string;
  childSessionRef?: string;
}

export interface SessionProcessOverview {
  version: 1;
  revision: number;
  asOf: string;
  activeCount: number;
  recentCount: number;
  problemCount: number;
  visibility: "hidden" | "active" | "recent";
  nearestExpiry?: string;
  omissions?: { count: number; bytes: number; reason: "count" | "bytes" | "countAndBytes" };
}

export interface SessionProcessDelta {
  /** One exact upsert. A removal-only frame deliberately omits it. */
  activity?: SessionProcessActivity;
  /** Exact identities removed or re-keyed by the same authoritative replacement. */
  removedProcessIds?: string[];
  processRevision: number;
  processAsOf: string;
  overview: SessionProcessOverview;
}

export interface SessionProcessHistoryPage {
  activities: SessionProcessActivity[];
  historyRevision: string;
  nextCursor?: string;
  omissions?: { count: number; bytes: number; reason: "bytes" | "countAndBytes" };
}

export interface ProcessTranscriptLease {
  leaseId: string;
  processId: string;
  childSessionRef: string;
  revision: string;
  page: {
    items: TranscriptItem[];
    start: number;
    end: number;
    total: number;
    nextEntryId?: string;
    leafEntryId?: string;
  };
}

export interface ToolExecutionState {
  toolCallId: string;
  toolName: string;
  /** Extension-authored human-readable label from Pi's registered tool definition. */
  toolLabel?: string;
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
  /** Gateway-owned active-turn identity. Equal values may share one display run. */
  toolSegmentId?: string;
  /** Finalized declaration metadata, bounded to the active Gateway runtime. */
  groupId?: string;
  groupIndex?: number;
  groupCount?: number;
  groupFinalized?: boolean;
  /** Optional structured extension-owned run projection for native clients. */
  extensionActivity?: ExtensionRunActivity;
  /** Activity projection facts carried with live frames for stale-frame admission. */
  liveActivityRevision?: number;
  extensionActivityAsOf?: string;
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

interface ExtensionInteractionBase {
  id: string;
  hostEpoch: string;
  presentationRevision: number;
  title: string;
  message?: string;
  expiresAt?: string;
}

/** Method-discriminated in Gateway code while retaining the existing flat JSON shape. */
export type ExtensionInteraction =
  | (ExtensionInteractionBase & {
      method: "select";
      options: string[];
      placeholder?: never;
      prefill?: never;
      /** Additive descriptor; old clients ignore it and answer the primitive dialog. */
      questionnaire?: ExtensionQuestionnaireDescriptor;
    })
  | (ExtensionInteractionBase & {
      method: "confirm";
      options?: never;
      placeholder?: never;
      prefill?: never;
      questionnaire?: never;
    })
  | (ExtensionInteractionBase & {
      method: "input";
      options?: never;
      placeholder?: string;
      prefill?: string;
      /** Additive descriptor; old clients ignore it and answer the primitive dialog. */
      questionnaire?: ExtensionQuestionnaireDescriptor;
    })
  | (ExtensionInteractionBase & {
      method: "editor";
      options?: never;
      placeholder?: string;
      prefill?: string;
      questionnaire?: never;
    });

export type ExtensionInteractionInput =
  | Omit<Extract<ExtensionInteraction, { method: "select" }>, "id" | "hostEpoch" | "presentationRevision" | "expiresAt">
  | Omit<Extract<ExtensionInteraction, { method: "confirm" }>, "id" | "hostEpoch" | "presentationRevision" | "expiresAt">
  | Omit<Extract<ExtensionInteraction, { method: "input" }>, "id" | "hostEpoch" | "presentationRevision" | "expiresAt">
  | Omit<Extract<ExtensionInteraction, { method: "editor" }>, "id" | "hostEpoch" | "presentationRevision" | "expiresAt">;

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

export interface PromptAttachmentState {
  /** Gateway-owned media identity (`upload:<uuid>` for uploads); content remains out of snapshot JSON. */
  id: string;
  name: string;
  mimeType: string;
  size: number;
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
  /** Bounded exact descriptors added without breaking older clients. */
  attachments?: PromptAttachmentState[];
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
  /** Bounded exact descriptors added without breaking older clients. */
  attachments?: PromptAttachmentState[];
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
  extensionActivityOmissions?: { count: number; bytes: number; reason: "count" | "bytes" | "countAndBytes" };
  /** Monotonic Gateway revision for disposable current/recent activity. */
  liveActivityRevision: number;
  /** Wall-clock observation time for the activity projection, including expiry. */
  extensionActivityAsOf: string;
  /** Additive unified process projection. Old clients ignore these fields. */
  processActivities?: SessionProcessActivity[];
  processOverview?: SessionProcessOverview;
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
  resourceSource?: string;
  resourceScope?: "user" | "project" | "temporary";
  resourceOrigin?: "package" | "top-level";
}

export interface CommandDetail extends CommandInfo {
  content?: string;
  contentBytes?: number;
  contentTruncated?: boolean;
}

export interface ProtocolEvent {
  type: "event";
  topic: string;
  sessionId?: string;
  payload: JsonValue;
}
