import { createHash } from "node:crypto";
import {
  KNOWLEDGE_CURATION_MAX_BATCH_SUMMARY_CHARS, KNOWLEDGE_CURATION_MAX_ITEMS, KNOWLEDGE_CURATION_MAX_SUMMARY_CHARS,
  KnowledgeCurationRefusal,
  type KnowledgeCurationItem, type KnowledgeCurationJob, type KnowledgeCurationJobRequest, type KnowledgeCurationJobResponse,
  type KnowledgeCurationOperation, type KnowledgeCurationOutcome, type KnowledgeCurationRequest, type KnowledgeCurationResponse, type SourceCurationProducer,
} from "./knowledge-contract.js";

/** A curation item's own command identity. It is stable for one batch command
 * and one entry, so a replayed batch re-runs each item against its own receipt:
 * an item that committed before a crash replays instead of conflicting, and a
 * changed payload under the same batch command is refused per item. */
export function curationCommandId(base: string, recordId: string): string {
  const digest = createHash("sha256").update(`${base}\u0000${recordId}`).digest("hex").slice(0, 16);
  const prefix = `${base.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 72)}:${recordId.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 48)}`;
  return `${prefix}:${digest}`.slice(0, 160);
}

/** Batch-level shape. Per-item problems become per-item outcomes instead, so a
 * malformed item never discards the rest of the batch. */
export function validateCurationRequest(request: KnowledgeCurationRequest): void {
  if (!["summary", "tags", "verdict", "placement", "relation"].includes(request.operation)) throw new KnowledgeCurationRefusal("invalid-input", "Knowledge curation requires a supported operation");
  const producer = request.producer as SourceCurationProducer | undefined;
  if (!producer || typeof producer !== "object" || !["user", "agent", "connector", "import", "system"].includes(producer.actor as string)) throw new KnowledgeCurationRefusal("invalid-input", "Knowledge curation requires a producer actor");
  if (producer.model !== undefined && (typeof producer.model !== "string" || producer.model.length < 1 || producer.model.length > 200)) throw new KnowledgeCurationRefusal("invalid-input", "A producer model label is 1..200 characters");
  if (!Array.isArray(request.items) || request.items.length < 1 || request.items.length > KNOWLEDGE_CURATION_MAX_ITEMS) throw new KnowledgeCurationRefusal("invalid-input", `A curation batch carries 1..${KNOWLEDGE_CURATION_MAX_ITEMS} items`);
  if (new Set(request.items.map(item => item.recordId)).size !== request.items.length) throw new KnowledgeCurationRefusal("invalid-input", "A curation batch lists an entry more than once");
  if (request.operation === "summary") {
    let text = 0;
    for (const item of request.items) {
      if (item.summary === undefined) continue;
      if (typeof item.summary.text !== "string") throw new KnowledgeCurationRefusal("invalid-input", "Summary text must be a string");
      text += item.summary.text.length;
    }
    // One batch's read-back is bounded, so a page of summaries stays a small
    // response instead of a multi-hundred-kilobyte frame.
    if (text > KNOWLEDGE_CURATION_MAX_BATCH_SUMMARY_CHARS) throw new KnowledgeCurationRefusal("invalid-input", `A curation batch carries at most ${KNOWLEDGE_CURATION_MAX_BATCH_SUMMARY_CHARS} characters of summary text`);
  }
}

/** Item-level shape, checked before the store sees it, so an unusable item is
 * one reported outcome rather than an exception that abandons the batch. */
export function curationItemRefusal(operation: KnowledgeCurationOperation, item: KnowledgeCurationItem): { code: "invalid-input"; reason: string } | undefined {
  const record = (value: unknown, label: string, maximum: number): boolean => typeof value === "string" && value.length > 0 && value.length <= maximum && !/[\u0000-\u001f\u007f]/.test(value);
  if (!record(item.recordId, "record id", 200)) return { code: "invalid-input", reason: "A curation item requires a record id" };
  if (!record(item.expectedRevision, "revision", 80)) return { code: "invalid-input", reason: `Item ${item.recordId} requires the revision it was read at` };
  if (operation === "summary" && (item.summary === undefined || item.summary.text.trim().length === 0 || item.summary.text.length > KNOWLEDGE_CURATION_MAX_SUMMARY_CHARS)) {
    return { code: "invalid-input", reason: `Item ${item.recordId} requires summary text of 1..${KNOWLEDGE_CURATION_MAX_SUMMARY_CHARS} characters` };
  }
  if (operation === "tags" && !Array.isArray(item.tagIds)) return { code: "invalid-input", reason: `Item ${item.recordId} requires tagIds` };
  if (operation === "verdict" && item.verdict === undefined) return { code: "invalid-input", reason: `Item ${item.recordId} requires a verdict` };
  if (operation === "placement" && item.placement === undefined) return { code: "invalid-input", reason: `Item ${item.recordId} requires a placement` };
  if (operation === "relation" && item.relation === undefined) return { code: "invalid-input", reason: `Item ${item.recordId} requires a relation` };
  return undefined;
}

/** One item's typed failure as a batch outcome. An unexpected error is reported
 * as `unavailable` with its message rather than swallowed or rethrown: the rest
 * of the batch still has work to attempt. */
