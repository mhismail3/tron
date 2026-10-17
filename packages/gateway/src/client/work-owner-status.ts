#!/usr/bin/env node
/**
 * Work-claim owner status for `scripts/tron work` (tools/work/README.md, "Owner status").
 *
 * Prints one JSON verdict `{state, reason}` on stdout:
 * - `live`: a Home task for the session is not terminal, or the Gateway lists the session as active.
 * - `settled`: the session's Home task is terminal with settlement proof.
 * - `absent`: the id has Gateway session shape, the Gateway lists no such session, and no file in the
 *   Gateway's session root (validated against that listing) carries the id. The automatic
 *   stale-claim sweep accepts this; candidate recovery needs `settled`.
 * - `idle`: the Gateway lists the session as idle (no turn, subagent or user wait) and no Home task is
 *   bound to it. It can still be resumed, so automatic sweep/recovery keep its claim.
 * - `indeterminate`: anything else, including a deadline. Callers fail closed.
 * Exit 3 with a JSON stderr detail is a protocol mismatch; any other failure exits 2.
 *
 */
import { readdir } from "node:fs/promises";
import { isIP } from "node:net";
import { networkInterfaces } from "node:os";
import { join, resolve } from "node:path";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { resolveBindHost } from "../config.js";
import type { JsonValue } from "../protocol/types.js";
import { resolveTronHome } from "../tron-home.js";
import { GatewayClientError, GatewayProtocolClient } from "./gateway-client.js";
import { PROTOCOL_VERSION } from "../version.js";
import { readLocalCredential } from "./local-credential.js";

/** One overall budget; each request gets what remains, so a slow page cannot hang the caller. */
const DEADLINE_MS = 20_000;
const ROOT_ENTRY_LIMIT = 200_000;
const SESSION_ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gu;

const settledEvidence = new Set([
  "final:explicit-report", "final:cold-explicit-report",
  "progress:explicit-report", "progress:cold-explicit-report",
  "needs-input:explicit-report", "needs-input:cold-explicit-report",
  "interrupted:task-stop", "interrupted:stopped-before-conversation",
  "limited:deadline", "limited:length",
  // The Gateway reconciled these from the canonical file after the worker's operation ended,
  // with every async run's own status proven ended (else `detached-work-outlived-task`): the
  // owner runs no more, though its work result is unknown (#1166).
  "unknown:settlement-failed", "unknown:cold-no-report",
]);

type State = "settled" | "live" | "absent" | "idle" | "indeterminate";
type Verdict = { state: State; reason: string };
class Indeterminate extends Error {}

type TaskStatus = {
  taskId?: unknown; operationId?: unknown; sessionId?: unknown; lifecycle?: unknown;
  terminalEvidence?: { outcome?: unknown; reason?: unknown; sessionId?: unknown } | null;
  subagents?: { started?: unknown; stoppedAtEnd?: unknown };
  subagentRuns?: { total?: unknown; runs?: unknown[] };
  ownerSettlement?: { taskId?: unknown; sessionId?: unknown; operationId?: unknown;
    markerEntryId?: unknown; terminalEntryId?: unknown; settlementEntryId?: unknown; stoppedAtEnd?: unknown } | null;
};
type SessionRow = { id?: unknown; phase?: unknown; foregroundPhase?: unknown; activeSince?: unknown;
  hasActiveSubagents?: unknown; waitingForUser?: unknown };
const id = (value: unknown): value is string => typeof value === "string" && value.length > 0 && value.length <= 256 && !/[\u0000-\u001f\u007f]/u.test(value);
function settled(task: TaskStatus, taskId: string, session: string): boolean {
  const started = task.subagents?.started, stopped = task.subagents?.stoppedAtEnd;
  const evidence = task.terminalEvidence, runs = task.subagentRuns;
  if (task.taskId !== taskId || !id(task.operationId) || task.sessionId !== session || task.lifecycle !== "terminal"
    || evidence?.sessionId !== session || !Number.isSafeInteger(started) || Number(started) < 0
    || !Number.isSafeInteger(stopped) || Number(stopped) < 0 || Number(stopped) > Number(started)
    || runs?.total !== 0 || !Array.isArray(runs.runs) || runs.runs.length !== 0) return false;
  if (settledEvidence.has(`${evidence.outcome}:${evidence.reason}`)) return true;
  // The Gateway validates an ordered durable canonical cut. Zero terminal run
  // counts are synthetic; an unknown work result alone never proves settlement.
  const proof = task.ownerSettlement;
  return evidence.outcome === "unknown" && evidence.reason === "no-report" && !!proof
    && Object.keys(proof).sort().join(",") === "markerEntryId,operationId,sessionId,settlementEntryId,stoppedAtEnd,taskId,terminalEntryId"
    && proof.taskId === taskId && proof.sessionId === session && proof.operationId === task.operationId
    && id(proof.markerEntryId) && id(proof.terminalEntryId) && id(proof.settlementEntryId)
    && new Set([proof.markerEntryId, proof.terminalEntryId, proof.settlementEntryId]).size === 3
    && proof.stoppedAtEnd === stopped;
}

