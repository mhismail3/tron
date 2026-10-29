import type { ToolDisplayProjection } from "./tool-result.js";
import type { AgentMessage } from "../pi/agent-core.js";
import type { AgentSession } from "../pi/coding-agent.js";
import type { BlobStore } from "../../sessions/blob-store.js";
import type { SessionSnapshot, SessionPhase, ToolExecutionState, ExtensionRunActivity, SessionProcessActivity, SessionProcessOverview } from "../../protocol/types.js";
import { invocationReceipts } from "../receipts/invocation-receipts.js";
import { canonicalToolResultCallIDsFromBranch, fitSessionSnapshot, projectMessage, type TranscriptPage } from "./projection.js";
import { boundExtensionActivities } from "./extension-run-projection.js";

/** Synchronous reads of run-owned facts. No run state or canonical entries are copied here. */
export interface SnapshotSource {
  displayProjection: ToolDisplayProjection;
  assertNoTrustReload(): void;
  runtime: { session: AgentSession; diagnostics: readonly { type: string; message: string }[] };
  ensureAgentProjection(): void;
  revision: number;
  latestCacheHitRate(): number | undefined;
  contextPolicies: { get(session: AgentSession): { snapshot(): SessionSnapshot["contextWindowPolicy"] } | undefined };
  compactionPolicies: { get(session: AgentSession): { snapshot(): SessionSnapshot["compactionPolicy"] } | undefined };
  streamPresentationId: string | undefined;
  latestStreamingMessage: AgentMessage | undefined;
  canonicalizedStreamingMessages: WeakSet<object>;
  captureStreamIdentity(message: AgentMessage): void;
  streamAnchorId: string | null | undefined;
  streamStartedAt: string | undefined;
  finalizedStreamPresentationId: string | undefined;
  dependencies: { blobs: BlobStore; archivedAt(sessionId: string): string | undefined };
  toolLabels(): ReadonlyMap<string, string>;
  activeToolSegmentId(): string | undefined;
  transcriptPage(before?: number, next?: string, generation?: string, leaf?: string, branch?: import("../pi/coding-agent.js").SessionEntry[]): TranscriptPage;
  pendingExtensionCommand: SessionSnapshot["operation"];
  id: string;
  ui: { presentation: { state(): { pendingInteractions: readonly unknown[] } }; state(): SessionSnapshot["extensionPresentation"] };
  projectedQueue(): SessionSnapshot["queuedItems"];
  currentProcessProjection(): { activities: SessionProcessActivity[]; overview: SessionProcessOverview };
  isAgentAdmissionSettling: boolean;
  phase: SessionPhase;
  effectivePhase: SessionPhase;
  runtimeGeneration: string;
  configurationBlocker(): SessionSnapshot["configurationBlocker"];
  isHomeChapter: boolean;
  queueRevision: number;
  pendingPrompt: SessionSnapshot["pendingPrompt"];
  pendingManualCompaction: unknown;
  operation: SessionSnapshot["operation"];
  retry: SessionSnapshot["retry"];
  toolExecutions: ReadonlyMap<string, ToolExecutionState>;
  toolProgressWire(tool: ToolExecutionState): ToolExecutionState;
  extensionActivities: ReadonlyMap<string, ExtensionRunActivity>;
  extensionActivityVisibility(activity: ExtensionRunActivity): "current" | "recent" | "historical" | "unknown";
  extensionActivityWire(activity: ExtensionRunActivity): ExtensionRunActivity;
  liveActivityRevision: number;
  extensionActivityAsOf: string;
}

export class SnapshotProjection {
  /** Snapshot-derived SDK scans are exact but need not repeat while the
   * RuntimeSlot revision is unchanged. A canonical event/rebind/branch change
   * increments revision before publication, naturally invalidating this cut. */
  private derived: {
    revision: number;
    model: AgentSession["model"];
    contextWindow: number | undefined;
    stats: ReturnType<AgentSession["getSessionStats"]>;
    latestCacheHitRate?: number;
  } | undefined;

