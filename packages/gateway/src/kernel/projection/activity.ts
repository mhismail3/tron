import type { ExtensionRunActivity, SessionProcessActivity, SessionProcessOverview, ToolExecutionState } from "../../protocol/types.js";
import type { ExtensionActivityRecency } from "../../sessions/extension-activity-recency.js";
import type { ProcessActivityRecency } from "./process-activity-recency.js";
import { boundProcessActivities, processOverview } from "./process-activity.js";

/** Activity producers/expiry remain run-owned; these reads only bound wire views. */
export interface ActivitySource {
  processActivities: ReadonlyMap<string, SessionProcessActivity>;
  extensionActivities: ReadonlyMap<string, ExtensionRunActivity>;
  dependencies: { processActivityRecency: ProcessActivityRecency; extensionActivityRecency: ExtensionActivityRecency };
  processRevision: number;
  processAsOf: string;
  liveActivityRevision: number;
  extensionActivityAsOf: string;
  measureToolDuration(toolCallId: string, startedAt: string, completedAt: string, now: number): number;
}

export function currentProcessProjection(source: ActivitySource): { activities: SessionProcessActivity[]; overview: SessionProcessOverview } {
  const visible = [...source.processActivities.values()]
    .map((activity) => source.dependencies.processActivityRecency.wire(activity))
    .filter((activity) => activity.visibility === "active" || activity.visibility === "recent");
  const bounded = boundProcessActivities(visible);
  const omissions = bounded.omittedCount > 0 ? {
    count: bounded.omittedCount,
    bytes: bounded.omittedBytes,
    reason: bounded.hitCount && bounded.hitBytes ? "countAndBytes" as const : bounded.hitCount ? "count" as const : "bytes" as const,
  } : undefined;
  const extensionChildOmissions = [...source.extensionActivities.values()].reduce<{ children: number; byteLimitExceeded: boolean } | undefined>((total, activity) => {
    const current = activity.lifecycleOmissions;
    if (!current) return total;
    return {
      children: (total?.children ?? 0) + current.children,
      byteLimitExceeded: Boolean(total?.byteLimitExceeded || current.byteLimitExceeded),
    };
  }, undefined);
  return {
    activities: bounded.activities,
    overview: {
      ...processOverview(visible, source.processRevision, source.processAsOf, omissions),
      ...(extensionChildOmissions ? { extensionChildOmissions } : {}),
    },
  };
}

export function toolProgressWire(source: ActivitySource, state: ToolExecutionState): ToolExecutionState {
  // Running duration is sampled at delivery time. This keeps reconnect and
  // delayed/coalesced frames current even when the tool emits no output;
  // clients then advance the sample locally with a monotonic clock.
  const sampled = state.status === "running"
    ? {
        ...state,
        durationMs: Math.max(
          state.durationMs ?? 0,
          source.measureToolDuration(
            state.toolCallId,
            state.startedAt,
            new Date().toISOString(),
            performance.now()
          )
        ),
      }
    : state;
  return sampled.extensionActivity
    ? { ...sampled, liveActivityRevision: source.liveActivityRevision, extensionActivityAsOf: source.extensionActivityAsOf }
    : sampled;
}

export function extensionActivityWire(source: ActivitySource, activity: ExtensionRunActivity): ExtensionRunActivity {
  if (!activity.lifecycle) return activity;
  const recency = source.dependencies.extensionActivityRecency.visibility(activity);
  return {
    ...activity,
    lifecycle: {
      ...activity.lifecycle,
      visibility: recency.visibility,
      ...(recency.remainingMs === undefined ? {} : { remainingMs: recency.remainingMs }),
    },
  };
}

export function extensionActivityVisibility(source: ActivitySource, activity: ExtensionRunActivity): "current" | "recent" | "historical" | "unknown" {
  return source.dependencies.extensionActivityRecency.visibility(activity).visibility;
}
