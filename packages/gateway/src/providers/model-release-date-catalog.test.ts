import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ModelReleaseDateCatalog } from "./model-release-date-catalog.js";

// Failure modes guarded here: 1) a model-list lookup performs network I/O; 2) fetched dates fail to override baseline or aliases; 3) concurrent callers duplicate requests; 4) freshness/force behavior regresses; 5) a 304 damages persisted dates; 6) failed or invalid responses replace prior dates; 7) corrupt persistence crashes startup; 8) persisted dates disappear after restart; 9) calendar-invalid dates enter the overlay; 10) newly served providers remain conditionally stale; 11) PI_OFFLINE is ignored.
describe("ModelReleaseDateCatalog", () => {
  let root = "";
  afterEach(async () => {
    vi.unstubAllGlobals();
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
  });
  async function fixture() {
    if (!root) root = await mkdtemp(join(tmpdir(), "release-dates-"));
    return new ModelReleaseDateCatalog({
      tronHome: root,
      baseline: { "anthropic/known": "2025-01-01" },
      aliases: { cortex: "anthropic" },
      providers: () => ["anthropic"],
      log: vi.fn(),
    });
  }
  const response = (payload: unknown, headers: Record<string, string> = {}) => new Response(JSON.stringify(payload), { status: 200, headers });
  const catalogData = { anthropic: { models: { "claude-sonnet-5-5": { release_date: "2026-09-28" }, known: { release_date: "2025-02" } } } };

  it("serves reads without network and updates baseline plus aliases only after refresh", async () => {
    const catalog = await fixture();
    const fetcher = vi.fn(async () => response(catalogData));
    vi.stubGlobal("fetch", fetcher);
    expect(await catalog.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBeUndefined();
    expect(fetcher).not.toHaveBeenCalled();
    await catalog.refresh({ force: true });
    expect(await catalog.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBe("2026-09-28");
    expect(await catalog.modelReleaseDate("cortex", "claude-sonnet-5-5")).toBe("2026-09-28");
    expect(await catalog.modelReleaseDate("anthropic", "known")).toBe("2025-02-01");
    catalog.dispose();
  });

  it("shares in-flight requests, skips fresh data unless forced, and restores persistence", async () => {
    const catalog = await fixture();
    let resolve!: (value: Response) => void;
    const fetcher = vi.fn(() => fetcher.mock.calls.length === 1
      ? new Promise<Response>(r => { resolve = r; })
      : Promise.resolve(response(catalogData, { etag: '"release-2"' })));
    vi.stubGlobal("fetch", fetcher);
    const one = catalog.refresh({ force: true });
    const two = catalog.refresh({ force: true });
    await vi.waitFor(() => expect(fetcher).toHaveBeenCalledOnce());
    resolve(response(catalogData, { etag: '"release-1"' }));
    await Promise.all([one, two]);
    await catalog.refresh();
    expect(fetcher).toHaveBeenCalledOnce();
    await catalog.refresh({ force: true });
    expect(fetcher).toHaveBeenCalledTimes(2);
    catalog.dispose();
    const restored = await fixture();
    const offlineFetch = vi.fn(); vi.stubGlobal("fetch", offlineFetch);
    expect(await restored.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBe("2026-09-28");
    expect(offlineFetch).not.toHaveBeenCalled();
    restored.dispose();
  });

  it("retains prior dates after failed and invalid responses and tolerates corrupt persisted state", async () => {
    const catalog = await fixture();
    vi.stubGlobal("fetch", vi.fn(async () => response(catalogData)));
    await catalog.refresh({ force: true });
    vi.stubGlobal("fetch", vi.fn(async () => response({ anthropic: { models: { broken: { release_date: "2025-02-30" } } } })));
    await expect(catalog.refresh({ force: true })).resolves.toMatchObject({ updated: 0, error: expect.any(String) });
    expect(await catalog.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBe("2026-09-28");
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("network down"); }));
    await expect(catalog.refresh({ force: true })).resolves.toMatchObject({ updated: 0, error: expect.any(String) });
    expect(await catalog.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBe("2026-09-28");
    catalog.dispose();
    await writeFile(join(root, "gateway", "model-release-dates.json"), "not json");
    const corrupt = await fixture();
    expect(await corrupt.modelReleaseDate("anthropic", "known")).toBe("2025-01-01");
    corrupt.dispose();
  });

  it("turns drain admission and timeout failures into bounded refresh results", async () => {
    const catalog = new ModelReleaseDateCatalog({
      tronHome: root || (root = await mkdtemp(join(tmpdir(), "release-dates-drain-"))),
      baseline: { "anthropic/known": "2025-01-01" }, providers: () => ["anthropic"], log: vi.fn(),
      workRegistry: { runtimeEpoch: "epoch", begin: () => { throw new Error("busy"); } },
    });
    vi.stubGlobal("fetch", vi.fn());
    await expect(catalog.refresh({ force: true })).resolves.toMatchObject({ updated: 0, error: "busy" });
    catalog.dispose();

    const timed = await fixture();
    vi.useFakeTimers();
    const fetcher = vi.fn(async (_url: string, init?: RequestInit) => await new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
    }));
    vi.stubGlobal("fetch", fetcher);
    const refresh = timed.refresh({ force: true });
    await vi.waitFor(() => expect(fetcher).toHaveBeenCalledOnce());
    await vi.advanceTimersByTimeAsync(60_000);
    await expect(refresh).resolves.toMatchObject({ updated: 0, error: expect.stringContaining("timed out") });
    vi.useRealTimers();
    timed.dispose();
  });

  it("rejects oversized responses without replacing persisted dates", async () => {
    const catalog = await fixture();
    vi.stubGlobal("fetch", vi.fn(async () => response(catalogData)));
    await catalog.refresh({ force: true });
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new Uint8Array(32 * 1024 * 1024 + 1)); controller.close(); },
    });
    vi.stubGlobal("fetch", vi.fn(async () => new Response(body)));
    await expect(catalog.refresh({ force: true })).resolves.toMatchObject({ updated: 0, error: expect.stringContaining("exceeds 32 MiB") });
    expect(await catalog.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBe("2026-09-28");
    catalog.dispose();
  });

  it("accepts 304 without losing persisted dates and honors provider coverage", async () => {
    const catalog = await fixture();
    let conditionalHeaders: HeadersInit | undefined;
    vi.stubGlobal("fetch", vi.fn(async (_url: string, init?: RequestInit) => {
      conditionalHeaders = init?.headers;
      return response(catalogData, { etag: '"catalog-1"' });
    }));
    await catalog.refresh({ force: true });
    vi.stubGlobal("fetch", vi.fn(async (_url: string, init?: RequestInit) => {
      conditionalHeaders = init?.headers;
      return new Response(null, { status: 304 });
    }));
    await catalog.refresh({ force: true });
    expect(new Headers(conditionalHeaders).get("if-none-match")).toBe('"catalog-1"');
    expect(await catalog.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBe("2026-09-28");
    vi.stubGlobal("fetch", vi.fn(async (_url: string, init?: RequestInit) => {
      conditionalHeaders = init?.headers;
      return response(catalogData, { etag: '"catalog-2"' });
    }));
    await catalog.refresh({ force: true, providers: ["anthropic", "new-extension"] });
    expect(new Headers(conditionalHeaders).has("if-none-match")).toBe(false);
    catalog.dispose();
  });

  it("serves vendored snapshot dates and aliases through the catalog owner", async () => {
    const catalog = new ModelReleaseDateCatalog({ tronHome: root || (root = await mkdtemp(join(tmpdir(), "release-dates-baseline-"))), providers: () => [], log: vi.fn() });
    const snapshot = (await import("./model-release-dates.json", { with: { type: "json" } })).default as Record<string, string>;
    const aliases = (await import("./model-release-date-aliases.json", { with: { type: "json" } })).default as Record<string, string>;
    expect(Object.keys(snapshot).length).toBeGreaterThan(0);
    for (const [source, target] of Object.entries(aliases)) {
      const sample = Object.entries(snapshot).find(([key]) => key.startsWith(`${target}/`));
      expect(sample).toBeDefined();
      expect(await catalog.modelReleaseDate(source, sample![0].slice(target.length + 1))).toBe(sample![1]);
    }
    catalog.dispose();
  });

  it("honors truthy PI_OFFLINE values without making a request", async () => {
    const catalog = await fixture();
    const fetcher = vi.fn();
    vi.stubGlobal("fetch", fetcher);
    vi.stubEnv("PI_OFFLINE", "yes");
    await expect(catalog.refresh({ force: true })).resolves.toMatchObject({ updated: 0, error: "offline mode" });
    expect(fetcher).not.toHaveBeenCalled();
    vi.unstubAllEnvs();
    catalog.dispose();
  });
});
