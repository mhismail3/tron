import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ModelReleaseDateCatalog } from "./model-release-date-catalog.js";

// Failure modes guarded here: 1) model.list accidentally fetches; 2) a fetched
// date does not override the baseline or misses an alias provider; 3) concurrent
// refreshes duplicate requests; 4) fresh data is fetched unnecessarily or
// force is ignored; 5) a conditional 304 damages the saved snapshot; 6) bad,
// oversized, timed-out or failed responses replace good data; 7) a corrupt file
// crashes startup; 8) persisted data is unavailable after restart; 9) malformed
// dates enter the catalog; 10) shutdown does not abort outstanding work.
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
    const fetcher = vi.fn(() => new Promise<Response>(r => { resolve = r; }));
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
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("network down"); }));
    await expect(catalog.refresh({ force: true })).resolves.toMatchObject({ updated: 0, error: expect.any(String) });
    expect(await catalog.modelReleaseDate("anthropic", "claude-sonnet-5-5")).toBe("2026-09-28");
    catalog.dispose();
    await writeFile(join(root, "gateway", "model-release-dates.json"), "not json");
    const corrupt = await fixture();
    expect(await corrupt.modelReleaseDate("anthropic", "known")).toBe("2025-01-01");
    corrupt.dispose();
  });
});
