import type { AgentSession } from "../pi/coding-agent.js";
import type { BlobStore } from "../../sessions/blob-store.js";
import type { ExtensionRunActivity, SessionProcessActivity, SessionProcessHistoryPage, ChatSemanticMetadata } from "../../protocol/types.js";
import type { ForkBoundaryAnchor } from "../../sessions/fork-boundary.js";
import { GatewayError } from "../../errors.js";
import { projectTranscriptPage, projectTranscriptPageAfter, type TranscriptPage, type ToolProjectionMetadata } from "./projection.js";
import { listExtensionActivityHistory, extensionActivityHistoryRevision, extensionActivityReceipts, extensionReceiptActivity, type ExtensionActivityHistoryPage } from "../../sessions/extension-activity-history.js";
import { listProcessHistory, processHistoryDetail } from "./process-activity.js";

export interface PageSource {
  assertNoTrustReload(): void;
  runtimeGeneration: string;
  runtime: { session: AgentSession };
  dependencies: { blobs: BlobStore };
  toolMetadata: ReadonlyMap<string, ToolProjectionMetadata>;
  presentationIDs: ReadonlyMap<string, string>;
  toolLabels(): ReadonlyMap<string, string>;
  bashMetadata: ReadonlyMap<string, ToolProjectionMetadata>;
  forkBoundary: ForkBoundaryAnchor | undefined;
  internalWakeSemantic(entryId: string): ChatSemanticMetadata | undefined;
  id: string;
  extensionActivities: ReadonlyMap<string, ExtensionRunActivity>;
}

export function transcriptPageAfter(source: PageSource,
  after: number,
  expectedPreviousEntryId?: string,
  expectedRuntimeGeneration?: string,
  expectedLeafEntryId?: string,
): TranscriptPage {
  source.assertNoTrustReload();
  if (expectedRuntimeGeneration !== undefined && expectedRuntimeGeneration !== source.runtimeGeneration) {
    throw new GatewayError("conflict", "The session runtime changed while loading history. Refresh the session and try again.", true);
  }
  const leafEntryId = source.runtime.session.sessionManager.getLeafId();
  if (expectedLeafEntryId !== undefined && expectedLeafEntryId !== leafEntryId) {
    throw new GatewayError("conflict", "The session branch changed while loading history. Refresh the session and try again.", true);
  }
  try {
    return {
      ...projectTranscriptPageAfter(source.runtime.session.sessionManager, source.dependencies.blobs, after,
        undefined, expectedPreviousEntryId, source.toolMetadata, source.presentationIDs, source.toolLabels(),
        source.bashMetadata, source.forkBoundary),
      runtimeGeneration: source.runtimeGeneration,
      ...(leafEntryId ? { leafEntryId } : {}),
    };
  } catch (error) {
    if (error instanceof Error && error.message.includes("anchor changed")) {
      throw new GatewayError("conflict", "The session branch changed while loading history. Refresh the session and try again.", true);
    }
    throw error;
  }
}

export function transcriptPage(source: PageSource,
  before?: number,
  expectedNextEntryId?: string,
  expectedRuntimeGeneration?: string,
  expectedLeafEntryId?: string,
  branchCut?: import("../pi/coding-agent.js").SessionEntry[],
): TranscriptPage {
  source.assertNoTrustReload();
  if (expectedRuntimeGeneration !== undefined && expectedRuntimeGeneration !== source.runtimeGeneration) {
    throw new GatewayError("conflict", "The session runtime changed while loading history. Refresh the session and try again.", true);
  }
  const leafEntryId = source.runtime.session.sessionManager.getLeafId();
  if (expectedLeafEntryId !== undefined && expectedLeafEntryId !== leafEntryId) {
    throw new GatewayError("conflict", "The session branch changed while loading history. Refresh the session and try again.", true);
  }
  try {
    const page = projectTranscriptPage(
        source.runtime.session.sessionManager,
        source.dependencies.blobs,
        before,
        undefined,
        expectedNextEntryId,
        source.toolMetadata,
        source.presentationIDs,
        source.toolLabels(),
        source.bashMetadata,
        source.forkBoundary,
        branchCut,
      );
    return {
      ...page,
      // Exact presentation binding precedes receipt I/O. Retain the owning
      // invocation's semantics in that interval without a second binding map.
      items: page.items.map(item => {
        const semantic = item.kind === "message" && item.role === "user" && !item.semantic?.invocationId
          ? source.internalWakeSemantic(source.presentationIDs.get(item.id) ?? item.id) : undefined;
        return semantic ? { ...item, semantic } : item;
      }),
      runtimeGeneration: source.runtimeGeneration,
      ...(leafEntryId ? { leafEntryId } : {}),
    };
  } catch (error) {
    if (error instanceof Error && error.message.includes("anchor changed")) {
      throw new GatewayError("conflict", "The session branch changed while loading history. Refresh the session and try again.", true);
    }
    throw error;
  }
}

/** Canonical reserved receipts are read independently of transcript/tree
 * projection. The page revision includes entry/parent identity so branch
 * changes invalidate cursors without creating a second history store. */
export function extensionActivityHistory(source: PageSource, cursor?: string, limit = 25, filter?: { ownerId?: string; runId?: string; state?: "completed" | "failed" | "stopped" | "rejected" }): ExtensionActivityHistoryPage {
  source.assertNoTrustReload();
  return listExtensionActivityHistory(
    source.runtime.session.sessionManager.getEntries(),
    source.id,
    cursor,
    limit,
    source.runtime.session.sessionManager.getLeafId() ?? "root",
    filter,
  );
}

export function extensionActivityDetail(source: PageSource, activityId: string, expectedHistoryRevision?: string): ExtensionRunActivity | undefined {
  source.assertNoTrustReload();
  if (expectedHistoryRevision !== undefined) {
    const actual = extensionActivityHistoryRevision(source.runtime.session.sessionManager.getEntries(), source.id, source.runtime.session.sessionManager.getLeafId() ?? "root");
    if (actual !== expectedHistoryRevision) throw new GatewayError("conflict", "Extension activity generation changed; refresh history", true);
  }
  const receipts = extensionActivityReceipts(source.runtime.session.sessionManager.getEntries(), source.id);
  const receipt = receipts.find((entry) => entry.receipt.activityId === activityId)?.receipt;
  if (receipt) return extensionReceiptActivity(receipt);
  return [...source.extensionActivities.values()].find((activity) => (activity.activityId ?? activity.id) === activityId);
}

export function processHistory(source: PageSource, cursor?: string, limit = 25, filter?: { kind?: "command" | "subagent"; state?: SessionProcessActivity["lifecycle"]["state"] }): SessionProcessHistoryPage {
  source.assertNoTrustReload();
  return listProcessHistory(source.runtime.session.sessionManager, cursor, limit, filter);
}

export function processDetail(source: PageSource, processId: string, expectedHistoryRevision?: string): SessionProcessActivity | undefined {
  source.assertNoTrustReload();
  try {
    // History detail is canonical-only. Mutable mounted state has its own
    // process revision and must never be returned under a history revision.
    return processHistoryDetail(source.runtime.session.sessionManager, processId, expectedHistoryRevision);
  } catch (error) {
    if (error instanceof Error && error.message.includes("generation conflict")) {
      throw new GatewayError("conflict", "Process history generation changed; refresh history", true);
    }
    throw error;
  }
}
