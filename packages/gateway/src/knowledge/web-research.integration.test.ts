import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { expect, it } from "vitest";
import { WebResearch } from "./web-research.js";

/** HTTP/socket integration for the shared owner's nonduplicated boundaries:
 * global dispatch limits, streamed body bounds, pre-disclosure redirect safety,
 * and stored-byte TTL. Runtime/role/status semantics are covered by Gateway E2E. */
it("bounds concurrent callers, rejects oversized streams and unsafe redirects, and expires scoped bytes", async () => {
  let active = 0; let peak = 0; let providerCalls = 0; let originCalls = 0;
  let release!: () => void; const held = new Promise<void>(resolve => { release = resolve; });
  const server: Server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", chunk => chunks.push(chunk));
    request.on("end", () => {
      if (request.url === "/redirect") { originCalls++; response.writeHead(302, { location: "http://127.0.0.1/secret" }).end(); return; }
      providerCalls++; active++; peak = Math.max(peak, active);
      response.on("close", () => { active--; });
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (body.query === "oversize") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ success: true, data: { web: [], padding: "x".repeat(300000) } })); return;
      }
      const finish = () => response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ success: true, data: { web: [{ title: "Shared fixture", url: "https://example.org/source", description: "資料🙂 bounded fixture passage" }] } }));
      if (String(body.query).startsWith("held")) void held.then(finish); else finish();
    });
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  let clock = Date.now();
  const service = new WebResearch(() => ({
    resolveHost: async () => ["93.184.216.34"],
    providerFetcher: (_input, init) => fetch(`${endpoint}/provider`, init),
    fetcher: (_input, init) => fetch(`${endpoint}/redirect`, init),
  }), () => clock);
  let passed = false;
  try {
    const first = service.execute("home", { op: "search", query: "held-home" });
    const second = service.execute("worker", { op: "search", query: "held-worker" });
    // Synchronize on the real socket requests rather than a timing sleep.
    const ready = Date.now() + 2000;
    while (providerCalls < 2 && Date.now() < ready) await new Promise<void>(resolve => setImmediate(resolve));
    expect(providerCalls).toBe(2);
    const refused = await service.execute("child", { op: "search", query: "third" });
    expect(refused).toMatchObject({ isError: true, details: { reason: "rate_limited" } });
    expect(providerCalls).toBe(2); release();
    const [home, worker] = await Promise.all([first, second]);
    expect(home.isError).toBe(false); expect(worker.isError).toBe(false); expect(peak).toBe(2);
    const oversized = await service.execute("home", { op: "search", query: "oversize" });
    expect(oversized).toMatchObject({ isError: true, details: { reason: "parse_error" } });
    const before = providerCalls;
    const redirected = await service.execute("home", { op: "read", url: "https://example.org/redirect" });
    expect(redirected).toMatchObject({ isError: true, details: { reason: "blocked" } }); expect(originCalls).toBe(1); expect(providerCalls).toBe(before);
    const credential = await service.execute("home", { op: "read", url: "https://example.org/?api_key=secret" });
    expect(credential.isError).toBe(true); expect(originCalls).toBe(1); expect(providerCalls).toBe(before);
    const saved = JSON.parse(home.content[0]!.text);
    const slice = await service.execute("home", { op: "content", resultId: saved.resultId, sourceId: saved.sources[0].sourceId, offset: 1, limitBytes: 7 });
    const content = JSON.parse(slice.content[0]!.text).sources[0].content;
    expect(content).not.toContain("�"); expect(Buffer.byteLength(content)).toBeLessThanOrEqual(7);
    clock += 15 * 60000 + 1;
    const expired = await service.execute("home", { op: "content", resultId: saved.resultId });
    expect(expired).toMatchObject({ isError: true, details: { reason: "expired" } });
    passed = true;
  } finally {
    release(); await service.stop();
    await new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); });
    const output = join(process.cwd(), "test-results", "web-research-integration"); await mkdir(output, { recursive: true });
    await writeFile(join(output, "report.json"), JSON.stringify({ passed, peak, providerCalls, originCalls }, null, 2));
  }
});
