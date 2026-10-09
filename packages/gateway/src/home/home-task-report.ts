import { Type } from "@earendil-works/pi-ai";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import { AsyncMutex } from "../util/async-mutex.js";

export const HOME_TASK_MARKER = "tron-home-task";
export const HOME_TASK_REPORT = "tron-home-task-report";
export interface HomeTaskWorkerIdentity {
  taskId: string;
  intentRevision: number;
  homeId: string;
  generation: number;
  operationId: string;
}
export interface HomeTaskReportRequest {
  resultId: string;
  outcome: "progress" | "needs-input" | "final";
  text: string;
  /** Acceptance evidence is separate from the claimed outcome. */
  evidence: string[];
}
export interface HomeTaskReport extends HomeTaskWorkerIdentity, HomeTaskReportRequest {
  version: 1;
  receiptId: string;
  sessionId: string;
  acceptedAt: string;
}
const PARAMETERS = Type.Object({
  resultId: Type.String({ minLength: 1, maxLength: 160 }),
  outcome: Type.Union([Type.Literal("progress"), Type.Literal("needs-input"), Type.Literal("final")]),
  text: Type.String({ minLength: 1, maxLength: 65536 }),
  evidence: Type.Array(Type.String({ minLength: 1, maxLength: 4096 }), { maxItems: 64 }),
}, { additionalProperties: false });

function admit(value: unknown): HomeTaskReportRequest {
  const request = value as HomeTaskReportRequest;
  if (!request || typeof request !== "object" || Object.keys(request).sort().join(",") !== "evidence,outcome,resultId,text"
    || typeof request.resultId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(request.resultId)
    || !["progress", "needs-input", "final"].includes(request.outcome)
    || typeof request.text !== "string" || request.text.length === 0 || request.text.includes("\0") || Buffer.byteLength(request.text) > 65536
    || !Array.isArray(request.evidence) || request.evidence.length > 64
    || request.evidence.some(item => typeof item !== "string" || item.length === 0 || item.includes("\0") || Buffer.byteLength(item) > 4096)
    || Buffer.byteLength(JSON.stringify(request)) > 128 * 1024) throw new Error("Invalid task report");
  return { resultId: request.resultId, outcome: request.outcome, text: request.text, evidence: [...request.evidence] };
}

/** Canonical reports cross a cold-process trust boundary too: the tool schema
 * alone cannot qualify persisted evidence after restart. */
export function parseHomeTaskReport(value: unknown): HomeTaskReport {
  const report = value as HomeTaskReport;
  const identityKeys = ["version", "taskId", "intentRevision", "homeId", "generation", "operationId", "receiptId", "sessionId", "acceptedAt"];
  if (!report || typeof report !== "object" || Array.isArray(report)
    || Object.keys(report).sort().join(",") !== [...identityKeys, "resultId", "outcome", "text", "evidence"].sort().join(",")
    || report.version !== 1 || !Number.isSafeInteger(report.intentRevision) || report.intentRevision < 1
    || !Number.isSafeInteger(report.generation) || report.generation < 1
    || [report.taskId, report.homeId, report.operationId, report.sessionId].some(id => typeof id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(id))
    || report.receiptId !== `report:${report.operationId}` || typeof report.acceptedAt !== "string" || !Number.isFinite(Date.parse(report.acceptedAt))) throw new Error("Invalid canonical task report");
  admit({ resultId: report.resultId, outcome: report.outcome, text: report.text, evidence: report.evidence });
  return report;
}

/** One immutable result belongs to one worker operation, not to a slot-wide map.
 * Append evidence before sealing; failure leaves no false accepted result. */
export class HomeTaskReportOwner {
  private readonly mutex = new AsyncMutex();
  private sealed: { request: string; report: HomeTaskReport; entryId: string } | undefined;
  private stopping: Promise<void> | undefined;
  private readonly cancellation = new AbortController();
  get signal(): AbortSignal { return this.cancellation.signal; }
  cancel(): void { this.cancellation.abort(); }
  requestStop(stop: () => Promise<void>): void {
    if (!this.stopping) {
      this.stopping = stop();
      void this.stopping.catch(() => {}); // The task settlement owner joins this promise.
    }
  }
  async joinStop(): Promise<void> { await this.stopping; }
  readonly identity: Readonly<HomeTaskWorkerIdentity>;
  private admission: { interrupt: () => Promise<void> } | undefined;
  constructor(identity: HomeTaskWorkerIdentity, interrupt: () => Promise<void>) {
    this.identity = Object.freeze({ ...identity });
    this.admission = { interrupt };
  }

  get controlsActive(): boolean { return this.admission !== undefined; }
  get acceptsSteering(): boolean { return !!this.admission && !this.sealed && !this.stopping; }
  /** Settlement releases execution callbacks with the lease, even when exact
   * Stop failed. Immutable evidence remains, but no late report can rewrite it. */
  retire(): void { this.admission = undefined; this.cancel(); }

  async stop(): Promise<void> {
    if (!this.admission) throw new Error("Task control is unavailable");
    this.requestStop(this.admission.interrupt);
    await this.joinStop();
  }

  async accept(sessionId: string, operationId: string | undefined, value: unknown,
    append: (report: HomeTaskReport) => Promise<string>): Promise<string> {
    const request = admit(value);
    if (operationId !== this.identity.operationId) throw new Error("Stale task operation");
    return this.mutex.run(async () => {
      if (!this.admission) throw new Error("Task operation is retired");
      const payload = JSON.stringify(request);
      if (this.sealed) {
        if (payload !== this.sealed.request || this.sealed.report.sessionId !== sessionId) throw new Error("Conflicting task report");
        return this.sealed.entryId;
      }
      if (this.stopping) throw new Error("Task operation is stopping");
      const report: HomeTaskReport = { version: 1, ...this.identity, ...request,
        receiptId: `report:${this.identity.operationId}`, sessionId, acceptedAt: new Date().toISOString() };
      const entryId = await append(report);
      this.sealed = { request: payload, report, entryId };
      return entryId;
    });
  }

  tool(sessionId: () => string, operationId: () => string | undefined,
    append: (report: HomeTaskReport) => Promise<string>, stop: () => void): ToolDefinition {
    return { name: "report", label: "Report", description: "Seal the task's explicit immutable result with acceptance evidence. Ends this task immediately; do no work afterwards.",
      parameters: PARAMETERS, executionMode: "sequential",
      execute: async (_id, request) => {
        const entryId = await this.accept(sessionId(), operationId(), request, append);
        // Never await abort inside the tool being joined by that abort.
        stop();
        return { content: [{ type: "text", text: "Task report sealed." }], details: { entryId } };
      },
    };
  }
}