function active(row: SessionRow): boolean {
  return row.activeSince !== undefined || row.hasActiveSubagents === true || row.waitingForUser === true
    || (row.phase !== undefined && row.phase !== "idle") || (row.foregroundPhase !== undefined && row.foregroundPhase !== "idle");
}

/** Every session-shaped id in the names under the Gateway's session root, bounded. */
async function idsUnder(root: string, deadline: number): Promise<Set<string>> {
  const ids = new Set<string>();
  const pending = [root];
  let entries = 0;
  const visit = async (directory: string) => {
    let names;
    try { names = await readdir(directory, { withFileTypes: true }); }
    catch (error) {
      throw new Indeterminate(`cannot read ${directory === root ? "the Gateway session root" : "a session folder"}: ${(error as Error).message}`);
    }
    entries += names.length;
    if (entries > ROOT_ENTRY_LIMIT) throw new Indeterminate(`the session root holds more than ${ROOT_ENTRY_LIMIT} entries`);
    if (Date.now() > deadline) throw new Indeterminate(`the session root scan exceeded the ${DEADLINE_MS / 1000}s owner-status deadline`);
    for (const entry of names) {
      for (const match of entry.name.toLowerCase().matchAll(SESSION_ID)) ids.add(match[0]);
      if (entry.isDirectory()) pending.push(join(directory, entry.name));
    }
  };
  // Folders are independent; a small fixed width keeps the walk to a few seconds on thousands of sessions.
  while (pending.length) await Promise.all(pending.splice(0, 16).map(visit));
  return ids;
}

async function verdict(client: GatewayProtocolClient, session: string, deadline: number): Promise<Verdict> {
  const request = async (method: string, params: Record<string, JsonValue>) => {
    const late = () => new Indeterminate(`${method} did not answer within the ${DEADLINE_MS / 1000}s owner-status deadline`
      + (method === "home.taskList" ? "; a Gateway older than #905 lists Home tasks at O(catalog) per row, so update the Gateway and retry" : "; retry when the Gateway is less busy"));
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw late();
    try { return await client.request(method, params, remaining); }
    catch (error) {
      if (error instanceof GatewayClientError && error.code === "protocol_mismatch") throw error;
      if (Date.now() >= deadline - 50) throw late();
      throw new Indeterminate(`${method} failed: ${(error as Error).message}`);
    }
  };

  // 1. The Gateway's own session listing (user scope, including archived rows): cheap and authoritative for liveness.
  const rows: SessionRow[] = [];
  for (const archived of ["exclude", "only"]) {
    let cursor: string | undefined;
    do {
      const page = await request("session.list", { scope: "user", archived, limit: 500, ...(cursor ? { cursor } : {}) }) as
        { sessions?: SessionRow[]; nextCursor?: string };
      if (!Array.isArray(page.sessions)) throw new Indeterminate("session.list returned no rows");
      rows.push(...page.sessions);
      cursor = page.nextCursor;
    } while (cursor);
  }
  const row = rows.find((candidate) => candidate.id === session);
  if (row && active(row)) return { state: "live", reason: `session ${session} is active in the Gateway` };

  // 2. Absence. The user listing omits delegated sessions and Home chapters, so the session root is read too;
  //    the root is trusted only when it holds every idle listed session.
  const sessionShaped = new RegExp(`^${SESSION_ID.source}$`, "u").test(session);
  if (!row && sessionShaped) {
    const agentDir = resolve(process.env.PI_CODING_AGENT_DIR ?? join(resolveTronHome(), "agent"));
    const root = SettingsManager.create(process.cwd(), agentDir, { projectTrusted: false }).getSessionDir() ?? join(agentDir, "sessions");
    const ids = await idsUnder(root, deadline);
    const unmatched = rows.filter((candidate) => !active(candidate) && typeof candidate.id === "string" && !ids.has(candidate.id));
    if (unmatched.length) throw new Indeterminate(`the session root does not hold ${unmatched.length} listed session(s); it is not the Gateway's`);
    if (!ids.has(session)) return { state: "absent", reason: `no Gateway session or session file has id ${session}` };
  }

  // 3. Home tasks, newest first. Only the matching task's status is read.
  let cursor: string | undefined;
  for (let page = 0; page < 100; page += 1) {
    const result = await request("home.taskList", { limit: 50, ...(cursor ? { cursor } : {}) }) as {
      items?: Array<{ taskId?: unknown; lifecycle?: unknown; sessionId?: unknown }>; nextCursor?: string;
    };
    if (!Array.isArray(result.items)) throw new Indeterminate("home.taskList returned no items");
    for (const item of result.items) {
      if (item.sessionId !== session) continue;
      if (!id(item.taskId)) throw new Indeterminate("home.taskList returned an invalid task identity");
      if (item.lifecycle !== "terminal") return { state: "live", reason: `Home task ${item.taskId} is ${String(item.lifecycle)}` };
      const task = await request("home.taskStatus", { taskId: item.taskId }) as TaskStatus;
      let proven = settled(task, item.taskId, session);
      if (proven) {
        // A second read must agree exactly: a racing status change is not proof.
        const current = await request("home.taskStatus", { taskId: item.taskId }) as TaskStatus;
        proven = settled(current, item.taskId, session) && current.operationId === task.operationId
          && JSON.stringify(current.terminalEvidence) === JSON.stringify(task.terminalEvidence)
          && JSON.stringify(current.ownerSettlement) === JSON.stringify(task.ownerSettlement)
          && JSON.stringify(current.subagents) === JSON.stringify(task.subagents);
      }
      return proven
        ? { state: "settled", reason: `Home task ${item.taskId} settled` }
        : { state: "indeterminate", reason: `Home task ${item.taskId} ended without settlement proof` };
    }
    cursor = result.nextCursor;
    if (!cursor) break;
  }
  // Idle needs the whole Home task list read: a task beyond the page cap could still hold the session.
  if (cursor) throw new Indeterminate("home.taskList has more than 100 pages; the session's Home task is unknown");
  if (row) return { state: "idle", reason: `session ${session} is listed idle with no live turn and no Home task; it can be resumed` };
  return { state: "indeterminate", reason: sessionShaped
    ? `session ${session} has a file but no user listing (a delegated session or Home chapter) and is no settled Home task`
    : `owner ${session} is not a Gateway session id and is no Home task; another runtime may hold it` };
}