export function curationFailureOutcome(item: KnowledgeCurationItem, error: unknown): KnowledgeCurationOutcome {
  const message = error instanceof Error ? error.message : "Knowledge curation failed";
  if (error instanceof KnowledgeCurationRefusal) {
    return {
      recordId: item.recordId,
      status: error.code === "stale-revision" ? "conflict" : "failed",
      code: error.code,
      reason: message,
      ...(error.currentRevision ? { currentRevision: error.currentRevision } : {}),
    };
  }
  return { recordId: item.recordId, status: "failed", code: "unavailable", reason: message };
}

/** Terminal reason for a job that failed, kept typed for the caller. */
export function curationJobFailure(error: unknown, aborted: boolean, cancellationReason?: unknown): { code: KnowledgeCurationOutcome["code"] & string; reason: string } {
  if (error instanceof KnowledgeCurationRefusal) return { code: error.code, reason: error.message };
  if (aborted) return { code: "cancelled", reason: cancellationReason instanceof Error ? cancellationReason.message : "Knowledge curation job was cancelled" };
  return { code: "unavailable", reason: error instanceof Error ? error.message : "Knowledge curation job failed" };
}

export type KnowledgeCurationRunner = (signal: AbortSignal, cancel: (reason?: Error) => void) => Promise<{ revisionId: string }>;

interface JobEntry { job: KnowledgeCurationJob; controller: AbortController }

/** Owned background interpretation work. One entry per accepted command, so a
 * duplicate request observes the run it already started instead of starting a
 * second one. State is process-local by design: the durable outcome is the
 * committed revision, where a restart can only lose `running`. */
export class KnowledgeCurationJobs {
  private readonly jobs = new Map<string, JobEntry>();
  constructor(private readonly maximum = 64, private readonly deadlineMs = 120_000) {}

  start(input: { commandId: string; operation: KnowledgeCurationJob["operation"]; sourceId: string; run: KnowledgeCurationRunner }): KnowledgeCurationJob {
    const existing = this.jobs.get(input.commandId);
    if (existing) return { ...existing.job };
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(new Error("Knowledge curation job deadline exceeded")), this.deadlineMs);
    deadline.unref?.();
    const entry: JobEntry = { job: { commandId: input.commandId, operation: input.operation, sourceId: input.sourceId, status: "running", startedAt: new Date().toISOString() }, controller };
    this.jobs.set(input.commandId, entry);
    this.evict();
    void (async () => {
      try {
        const settled = await input.run(controller.signal, reason => controller.abort(reason));
        const { code: _code, reason: _reason, ...rest } = entry.job;
        entry.job = { ...rest, status: "done", finishedAt: new Date().toISOString(), revisionId: settled.revisionId };
      } catch (error) {
        const failure = curationJobFailure(error, controller.signal.aborted, controller.signal.reason);
        entry.job = { ...entry.job, status: "failed", finishedAt: new Date().toISOString(), code: failure.code, reason: failure.reason };
      } finally {
        clearTimeout(deadline);
      }
    })();
    return { ...entry.job };
  }

  observe(request: KnowledgeCurationJobRequest): KnowledgeCurationJobResponse {
    const limit = request.limit ?? 25;
    const jobs = [...this.jobs.values()].map(entry => ({ ...entry.job }))
      .filter(job => (request.commandId === undefined || job.commandId === request.commandId)
        && (request.sourceId === undefined || job.sourceId === request.sourceId)
        && (request.status === undefined || job.status === request.status))
      .sort((left, right) => right.startedAt.localeCompare(left.startedAt) || right.commandId.localeCompare(left.commandId));
    const page = jobs.slice(0, limit);
    return { jobs: page, running: jobs.filter(job => job.status === "running").length, failed: jobs.filter(job => job.status === "failed").length };
  }

  /** Shutdown and suspension release running work; each job's own owner settles
   * its work token, so a drain still waits for the real end of a generation. */
  cancelAll(reason: Error): void {
    for (const entry of this.jobs.values()) if (entry.job.status === "running") entry.controller.abort(reason);
  }

  get running(): number { return [...this.jobs.values()].filter(entry => entry.job.status === "running").length; }

  private evict(): void {
    if (this.jobs.size <= this.maximum) return;
    const settled = [...this.jobs.entries()].filter(([, entry]) => entry.job.status !== "running").sort(([, left], [, right]) => left.job.startedAt.localeCompare(right.job.startedAt));
    for (const [commandId] of settled) {
      if (this.jobs.size <= this.maximum) break;
      this.jobs.delete(commandId);
    }
  }
}

/** The agent-visible rendering of one batch: counts first, then one line per
 * item, so a 25-item batch stays readable instead of dumping its details. */
export function curationToolText(response: KnowledgeCurationResponse): string {
  const counts = new Map<string, number>();
  for (const outcome of response.outcomes) counts.set(outcome.status, (counts.get(outcome.status) ?? 0) + 1);
  const summary = [...counts.entries()].map(([status, count]) => `${count} ${status}`).join(", ") || "no items";
  const lines = response.outcomes.map(outcome => {
    const revision = outcome.revisionId ? ` revision=${outcome.revisionId}` : "";
    const current = outcome.currentRevision ? ` current=${outcome.currentRevision}` : "";
    const detail = outcome.reason ? `: ${outcome.reason.slice(0, 240)}` : "";
    return `- ${outcome.recordId} ${outcome.status}${outcome.code ? ` (${outcome.code})` : ""}${revision}${current}${detail}`;
  });
  return `Knowledge curation ${response.operation}: ${summary} (state revision ${response.stateRevision}).\n${lines.join("\n")}`;
}
