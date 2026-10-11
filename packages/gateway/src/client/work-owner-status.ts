#!/usr/bin/env node
import { isIP } from "node:net";
import { networkInterfaces } from "node:os";
import { resolveBindHost } from "../config.js";
import type { JsonValue } from "../protocol/types.js";
import { resolveTronHome } from "../tron-home.js";
import { GatewayProtocolClient } from "./gateway-client.js";
import { readLocalCredential } from "./local-credential.js";

const settledEvidence = new Set([
  "final:explicit-report", "final:cold-explicit-report",
  "progress:explicit-report", "progress:cold-explicit-report",
  "needs-input:explicit-report", "needs-input:cold-explicit-report",
  "interrupted:task-stop", "interrupted:stopped-before-conversation",
  "limited:deadline", "limited:length",
]);

type TaskStatus = {
  taskId?: unknown; operationId?: unknown; sessionId?: unknown; lifecycle?: unknown;
  terminalEvidence?: { outcome?: unknown; reason?: unknown; sessionId?: unknown } | null;
  subagents?: { started?: unknown; stoppedAtEnd?: unknown };
  subagentRuns?: { total?: unknown; runs?: unknown[] };
  ownerSettlement?: { taskId?: unknown; sessionId?: unknown; operationId?: unknown;
    markerEntryId?: unknown; terminalEntryId?: unknown; settlementEntryId?: unknown; stoppedAtEnd?: unknown } | null;
};
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

async function main(): Promise<void> {
  const session = process.argv[2];
  if (!id(session)) throw new Error("session id required");
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
  const deadline = Date.now() + 25_000;
  const request = (method: string, params: Record<string, JsonValue>) => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("owner status deadline exceeded");
    return client.request(method, params, Math.min(remaining, 4_000));
  };
  try {
    await client.connect(Math.min(5_000, deadline - Date.now()));
    let cursor: string | undefined;
    for (let page = 0; page < 100 && Date.now() < deadline; page += 1) {
      const result = await request("home.taskList", { limit: 50, ...(cursor ? { cursor } : {}) }) as {
        items: Array<{ taskId: string; lifecycle?: string; sessionId?: string | null }>;
        nextCursor?: string;
      };
      for (const item of result.items) {
        // Status computes spend for active tasks; never call it while classifying live work.
        if (item.lifecycle !== "terminal") continue;
        if (!id(item.taskId)) throw new Error("invalid task identity");
        const task = await request("home.taskStatus", { taskId: item.taskId }) as TaskStatus;
        if (item.sessionId === session || task.sessionId === session || task.terminalEvidence?.sessionId === session) {
          let proven = (item.sessionId == null || item.sessionId === session) && settled(task, item.taskId, session);
          if (proven) {
            const current = await request("home.taskStatus", { taskId: item.taskId }) as TaskStatus;
            proven = settled(current, item.taskId, session) && current.operationId === task.operationId
              && JSON.stringify(current.terminalEvidence) === JSON.stringify(task.terminalEvidence)
              && JSON.stringify(current.ownerSettlement) === JSON.stringify(task.ownerSettlement)
              && JSON.stringify(current.subagents) === JSON.stringify(task.subagents);
          }
          process.stdout.write(proven ? "settled\n" : "live-or-indeterminate\n");
          return;
        }
      }
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    process.stdout.write("unknown\n");
  } finally { client.close(); }
}
main().catch(error => { process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`); process.exitCode = 2; });
