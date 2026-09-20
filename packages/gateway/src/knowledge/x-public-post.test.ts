import { describe, expect, it, vi } from "vitest";
import { lookupPublicXPost, xPostIdentity, xEmbedToken, type XPostResponse } from "./x-public-post.js";
import { readPublicXPost } from "./source-capture.js";

const url = "https://x.com/synthetic/status/123456789";
const fx = (extra = {}) => JSON.stringify({ code: 200, tweet: { id: "123456789", text: "Synthetic full post", author: { screen_name: "synthetic", protected: false }, is_note_tweet: false, ...extra } });
const signal = () => new AbortController().signal;

describe("public X hydration", () => {
  it.each(["https://x.com/i/bookmarks", "https://evil.test/synthetic/status/123", "https://x.com.evil.test/a/status/123", "https://user:pass@x.com/a/status/123", "http://x.com/a/status/123", "https://x.com:444/a/status/123", "https://x.com/a/status/123?auth_token=synthetic", "https://x.com/a/status/123?key=synthetic"])("rejects unsafe/non-post input %s before network", async input => {
    const get = vi.fn();
    await expect(lookupPublicXPost(input, get, signal())).rejects.toThrow();
    expect(get).not.toHaveBeenCalled();
  });
  it("strips tracking, canonicalizes aliases, and never forwards credentials", async () => {
    const get = vi.fn(async () => ({ status: 200, body: fx() }));
    const result = await lookupPublicXPost("https://mobile.twitter.com/other/status/123456789/photo/1?s=20#foo", get, signal());
    expect(result.url).toBe("https://x.com/i/web/status/123456789");
    expect(result.disposition).toBe("complete");
    expect(result.raw).toBe(fx());
    expect(get).toHaveBeenCalledTimes(1);
    expect(get.mock.calls[0]?.[0]).toBe("https://api.fxtwitter.com/status/123456789");
  });
  it.each([{ status: 429 }, { status: 503 }, { status: 200, body: "{}" }, { status: 200, body: fx({ id: "987" }) }, { status: 200, body: fx(), truncated: true }, { status: 200, body: fx({ text: "" }) }, { status: 200, body: fx({ author: { protected: true } }) }])("uses bounded syndication fallback for %j", async first => {
    const get = vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce({ status: 200, body: JSON.stringify({ id_str: "123456789", text: "Synthetic fallback" }) });
    const result = await lookupPublicXPost(url, get, signal());
    expect(result).toMatchObject({ provider: "x-syndication", disposition: "partial", text: "Synthetic fallback" });
    expect(get).toHaveBeenCalledTimes(2);
    expect(get.mock.calls[1]?.[0]).toBe(`https://cdn.syndication.twimg.com/tweet-result?id=123456789&lang=en&token=${xEmbedToken("123456789")}`);
    expect(result.attempts).toHaveLength(2);
  });
  it.each([{ media: { videos: [] } }, { article: { title: "Article", preview_text: "not full" } }, { quote: { id: "987", text: "quote" } }, { is_note_tweet: true }])("keeps richer Fx evidence but labels unverified coverage %j", async extra => {
    const get = vi.fn(async () => ({ status: 200, body: fx(extra) }));
    const result = await lookupPublicXPost(url, get, signal());
    expect(result.disposition).toBe("partial");
    expect(result.id).toBe("123456789");
    expect(result.raw).toBe(fx(extra));
    expect(get).toHaveBeenCalledTimes(1);
  });
  it("reports provider cooldown without retrying it", async () => {
    const get = vi.fn().mockResolvedValueOnce({ status: 429, retryAfter: "120" }).mockResolvedValueOnce({ status: 503 });
    const before = Date.now();
    const result = await lookupPublicXPost(url, get, signal());
    expect(Date.parse(result.attempts[0]!.retryAt!)).toBeGreaterThanOrEqual(before + 120_000);
    expect(get).toHaveBeenCalledTimes(2);
  });
  it("reports failure, never an empty library or fabricated success", async () => {
    const get = vi.fn(async (): Promise<XPostResponse> => { throw new Error("secret provider body must not escape"); });
    const result = await lookupPublicXPost(url, get, signal());
    expect(result.disposition).toBe("inaccessible");
    expect(result.text).toBeUndefined();
    expect(JSON.stringify(result)).not.toContain("secret");
    expect(get).toHaveBeenCalledTimes(2);
  });
  it("does not dispatch fallback after caller cancellation", async () => {
    const controller = new AbortController();
    const get = vi.fn(async () => { controller.abort(); return { status: 503 }; });
    await expect(lookupPublicXPost(url, get, controller.signal)).rejects.toThrow();
    expect(get).toHaveBeenCalledTimes(1);
  });
  it("uses the safe transport with no redirects, auth headers, or browser cookies", async () => {
    const fetcher = vi.fn(async (_url: string | URL, init?: RequestInit) => {
      expect(init?.headers).toBeUndefined();
      expect(init?.redirect).toBe("manual");
      return new Response(fx(), { headers: { "content-type": "application/json" } });
    });
    const result = await readPublicXPost(url, { fetcher, resolveHost: async () => ["93.184.216.34"] });
    expect(result.provider).toBe("fxtwitter");
  });
  it("refuses private DNS and redirect destinations without sending a request there", async () => {
    const seen: string[] = [];
    const result = await readPublicXPost(url, { resolveHost: async host => host === "api.fxtwitter.com" ? ["93.184.216.34"] : ["127.0.0.1"], fetcher: async input => { seen.push(String(input)); return new Response(null, { status: 302, headers: { location: "https://evil.test/private" } }); } });
    expect(result.disposition).toBe("inaccessible");
    expect(seen).toEqual(["https://api.fxtwitter.com/status/123456789"]);
  });
  it("cancels a stalled response body without dispatching fallback", async () => {
    vi.useFakeTimers();
    try {
      const fetcher = vi.fn(async (_input: string | URL, init?: RequestInit) => {
        if (fetcher.mock.calls.length === 1) return new Response(new ReadableStream({ start(controller) { init?.signal?.addEventListener("abort", () => controller.error(new Error("aborted"))); } }));
        return new Response(JSON.stringify({ id_str: "123456789", text: "fallback" }));
      });
      // AbortSignal.timeout uses native timers, so exercise explicit caller cancellation instead.
      const controller = new AbortController();
      const pending = readPublicXPost(url, { fetcher, resolveHost: async () => ["93.184.216.34"], signal: controller.signal });
      const check = expect(pending).rejects.toThrow();
      await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
      controller.abort();
      await check;
      expect(fetcher).toHaveBeenCalledTimes(1);
    } finally { vi.useRealTimers(); }
  });
  it("accepts canonical web-status permalinks", () => expect(xPostIdentity("https://x.com/i/web/status/123456789").id).toBe("123456789"));
});