async function main(): Promise<void> {
  const session = process.argv[2];
  if (!id(session)) throw new Error("session id required");
  const deadline = Date.now() + DEADLINE_MS;
  const tronHome = resolveTronHome();
  const port = Number(process.env.TRON_GATEWAY_PORT ?? (process.env.TRON_HOME_NAME === ".tron-dev" ? 9848 : 9847));
  const interfaces = networkInterfaces();
  const requestedHost = process.env.TRON_GATEWAY_HOST?.trim() || "tailscale";
  const host = resolveBindHost(requestedHost, interfaces);
  const trustedLoopback = ["localhost", "127.0.0.1", "::1"].includes(host);
  const assignedLocally = isIP(host) !== 0 && Object.values(interfaces)
    .some((addresses) => addresses?.some((address) => address.address === host));
  if (!trustedLoopback && !assignedLocally) {
    throw new Error("owner status requires localhost or an IP address assigned to this Mac");
  }
  const client = new GatewayProtocolClient(`ws://${host.includes(":") ? `[${host}]` : host}:${port}/v1/socket`,
    await readLocalCredential(tronHome));
  let result: Verdict;
  try {
    try { await client.connect(Math.min(5_000, deadline - Date.now())); }
    catch (error) {
      if (error instanceof GatewayClientError && error.code === "protocol_mismatch") throw error;
      throw new Indeterminate(`cannot reach the Gateway at port ${port}: ${(error as Error).message}`);
    }
    result = await verdict(client, session, deadline);
  } catch (error) {
    if (!(error instanceof Indeterminate)) throw error;
    result = { state: "indeterminate", reason: error.message };
  } finally { client.close(); }
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
main().catch(error => {
  if (error instanceof GatewayClientError && error.code === "protocol_mismatch") {
    const details = error.details && typeof error.details === "object" && !Array.isArray(error.details)
      ? error.details as Record<string, unknown> : {};
    const gatewayProtocol = details.gatewayProtocol;
    process.stderr.write(`${JSON.stringify({ kind: "protocol_mismatch", gatewayProtocol: Number.isSafeInteger(gatewayProtocol) ? gatewayProtocol : null, helperProtocol: PROTOCOL_VERSION })}\n`);
    process.exitCode = 3;
    return;
  }
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 2;
});
