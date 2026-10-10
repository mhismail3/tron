import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

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
