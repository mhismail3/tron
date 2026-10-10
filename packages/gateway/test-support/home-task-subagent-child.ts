import { createServer, type Server } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { join } from "node:path";

/** A scripted OpenAI-compatible child model for real managed-provider children.
 * A request whose messages contain `HOLD-CHILD` stays open until the test releases
 * it or its client disconnects, so a run is demonstrably live until the test
 * stops it. Every other request answers `CHILD-DONE` at once. The server counts
 * client disconnects of held requests: that is the proof a child was cut off. */
export interface ChildModelServer {
  port: number;
  heldRequests: () => number;
  abortedRequests: () => number;
  releaseHeld: () => void;
  close: () => Promise<void>;
}

const MAX_REQUEST_BYTES = 2 * 1024 * 1024;
const MAX_REQUESTS = 64;

export async function startChildModelServer(): Promise<ChildModelServer> {
  let requests = 0;
  let held = 0;
  let aborted = 0;
  const releasers = new Set<() => void>();
  const server: Server = createServer(async (request, response) => {
    if (++requests > MAX_REQUESTS) { response.writeHead(500).end("request bound exceeded"); return; }
    let body = "";
    for await (const chunk of request) {
      body += chunk;
      if (body.length > MAX_REQUEST_BYTES) { response.writeHead(413).end(); return; }
    }
    const messages = (JSON.parse(body) as { messages?: unknown }).messages;
    const holds = JSON.stringify(messages).includes("HOLD-CHILD");
    if (holds) {
      held += 1;
      // The response closes early only when the client disconnects (an abort).
      let finish!: () => void;
      await new Promise<void>(resolve => {
        finish = () => resolve();
        releasers.add(finish);
        response.once("close", () => { if (!response.writableEnded) aborted += 1; resolve(); });
      });
      releasers.delete(finish);
      if (response.destroyed) return;
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    const chunks = [
      { role: "assistant", content: "CHILD-DONE" },
      {},
    ];
    chunks.forEach((delta, index) => {
      response.write(`data: ${JSON.stringify({ id: "task-child", object: "chat.completion.chunk", created: 1, model: "child",
        choices: [{ index: 0, delta, finish_reason: index === chunks.length - 1 ? "stop" : null }] })}\n\n`);
    });
    response.end("data: [DONE]\n\n");
  });
  server.requestTimeout = 60_000;
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo | null;
  if (!address || typeof address === "string") throw new Error("child model server did not bind a port");
  let closed = false;
  return {
    port: address.port,
    heldRequests: () => held,
    abortedRequests: () => aborted,
    releaseHeld: () => { for (const release of [...releasers]) release(); },
    close: async () => {
      if (closed) return;
      closed = true;
      for (const release of [...releasers]) release();
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    },
  };
}

/** Starts the scripted child model and registers it for a managed fixture: a
 * `task-child` agent whose model answers from this server. The fixture's own
 * agent and project directories hold the registration. */
export async function startScriptedChild(fixture: { agentDir: string; cwd: string }): Promise<ChildModelServer> {
  const server = await startChildModelServer();
  await writeFile(join(fixture.agentDir, "models.json"), JSON.stringify({ providers: { "task-child": {
    baseUrl: `http://127.0.0.1:${server.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
    models: [{ id: "child", name: "Task child", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  await mkdir(join(fixture.cwd, ".pi", "agents"), { recursive: true });
  await writeFile(join(fixture.cwd, ".pi", "agents", "task-child.md"),
    "---\nname: task-child\ndescription: Scripted task child\nmodel: task-child/child\ntools: read\n---\nComplete the scripted task.\n");
  return server;
}

/** Workflow scripts (written under the request cwd) whose one child holds until stopped:
 * the workflow stays running while the child is live. */
export const HELD_WORKFLOW_SCRIPT = 'return runs.run("hold", { agent: "task-child", task: "HOLD-CHILD workflow search" });\n';
/** A child the script launches as async and then returns: the workflow completes while
 * the child keeps running, as a detached workflow child does. */
export const DETACHED_WORKFLOW_SCRIPT = 'const receipt = await runs.run("hold", { agent: "task-child", task: "HOLD-CHILD detached search", async: true });\nreturn receipt.runId;\n';
