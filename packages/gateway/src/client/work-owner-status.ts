#!/usr/bin/env node
import { resolveBindHost } from "../config.js";
import { resolveTronHome } from "../tron-home.js";
import { GatewayProtocolClient } from "./gateway-client.js";
import { readLocalCredential } from "./local-credential.js";

const settledEvidence = new Set([
  "final:explicit-report", "interrupted:task-stop", "interrupted:stopped-before-conversation",
  "limited:deadline", "limited:turn-limit",
]);

async function main(): Promise<void> {
  const session = process.argv[2];
  if (!session) throw new Error("session id required");
  const tronHome = resolveTronHome();
  const port = Number(process.env.TRON_GATEWAY_PORT ?? (process.env.TRON_HOME_NAME === ".tron-dev" ? 9848 : 9847));
  const host = resolveBindHost(process.env.TRON_GATEWAY_HOST ?? "tailscale");
  const client = new GatewayProtocolClient(`ws://${host.includes(":") ? `[${host}]` : host}:${port}/v1/socket`,
    await readLocalCredential(tronHome));
  const deadline = Date.now() + 25_000;
  try {
    await client.connect(5_000);
    let cursor: string | undefined;
    for (let page = 0; page < 100 && Date.now() < deadline; page += 1) {
      const result = await client.request("home.taskList", { limit: 50, ...(cursor ? { cursor } : {}) }) as {
        items: Array<{ taskId: string; lifecycle?: string }>;
        nextCursor?: string;
      };
      for (const item of result.items) {
        // Status computes spend for active tasks; never call it while classifying live work.
        if (item.lifecycle !== "terminal") continue;
        const task = await client.request("home.taskStatus", { taskId: item.taskId }) as {
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
          && (stopped === null || (Number.isSafeInteger(stopped) && (stopped as number) >= 0 && (stopped as number) <= (started as number)));
        const key = `${evidence?.outcome}:${evidence?.reason}`;
        const settledRuns = runs?.total === 0 && Array.isArray(runs.runs) && runs.runs.length === 0;
        const settled = task.sessionId === session && task.lifecycle === "terminal"
          && evidence?.sessionId === session && settledEvidence.has(key) && validCounts && settledRuns;
        process.stdout.write(settled ? "settled\n" : "live-or-indeterminate\n");
        return;
      }
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    process.stdout.write("unknown\n");
  } finally { client.close(); }
}
main().catch(error => { process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`); process.exitCode = 2; });
