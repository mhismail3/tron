import { execFile } from "node:child_process";
import { lstat, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";

/**
 * Gateway projection of the one-tap Mac app replacement (#984).
 *
 * The orchestrator (`scripts/tron_mac_replace.py`) runs as its own launchd job
 * and is the single writer of its journal under `<tronHome>/../.tron-maintenance/replace`.
 * This service only reads that journal, asks the orchestrator for its plan,
 * starts it, pushes its result, and resumes the workers it stopped in place.
 */
export const MAC_REPLACE_CAPABILITY = "mac-replace.v1";
const MAX_JOURNAL_BYTES = 512 * 1_024;
const OPERATION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const TERMINAL = new Set(["succeeded", "failed", "rolled-back", "rollback-failed"]);
const execFileAsync = promisify(execFile);

export interface MacReplaceWorker { taskId: string; sessionId: string; title: string; stoppedAt?: string }
export type MacReplaceWorkerState = "resumable" | "resumed" | "stopping" | "unavailable";

export interface MacReplaceDependencies {
  tronHome: string;
  channel: "stable" | "dev";
  /** The configured source repository whose scripts plan and start a replacement. */
  sourceRoot: () => Promise<string | undefined>;
  /** Push one bounded result notification; returns the admission state. */
  notify?: (input: { sourceId: string; message: string }) => Promise<string>;
  /** The newest task on a worker session (its in-place continuation, if any). */
  latestWorkerTask?: (sessionId: string) => Promise<{ taskId: string; lifecycle: string; operationId: string | null } | undefined>;
  /** Resume a settled task in place on its own worker session. */
  resumeTask?: (input: { taskId: string; operationId: string; text: string }) => Promise<JsonValue>;
  environment?: NodeJS.ProcessEnv;
}

const RESUME_TEXT = "The Mac app was replaced while this task ran, so it was stopped and preserved. Continue the task in place from where you left off.";

export class MacReplaceService {
  constructor(private readonly dependencies: MacReplaceDependencies) {}

  private get store(): string { return join(dirname(this.dependencies.tronHome), ".tron-maintenance", "replace"); }

  /** Only the supervised Stable Gateway of this account's own `~/.tron` may start a replacement:
   * the orchestrator acts on /Applications/Tron.app, so any other Gateway reads status only. */
  get startable(): boolean {
    const environment = this.dependencies.environment ?? process.env;
    return environment.TRON_GATEWAY_SUPERVISED === "1" && this.dependencies.channel === "stable"
      && this.dependencies.tronHome === join(homedir(), ".tron");
  }

  async journal(): Promise<Record<string, JsonValue> | null> {
    const pointer = await readBoundedJson(join(this.store, "current.json"), 4_096);
    if (pointer === undefined) return null;
    const id = (pointer as Record<string, unknown>).id;
    if (typeof id !== "string" || !OPERATION_ID.test(id)) throw new GatewayError("conflict", "Mac replacement pointer is malformed");
    const journal = await readBoundedJson(join(this.store, id, "journal.json"), MAX_JOURNAL_BYTES);
    if (!journal || typeof journal !== "object" || Array.isArray(journal)) throw new GatewayError("conflict", "Mac replacement journal is missing");
    const raw = journal as Record<string, JsonValue>;
    if (raw.schema !== 1 || raw.kind !== "tron-mac-replace" || raw.id !== id || !Array.isArray(raw.steps)) {
      throw new GatewayError("conflict", "Mac replacement journal is malformed");
    }
    return raw;
  }

  private workers(journal: Record<string, JsonValue>): MacReplaceWorker[] {
    const workers = Array.isArray(journal.workers) ? journal.workers : [];
    return workers.flatMap((value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return [];
      const worker = value as Record<string, unknown>;
      return typeof worker.taskId === "string" && typeof worker.sessionId === "string"
        ? [{ taskId: worker.taskId, sessionId: worker.sessionId, title: typeof worker.title === "string" ? worker.title.slice(0, 200) : worker.taskId,
          ...(typeof worker.stoppedAt === "string" ? { stoppedAt: worker.stoppedAt } : {}) }] : [];
    });
  }

  private async workerState(worker: MacReplaceWorker): Promise<MacReplaceWorkerState> {
    if (!this.dependencies.latestWorkerTask) return "unavailable";
    const latest = await this.dependencies.latestWorkerTask(worker.sessionId).catch(() => undefined);
    if (!latest) return "unavailable";
    if (latest.taskId !== worker.taskId) return "resumed";
    return latest.lifecycle === "terminal" ? "resumable" : "stopping";
  }

  async status(): Promise<JsonValue> {
    const journal = await this.journal();
    const workers = journal ? await Promise.all(this.workers(journal).map(async (worker) => ({ ...worker, state: await this.workerState(worker) }))) : [];
    return { startable: this.startable, operation: journal, workers } as JsonValue;
  }

  private async script(args: string[], timeoutMs: number): Promise<Record<string, JsonValue>> {
    const sourceRoot = await this.dependencies.sourceRoot();
    if (!sourceRoot) throw new GatewayError("conflict", "Set a source repository in server details first");
    try {
      const { stdout } = await execFileAsync("/usr/bin/python3", [join(sourceRoot, "scripts", "tron_mac_replace.py"), ...args], {
        timeout: timeoutMs, maxBuffer: 256 * 1_024, cwd: sourceRoot,
        env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", HOME: homedir() },
      });
      return JSON.parse(stdout) as Record<string, JsonValue>;
    } catch (error) {
      const stderr = String((error as { stderr?: unknown }).stderr ?? (error as Error).message ?? error).trim();
      throw new GatewayError("conflict", stderr.replace(/^STOP: /u, "").slice(0, 1_024) || "Mac replacement script failed");
    }
  }

  async plan(): Promise<JsonValue> {
    return { startable: this.startable, ...(await this.script(["--plan", "--json"], 60_000)) } as JsonValue;
  }

  async start(clientProtocol: number): Promise<JsonValue> {
    if (!this.startable) throw new GatewayError("unsupported", "Only the supervised Stable Gateway can replace the Mac app");
    return (await this.script(["--start", "--json", "--client-protocol", String(clientProtocol)], 120_000)) as JsonValue;
  }

  /** Push the result the journal records, once per attempt (the notification store dedupes on sourceId). */
  async complete(operationId: string): Promise<JsonValue> {
    const journal = await this.journal();
    if (!journal || journal.id !== operationId) throw new GatewayError("not_found", "No such Mac replacement");
    if (!TERMINAL.has(String(journal.state))) throw new GatewayError("conflict", "The Mac replacement has not settled");
    if (!this.dependencies.notify) return { state: "unavailable" };
    const state = await this.dependencies.notify({ sourceId: `mac-replace:${operationId}:${String(journal.attempt)}`, message: resultMessage(journal) });
    return { state };
  }

  async resumeWorker(operationId: string, taskId: string): Promise<JsonValue> {
    const journal = await this.journal();
    if (!journal || journal.id !== operationId) throw new GatewayError("not_found", "No such Mac replacement");
    if (!TERMINAL.has(String(journal.state))) throw new GatewayError("conflict", "Resume workers after the replacement settles");
    const worker = this.workers(journal).find((candidate) => candidate.taskId === taskId);
    if (!worker) throw new GatewayError("not_found", "This replacement did not stop that worker");
    if (!this.dependencies.latestWorkerTask || !this.dependencies.resumeTask) throw new GatewayError("unsupported", "Home is unavailable");
    const latest = await this.dependencies.latestWorkerTask(worker.sessionId);
    if (!latest || latest.taskId !== taskId) throw new GatewayError("conflict", "This worker was already resumed");
    if (latest.lifecycle !== "terminal" || !latest.operationId) throw new GatewayError("busy", "The worker is still stopping; try again in a moment", true);
    return this.dependencies.resumeTask({ taskId, operationId: latest.operationId, text: RESUME_TEXT });
  }
}

export function resultMessage(journal: Record<string, JsonValue>): string {
  const result = journal.result as Record<string, JsonValue> | null;
  const error = journal.error as Record<string, JsonValue> | null;
  const workers = Array.isArray(journal.workers) ? journal.workers.length : 0;
  const resume = workers ? ` ${workers} stopped worker${workers === 1 ? "" : "s"} can be resumed in Settings.` : "";
  switch (journal.state) {
    case "succeeded":
      return `Mac app replaced: Gateway ${String(result?.revision ?? "").slice(0, 9)} on protocol ${String(result?.protocol ?? "?")}${result?.cdhash ? `, signature ${String(result.cdhash).slice(0, 12)} verified` : ""}.${resume}`;
    case "rolled-back":
      return `Mac app replacement failed at ${String(error?.step ?? "?")} and was rolled back: ${String(error?.message ?? "").slice(0, 240)}${resume}`;
    case "rollback-failed":
      return `Mac app replacement failed and could not roll back. Check scripts/tron mac replace --status on the Mac.`;
    default:
      return `Mac app replacement failed at ${String(error?.step ?? "?")}: ${String(error?.message ?? "").slice(0, 280)}${resume}`;
  }
}

async function readBoundedJson(path: string, maximum: number): Promise<unknown | undefined> {
  try {
    const info = await lstat(path);
    if (!info.isFile() || info.size > maximum) throw new GatewayError("conflict", "Mac replacement journal is malformed or oversized");
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    if (error instanceof GatewayError) throw error;
    throw new GatewayError("conflict", "Mac replacement journal is unreadable");
  }
}
