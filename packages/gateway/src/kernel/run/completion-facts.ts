import type { SessionManager } from "../pi/coding-agent.js";
import type { RunMarkerEvidence } from "./run-markers.js";

export type SessionAttentionRebindDisposition = "migrate" | "preserve" | "reset" | "discard";

export interface CanonicalAssistantCompletion {
  id: string;
  completedAt: string;
  operationId?: string;
}

type CanonicalCompletionEntry = {
  id: string;
  timestamp: string;
  type: string;
  message?: { role?: string; stopReason?: string };
};

export function successfulAssistantCompletion(
  entry: CanonicalCompletionEntry | undefined,
): CanonicalAssistantCompletion | undefined {
  if (entry?.type !== "message" || entry.message?.role !== "assistant") return undefined;
  if (entry.message.stopReason !== "stop" && entry.message.stopReason !== "length") return undefined;
  return { id: entry.id, completedAt: entry.timestamp };
}

/** Recover only the canonical completion owned by durable run-marker evidence. */
export function completionOwnedByMarker(
  manager: Pick<SessionManager, "getEntry">,
  marker: RunMarkerEvidence,
): CanonicalAssistantCompletion | undefined {
  if (marker.assistantCompletionId === undefined) return undefined;
  const completion = successfulAssistantCompletion(manager.getEntry(marker.assistantCompletionId));
  return completion ? { ...completion, operationId: marker.operationId } : undefined;
}


