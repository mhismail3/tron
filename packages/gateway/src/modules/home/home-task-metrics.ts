import { GatewayError } from "../../errors.js";
import { homeTaskLineages } from "./home-task-lineage.js";
import type { HomeTaskRecord, HomeTaskStore } from "./home-task-store.js";
import { homeTaskPromptTokens } from "./home-task-spend.js";

export interface HomeTaskMetricsRequest {
  taskId?: string;
  from?: string;
  to?: string;
  limit?: number;
}

const unavailable = (reason: string) => ({ status: "unavailable" as const, value: null, reason });

/** A disposable projection of the existing task owner, not a second event ledger.
 * Retained check-ins are lower bounds: canonical history owns complete progress.
 * In particular, a terminal record's updatedAt is NOT a landed/settled timestamp. */
export async function readHomeTaskMetrics(store: HomeTaskStore, homeId: string, input: HomeTaskMetricsRequest) {
  for (const value of [input.from, input.to]) if (value !== undefined && (typeof value !== "string"
    || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/u.test(value)))
    throw new GatewayError("invalid_request", "task metrics: from/to must be UTC ISO timestamps ending in Z");
  const to = input.to === undefined ? Date.now() : Date.parse(input.to);
  const from = input.from === undefined ? to - 72 * 60 * 60 * 1000 : Date.parse(input.from);
  const limit = input.limit ?? 20;
  if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from < 0 || to <= from || to - from > 31 * 86400_000
    || !Number.isSafeInteger(limit) || limit < 1 || limit > 50)
    throw new GatewayError("invalid_request", "task metrics: from/to must define a positive UTC window of at most 31 days; limit is 1 to 50");
  const writes = store.writeCount;
  const epoch = await store.restoreEpoch();
  const records: HomeTaskRecord[] = [];
  for await (const record of store.records()) {
    if (records.length === 10_000) throw new GatewayError("conflict", "Task metrics scan exceeds 10000 records");
    records.push(record);
  }
  const currentEpoch = await store.restoreEpoch();
  if (writes !== store.writeCount || epoch !== currentEpoch)
    throw new GatewayError("conflict", "Task metrics evidence changed; read again");
  const groups = homeTaskLineages(records.filter(record => record.homeId === homeId));
  if (input.taskId && !groups.some(group => group.some(task => task.taskId === input.taskId)))
    throw new GatewayError("not_found", "No task with this id in this Home");
  // Cohort = roots delegated in [from,to). Ancestors and successors outside the
  // window remain visible for that cohort; this is current state, not time travel.
  const cohort = groups.filter(group => input.taskId ? group.some(task => task.taskId === input.taskId)
    : group[0]!.createdAt >= from && group[0]!.createdAt < to)
    .sort((a, b) => b[0]!.createdAt - a[0]!.createdAt || a[0]!.taskId.localeCompare(b[0]!.taskId));
  const rows = cohort.slice(0, limit).map(group => {
    const operations = group.filter(task => task.operationId !== null);
    const checkins = new Map<string, NonNullable<HomeTaskRecord["checkins"]>[number]>();
    const byId = new Map(operations.map(task => [task.taskId, task]));
    for (const task of group) for (const checkin of task.checkins ?? []) {
      const source = byId.get(checkin.taskId);
      if (!source || source.operationId !== checkin.operationId || source.sessionId !== checkin.sessionId) continue;
      const previous = checkins.get(checkin.id);
      if (previous && JSON.stringify(previous) !== JSON.stringify(checkin))
        throw new GatewayError("conflict", "Contradictory task metrics check-in");
      checkins.set(checkin.id, checkin);
    }
    const recent = [...checkins.values()].sort((a, b) => a.at.localeCompare(b.at) || a.id.localeCompare(b.id));
    const recordedSpend = operations.filter(task => task.spend !== null);
    return {
      taskId: group[0]!.taskId,
      delegatedAt: new Date(group[0]!.createdAt).toISOString(),
      operationRecords: group.length,
      operations: group.slice(-50).map(task => ({ taskId: task.taskId, admitted: task.operationId !== null,
        lifecycle: task.lifecycle, outcome: task.terminalEvidence?.outcome ?? null })),
      operationsTruncated: group.length > 50,
      resumes: operations.filter(task => task.resumes !== undefined).length,
      delegateToLandedMs: null,
      steerCount: null,
      waitingMs: { fullSuite: null, lock: null, reviewer: null },
      needsAttention: { status: "partial" as const, retainedCount: recent.filter(checkin => checkin.needsAttention === true).length,
        retained: recent.filter(checkin => checkin.needsAttention === true).slice(-50)
          .map(checkin => ({ id: checkin.id, taskId: checkin.taskId, at: checkin.at, blocker: checkin.blocker ?? null, attention: checkin.attention })) },
      parks: { status: "partial" as const, recordedCount: operations.filter(task => task.terminalEvidence?.outcome === "needs-input").length,
        recorded: operations.filter(task => task.terminalEvidence?.outcome === "needs-input").slice(-50)
          .map(task => ({ taskId: task.taskId, reason: task.terminalEvidence!.reason, detail: task.terminalEvidence!.detail ?? null })) },
      tokens: { status: recordedSpend.length === operations.length && operations.length > 0 ? "recorded" as const : "partial" as const,
        recordedOperations: recordedSpend.length, admittedOperations: operations.length,
        prompt: recordedSpend.length ? recordedSpend.reduce((sum, task) => sum + homeTaskPromptTokens(task.spend!), 0) : null,
        output: recordedSpend.length ? recordedSpend.reduce((sum, task) => sum + task.spend!.outputTokens, 0) : null },
      spendUsd: null,
    };
  });
  const completed = cohort.filter(group => group.some(task => task.operationId !== null) && group.every(task => task.lifecycle === "terminal"));
  const resumes = completed.map(group => group.filter(task => task.operationId !== null && task.resumes !== undefined).length);
  const result = {
    window: { from: new Date(from).toISOString(), to: new Date(to).toISOString(), cohort: input.taskId ? "named-lineage" : "root-created", observation: "current-records-not-historical-snapshot" },
    coverage: { scannedRecords: records.length, matchedLineages: cohort.length, returnedLineages: rows.length,
      more: cohort.length > rows.length, checkins: "retained-only", terminalTime: "unavailable" },
    scorecard: {
      approvalToMain: unavailable("Task records have no approved-intent/server-publication join"),
      deployLag: unavailable("Installation identities belong to the existing health scorecard"),
      mainReds: unavailable("Exact-SHA verify attempts belong to the existing health scorecard"),
      flakeRate: unavailable("Comparable repeated attempts belong to the existing health scorecard"),
      resumesPerTask: { status: "partial" as const, value: resumes.length ? resumes.reduce((a, b) => a + b, 0) / resumes.length : null,
        denominator: resumes.length, admittedResumes: resumes.reduce((a, b) => a + b, 0),
        reason: "Terminal recorded root lineages only; canonical history completeness is not checked" },
    },
    unavailable: { delegateToLandedMs: "No explicit publication endpoint in task records",
      steerCount: "Task records do not retain control events", waitingMs: "No typed wait start/end events; gaps and blocker prose are not durations",
      parks: "Only explicit needs-input outcomes; no inferred parks", spendUsd: "Task spend records tokens, not billing" },
    tasks: rows,
  };
  if (Buffer.byteLength(JSON.stringify(result)) > 256 * 1024)
    throw new GatewayError("conflict", "Task metrics page exceeds 256 KiB; request fewer lineages or one taskId");
  return result;
}

export type HomeTaskMetrics = Awaited<ReturnType<typeof readHomeTaskMetrics>>;
