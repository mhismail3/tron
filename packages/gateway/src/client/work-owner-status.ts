#!/usr/bin/env node
import { resolveBindHost } from "../config.js";
import { resolveTronHome } from "../tron-home.js";
import { GatewayProtocolClient } from "./gateway-client.js";
import { readLocalCredential } from "./local-credential.js";

async function main(): Promise<void> {
  const session = process.argv[2];
  if (!session) throw new Error("session id required");
  const tronHome = resolveTronHome();
  const port = Number(process.env.TRON_GATEWAY_PORT ?? (process.env.TRON_HOME_NAME === ".tron-dev" ? 9848 : 9847));
  const host = resolveBindHost(process.env.TRON_GATEWAY_HOST ?? "tailscale");
  const client = new GatewayProtocolClient(`ws://${host.includes(":") ? `[${host}]` : host}:${port}/v1/socket`,
    await readLocalCredential(tronHome));
  try {
    await client.connect();
    let cursor: string | undefined;
    for (let page = 0; page < 100; page += 1) {
      const result = await client.request("home.taskList", { limit: 50, ...(cursor ? { cursor } : {}) }) as {
        items: Array<{ taskId: string }>; nextCursor?: string;
      };
      for (const item of result.items) {
        const task = await client.request("home.taskStatus", { taskId: item.taskId }) as {
          sessionId?: string | null; lifecycle?: string; terminalEvidence?: { outcome?: string } | null;
          subagents?: { started?: number; stoppedAtEnd?: number | null };
          subagentRuns?: { total?: number; runs?: unknown[] };
        };
        if (task.sessionId !== session) continue;
        const settledRuns = task.subagentRuns?.total === 0 && task.subagentRuns.runs?.length === 0;
        const settled = task.lifecycle === "terminal" && !!task.terminalEvidence
          && task.terminalEvidence.outcome !== "unknown" && task.terminalEvidence.outcome !== "detached"
          && task.subagents?.stoppedAtEnd !== null
          && task.subagents?.started === task.subagents?.stoppedAtEnd && settledRuns;
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
