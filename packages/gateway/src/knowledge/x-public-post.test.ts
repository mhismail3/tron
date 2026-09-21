import { describe, expect, it, vi } from "vitest";
import { lookupPublicXPost, xPostIdentity, xEmbedToken, type XPostResponse } from "./x-public-post.js";
import { readPublicXPost } from "./source-capture.js";

const url = "https://x.com/synthetic/status/123456789";
const v2 = (extra: Record<string, unknown> = {}) => JSON.stringify({ code: 200, status: { id: "123456789", text: "Root publication", author: { id: "42", protected: false }, replying_to: null, raw_text: { facets: [] }, ...extra }, thread: [], replies: [], cursor: {} });
const reply = (id: string, author: string, parent: string, text: string, extra: Record<string, unknown> = {}) => ({ id, text, author: { id: author, protected: false }, replying_to: { status: parent }, raw_text: { facets: [] }, ...extra });
const signal = () => new AbortController().signal;

describe("public X v2 hydration", () => {
  it.each(["https://x.com/i/bookmarks", "https://evil.test/synthetic/status/123", "https://x.com.evil.test/a/status/123", "https://user:pass@x.com/a/status/123", "http://x.com/a/status/123", "https://x.com:444/a/status/123", "https://x.com/a/status/123?auth_token=synthetic"]) ("rejects unsafe/non-post input %s before network", async input => {
    const get = vi.fn(); await expect(lookupPublicXPost(input, get, signal())).rejects.toThrow(); expect(get).not.toHaveBeenCalled();
  });
  it("validates the v2 root and selects only explicit same-author parent chains", async () => {
    const body = JSON.stringify({ code: 200, status: { id: "123456789", text: "Root publication", author: { id: "42", protected: false }, replying_to: null, raw_text: { facets: [] } }, thread: [], replies: [
      reply("2", "42", "123456789", "Continuation", { raw_text: { facets: [{ type: "url", replacement: "http://example.test/model" }] } }),
      reply("3", "9", "123456789", "Commenter"), reply("4", "42", "3", "Author answer to commenter"), reply("5", "42", "999", "Missing parent"),
    ], cursor: {} });
    const result = await lookupPublicXPost(url, vi.fn(async () => ({ status: 200, body })), signal(), { coverage: "conversation" });
    expect(result.provider).toBe("fxembed-v2"); expect(result.id).toBe("123456789");
    expect(result.continuations?.map(post => post.id)).toEqual(["2"]);
    expect(result.commentary?.map(post => post.id)).toEqual(["3", "4", "5"]);
    expect(result.linkedReferences).toEqual([{ url: "http://example.test/model", postId: "2", postUrl: "https://x.com/i/web/status/2", role: "continuation" }]);
    expect(result.stopReasons).toContain("missing-parent");
  });
  it("paginates with finite cursor and item bounds, deduplicating repeated pages", async () => {
    const first = JSON.stringify({ code: 200, status: { id: "123456789", text: "Root", author: { id: "42" }, replying_to: null }, thread: [], replies: [reply("2", "42", "123456789", "one")], cursor: { bottom: "next" } });
    const second = JSON.stringify({ code: 200, status: { id: "123456789", text: "Root", author: { id: "42" }, replying_to: null }, thread: [], replies: [reply("2", "42", "123456789", "one"), reply("3", "42", "2", "two")], cursor: {} });
    const get = vi.fn().mockResolvedValueOnce({ status: 200, body: first }).mockResolvedValueOnce({ status: 200, body: second });
    const result = await lookupPublicXPost(url, get, signal(), { coverage: "conversation", maxPages: 2 });
    expect(get).toHaveBeenCalledTimes(2); expect(result.continuations?.map(post => post.id)).toEqual(["2", "3"]); expect(result.rawPages).toHaveLength(2); expect(result.stopReasons).toContain("cursor-exhausted");
  });
  it("uses thread coverage as an ancestor chain and never treats it as forward discovery", async () => {
    const body = JSON.stringify({ code: 200, status: { id: "123456789", text: "Endpoint", author: { id: "42" }, replying_to: { status: "2" } }, thread: [reply("1", "42", "0", "Ancestor"), reply("2", "9", "1", "Other author parent")], replies: [reply("3", "42", "123456789", "Forward")], cursor: {} });
    const result = await lookupPublicXPost(url, vi.fn(async () => ({ status: 200, body })), signal(), { coverage: "thread" });
    expect(result.continuations?.map(post => post.id)).toEqual(["1", "2"]);
    expect(result.continuations?.map(post => post.authorId)).toEqual(["42", "9"]);
    expect(result.limitations.join(" ")).toContain("ancestor chain");
  });
  it("keeps missing-parent coverage incomplete and reports the v2 reason through fallback", async () => {
    const invalidPage = JSON.stringify({ code: 200, status: { id: "123456789", text: "Root", author: { id: "42" } }, thread: [], replies: [reply("2", "42", "404", "orphan")], cursor: {} });
    const result = await lookupPublicXPost(url, vi.fn().mockResolvedValueOnce({ status: 200, body: invalidPage }).mockResolvedValueOnce({ status: 503 }), signal(), { coverage: "conversation" });
    expect(result.coverageComplete).toBe(false);
    expect(result.stopReasons).toContain("cursor-exhausted");
    const fallback = await lookupPublicXPost(url, vi.fn().mockResolvedValueOnce({ status: 503 }).mockResolvedValueOnce({ status: 200, body: JSON.stringify({ id_str: "123456789", text: "Fallback" }) }), signal(), { coverage: "conversation" });
    expect(fallback.stopReasons).toContain("unavailable");
  });
  it("falls back once to syndication without retaining an Fx v1 parser", async () => {
    const syndication = JSON.stringify({ id_str: "123456789", text: "Fallback", entities: { urls: [{ expanded_url: "http://example.test/a" }] } });
    const get = vi.fn().mockResolvedValueOnce({ status: 503 }).mockResolvedValueOnce({ status: 200, body: syndication });
    const result = await lookupPublicXPost(url, get, signal());
    expect(result.provider).toBe("x-syndication"); expect(result.disposition).toBe("partial"); expect(result.text).toBe("Fallback"); expect(get).toHaveBeenCalledTimes(2); expect(get.mock.calls[1]?.[0]).toContain(`token=${xEmbedToken("123456789")}`);
  });
  it("honors 429 without retrying the provider and retains safe diagnostics", async () => {
    const get = vi.fn().mockResolvedValueOnce({ status: 429, retryAfter: "120" }).mockResolvedValueOnce({ status: 429 });
    const result = await lookupPublicXPost(url, get, signal());
    expect(result.attempts.map(attempt => attempt.outcome)).toEqual(["rate-limited", "rate-limited"]); expect(JSON.stringify(result)).not.toContain("Authorization");
  });
  it("cancels before fallback", async () => {
    const controller = new AbortController(); const get = vi.fn(async () => { controller.abort(); return { status: 503 }; });
    await expect(lookupPublicXPost(url, get, controller.signal)).rejects.toThrow(); expect(get).toHaveBeenCalledTimes(1);
  });
  it("uses the descriptive UA and DNS-pinned safe transport", async () => {
    const fetcher = vi.fn(async (_url: string | URL, init?: RequestInit) => { expect(init?.headers).toEqual({ "user-agent": "Tron/0.1 (public-source-capture)" }); expect(init?.redirect).toBe("manual"); return new Response(v2(), { headers: { "content-type": "application/json" } }); });
    const result = await readPublicXPost(url, { fetcher, resolveHost: async () => ["93.184.216.34"] });
    expect(result.provider).toBe("fxembed-v2"); expect(fetcher).toHaveBeenCalledTimes(1);
  });
  it("accepts declared http links but rejects credential queries", async () => {
    const body = v2({ raw_text: { facets: [{ type: "url", replacement: "http://example.test/guide" }, { type: "url", replacement: "https://bad.test/a?token=no" }] } });
    const result = await lookupPublicXPost(url, vi.fn(async () => ({ status: 200, body })), signal());
    expect(result.linkedUrls).toEqual(["http://example.test/guide"]);
  });
  it("refuses private DNS and redirect destinations without sending a request there", async () => {
    const seen: string[] = [];
    const result = await readPublicXPost(url, { resolveHost: async host => host === "api.fxtwitter.com" ? ["93.184.216.34"] : ["127.0.0.1"], fetcher: async input => { seen.push(String(input)); return new Response(null, { status: 302, headers: { location: "https://evil.test/private" } }); } });
    expect(result.disposition).toBe("inaccessible"); expect(seen).toEqual(["https://api.fxtwitter.com/2/conversation/123456789"]);
  });
  it("accepts canonical web-status permalinks", () => expect(xPostIdentity("https://x.com/i/web/status/123456789").id).toBe("123456789"));
  it("keeps response type usable in failure tests", async () => { const get = vi.fn(async (): Promise<XPostResponse> => { throw new Error("secret"); }); const result = await lookupPublicXPost(url, get, signal()); expect(result.disposition).toBe("inaccessible"); });
});
