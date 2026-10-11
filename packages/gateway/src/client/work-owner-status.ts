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

async function main(): Promise<void> {
  const session = process.argv[2];
  if (!session) throw new Error("session id required");
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
        items: Array<{ taskId: string; lifecycle?: string }>;
        nextCursor?: string;
      };
      for (const item of result.items) {
        // Status computes spend for active tasks; never call it while classifying live work.
        if (item.lifecycle !== "terminal") continue;
        const task = await request("home.taskStatus", { taskId: item.taskId }) as {
          sessionId?: string | null; lifecycle?: string;
          terminalEvidence?: { outcome?: string; reason?: string; sessionId?: string | null } | null;
          subagents?: { started?: number; stoppedAtEnd?: number | null };
          subagentRuns?: { total?: number; runs?: unknown[] };
        };
        const started = task.subagents?.started;
        const stopped = task.subagents?.stoppedAtEnd;
        const runs = task.subagentRuns;
        const evidence = task.terminalEvidence;
        const validCounts = Number.isSafeInteger(started) && (started as number) >= 0
          && Number.isSafeInteger(stopped) && (stopped as number) >= 0 && (stopped as number) <= (started as number);
        const key = `${evidence?.outcome}:${evidence?.reason}`;
        const settledRuns = runs?.total === 0 && Array.isArray(runs.runs) && runs.runs.length === 0;
        const settled = task.sessionId === session && task.lifecycle === "terminal"
          && evidence?.sessionId === session && settledEvidence.has(key) && validCounts && settledRuns;
        if (task.sessionId === session || evidence?.sessionId === session) {
          process.stdout.write(settled ? "settled\n" : "live-or-indeterminate\n");
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
