import { describe, expect, it } from "vitest";
import { requestFixedHost } from "./fixed-host-transport.js";

const signal = () => new AbortController().signal;
function response(body: string, status = 200): Response {
  return new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode(body)); controller.close(); } }), { status });
}

describe("fixed-host transport", () => {
  it("keeps allowlisted provider requests bounded and refuses redirects", async () => {
    let seen: RequestInit | undefined;
    const result = await requestFixedHost("https://api.raindrop.io/rest/v1/user", {
      method: "GET", headers: { authorization: "Bearer fixture" }, signal: signal(),
      allowedHosts: ["api.raindrop.io"], timeoutMs: 1_000, maxBodyBytes: 64,
    }, async (_input, init) => { seen = init; return response("{\"user\":true}"); });
    expect(result.status).toBe(200);
    expect(result.body).toBe('{"user":true}');
    expect(seen?.redirect).toBe("error");
    await expect(requestFixedHost("https://example.test/user", {
      method: "GET", headers: {}, signal: signal(), allowedHosts: ["api.raindrop.io"], timeoutMs: 1_000, maxBodyBytes: 64,
    }, async () => response("no"))).rejects.toThrow(/allowlisted/);
  });

  it("rejects an unknown-length body after the fixed bound", async () => {
    await expect(requestFixedHost("https://api.typesafe.ai/v1/systemone", {
      method: "POST", headers: {}, body: "{}", signal: signal(),
      allowedHosts: ["api.typesafe.ai"], timeoutMs: 1_000, maxBodyBytes: 4,
    }, async () => response("12345"))).rejects.toThrow(/bounded body/);
  });
});