  /** The snapshot body. `snapshot` attributes it to the request that asked for
   * it; a state change with no request measures it where it publishes. */
  build(source: SnapshotSource, sequence: number): SessionSnapshot {
    source.assertNoTrustReload();
    const session = source.runtime.session;
    source.ensureAgentProjection();
    const derived = this.derived?.revision === source.revision
      && this.derived.model === session.model
      && this.derived.contextWindow === session.model?.contextWindow
      ? this.derived
      : (() => {
          const stats = session.getSessionStats();
          const latestCacheHitRate = source.latestCacheHitRate();
          const computed = {
            revision: source.revision,
            model: session.model,
            contextWindow: session.model?.contextWindow,
            stats,
            ...(latestCacheHitRate === undefined ? {} : { latestCacheHitRate }),
          };
          this.derived = computed;
          return computed;
        })();
    const contextUsage = derived.stats.contextUsage;
    const contextWindowPolicy = source.contextPolicies.get(session)?.snapshot();
    const compactionPolicy = source.compactionPolicies.get(session)?.snapshot();
    const stats = derived.stats;
    const latestCacheHitRate = derived.latestCacheHitRate;
    // Pi exposes streamingMessage before an async message_start hook returns,
    // so the SDK object may establish the initial Gateway identity. Once that
    // exact object is canonically bound, however, Pi can retain it briefly;
    // never let a snapshot recreate a second stream ID from that stale value.
    const sdkStreamingMessage = session.state.streamingMessage;
    const streamingMessage = source.streamPresentationId
      ? (sdkStreamingMessage ?? source.latestStreamingMessage)
      : sdkStreamingMessage && !source.canonicalizedStreamingMessages.has(sdkStreamingMessage)
        ? sdkStreamingMessage
        : undefined;
    const streaming = streamingMessage
      ? (() => {
        source.captureStreamIdentity(streamingMessage);
        return projectMessage(source.displayProjection,
          "streaming",
          source.streamAnchorId ?? null,
          source.streamStartedAt ?? new Date().toISOString(),
          streamingMessage,
          source.dependencies.blobs,
          undefined,
          source.streamPresentationId,
          source.finalizedStreamPresentationId === source.streamPresentationId,
          source.toolLabels(),
          undefined,
          source.activeToolSegmentId(),
        );
      })()
      : undefined;
    // One synchronous branch cut supplies both the bounded page and the
    // paged-out tool-result ownership check. Neither projection is cached; Pi
    // remains authoritative and the cut is discarded after this snapshot.
    const canonicalBranch = session.sessionManager.getBranch();
    const canonicalTranscriptPage = source.transcriptPage(undefined, undefined, undefined, undefined, canonicalBranch);
    // A replacement keeps its origin's live command, and the fork copies that
    // command's start row under the origin's identity. Only a start receipt this
    // session wrote may project the live lifecycle; the inherited row keeps its
    // stored state while the origin owns the terminal receipt.
    const liveCommand = source.pendingExtensionCommand;
    const liveCommandOwned = liveCommand !== undefined && invocationReceipts(canonicalBranch, source.id)
      .some(receipt => receipt.receiptKind === "start" && receipt.operationId === liveCommand.id);
    const liveCommandLifecycle = source.ui.presentation.state().pendingInteractions.length > 0
      ? "waitingForInput" as const
      : "running" as const;
    const transcriptPage: TranscriptPage = liveCommand && liveCommandOwned
      ? {
          ...canonicalTranscriptPage,
          items: canonicalTranscriptPage.items.map(item =>
            item.semantic?.kind === "command"
              && item.semantic.operationId === liveCommand.id
              ? { ...item, semantic: { ...item.semantic, lifecycle: liveCommandLifecycle } }
              : item),
        }
      : canonicalTranscriptPage;
    // transcriptPage is intentionally bounded; use the same full canonical
    // branch cut for ownership so paged-out results cannot leave a duplicate
    // runtime row.
    const canonicalToolResultIDs = canonicalToolResultCallIDsFromBranch(canonicalBranch);
    const queuedItems = source.projectedQueue();
    const processProjection = source.currentProcessProjection();
    // Compaction cannot take Agent input, but the Gateway queues it until the
    // summary settles, so clients may still request steer/follow-up delivery.
    const acceptsQueuedPrompts = (session.isStreaming && !source.isAgentAdmissionSettling)
      || source.phase === "compacting";
    const activeToolSegmentId = acceptsQueuedPrompts && source.effectivePhase === "running"
      ? source.activeToolSegmentId()
      : undefined;
    // Archive state is not canonical session content: it is read from its owner
    // for each snapshot so an archive commit never has to reach into the slot.
    const archivedAt = source.dependencies.archivedAt(source.id);
    // Canonical receipts are authoritative after runtime recreation; live maps
    // only enrich the current projection and never replace persisted facts.
    return fitSessionSnapshot({
      sessionId: session.sessionId,
      runtimeGeneration: source.runtimeGeneration,
      revision: source.revision,
      eventSequence: sequence,
      phase: source.effectivePhase,
      // Phase is presentation state; Pi streaming is the exact authority for
      // whether a new prompt can request steer/follow-up delivery right now.
      acceptsQueuedPrompts,
      configurationBlocker: source.configurationBlocker(),
      // Home is a role, not a generated conversation title. Never rewrite its canonical name or ID.
      ...(source.isHomeChapter ? { name: "Home" } : session.sessionName ? { name: session.sessionName } : {}),
      cwd: session.sessionManager.getCwd(),
      ...(session.sessionManager.getHeader()?.parentSession ? { parentSessionId: session.sessionManager.getHeader()!.parentSession } : {}),
      ...(session.model ? { model: { provider: session.model.provider, id: session.model.id } } : {}),
      thinkingLevel: session.thinkingLevel,
      availableThinkingLevels: session.getAvailableThinkingLevels(),
      ...(contextUsage ? { contextUsage } : {}),
      ...(contextWindowPolicy ? { contextWindowPolicy } : {}),
      ...(compactionPolicy ? { compactionPolicy } : {}),
      stats: {
        userMessages: stats.userMessages,
        assistantMessages: stats.assistantMessages,
        toolCalls: stats.toolCalls,
        toolResults: stats.toolResults,
        totalMessages: stats.totalMessages,
        tokens: stats.tokens,
        ...(latestCacheHitRate === undefined ? {} : { latestCacheHitRate }),
        cost: stats.cost,
      },
      queueRevision: source.queueRevision,
      queuedItems,
      ...(source.pendingPrompt ? { pendingPrompt: source.pendingPrompt } : {}),
      compactionQueued: source.pendingManualCompaction !== undefined,
      automaticCompactionEnabled: session.autoCompactionEnabled,
      transcript: transcriptPage.items,
      transcriptStart: transcriptPage.start,
      transcriptTotal: transcriptPage.total,
      ...(streaming ? { streaming } : {}),
      ...(session.sessionManager.getLeafId() ? { leafEntryId: session.sessionManager.getLeafId()! } : {}),
      ...(archivedAt === undefined ? {} : { archivedAt }),
      ...(source.operation ? { operation: source.operation } : {}),
      ...(source.retry ? { retry: source.retry } : {}),
      ...(canonicalTranscriptPage.forkBoundary ? { forkBoundary: canonicalTranscriptPage.forkBoundary } : {}),
      ...(activeToolSegmentId ? { activeToolSegmentId } : {}),
      toolExecutions: [...source.toolExecutions.values()]
        .filter((tool) => !canonicalToolResultIDs.has(tool.toolCallId))
        .filter((tool) => source.effectivePhase === "running" || tool.status !== "running")
        .sort((left, right) => left.order - right.order)
        .map((tool) => source.toolProgressWire(tool)),
      ...(() => {
        const visible = [...source.extensionActivities.values()]
          .map((activity) => ({ activity, visibility: source.extensionActivityVisibility(activity) }))
          .filter(({ visibility }) => visibility === "current" || visibility === "recent")
          // Current work is always retained ahead of recent terminal rows when
          // count or byte bounds force omission.
          .sort((left, right) => {
            const bucket = (visibility: string) => visibility === "current" ? 0 : 1;
            return bucket(left.visibility) - bucket(right.visibility)
              || right.activity.updatedAt.localeCompare(left.activity.updatedAt);
          })
          .map(({ activity }) => source.extensionActivityWire(activity));
        const bounded = boundExtensionActivities(visible);
        return bounded.activities.length > 0 || bounded.omittedCount > 0
          ? {
              ...(bounded.activities.length > 0 ? { extensionActivities: bounded.activities } : {}),
              ...(bounded.omittedCount > 0 ? { extensionActivityOmissions: {
                count: bounded.omittedCount,
                bytes: bounded.omittedBytes,
                reason: bounded.hitCount && bounded.hitBytes ? "countAndBytes" : bounded.hitCount ? "count" : "bytes",
              } } : {}),
            }
          : {};
      })(),
      liveActivityRevision: source.liveActivityRevision,
      extensionActivityAsOf: source.extensionActivityAsOf,
      ...(processProjection.activities.length > 0 ? { processActivities: processProjection.activities } : {}),
      processOverview: processProjection.overview,
      extensionPresentation: source.ui.state(),
      diagnostics: source.runtime.diagnostics.map((diagnostic) => ({ type: diagnostic.type, message: diagnostic.message })),
    });
  }

}
