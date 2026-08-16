import { describe, expect, it } from "vitest";
import {
  MODEL_CATALOG_MAX_ENCODED_BYTES,
  MODEL_CATALOG_MAX_ITEMS,
  ModelCatalogPager,
  pageCatalog,
} from "./model-pagination.js";

describe("model catalog pagination", () => {
  it("preserves extension models beyond the generic JSON array bound", () => {
    const catalog = Array.from({ length: 1_205 }, (_, index) => `model-${index}`);
    const first = pageCatalog(catalog, undefined, 500);
    const second = pageCatalog(catalog, first.nextCursor, 500);
    const third = pageCatalog(catalog, second.nextCursor, 500);
    expect([...first.items, ...second.items, ...third.items]).toEqual(catalog);
    expect(third.nextCursor).toBeUndefined();
  });

  it("runtime pager reuses one immutable build for every traversal page", async () => {
    const pager = new ModelCatalogPager();
    const owner = {};
    let builds = 0;
    const first = await pager.page(owner, undefined, 2, async () => {
      builds += 1;
      return ["a", "b", "c"];
    });
    const second = await pager.page(owner, first.nextCursor, 2, async () => {
      builds += 1;
      return ["changed"];
    });
    expect([...first.items, ...second.items]).toEqual(["a", "b", "c"]);
    expect(builds).toBe(1);
  });

  it("runtime pager globally evicts the least-recent traversal", async () => {
    const pager = new ModelCatalogPager();
    const traversals: Array<{ owner: object; cursor: string }> = [];
    for (let index = 0; index < 9; index += 1) {
      const owner = {};
      const page = await pager.page(owner, undefined, 1, async () => [`${index}-a`, `${index}-b`]);
      traversals.push({ owner, cursor: page.nextCursor! });
    }
    await expect(pager.page(
      traversals[0]!.owner,
      traversals[0]!.cursor,
      1,
      async () => ["must-not-build"],
    )).rejects.toThrow(/cursor expired/);
    await expect(pager.page(
      traversals[8]!.owner,
      traversals[8]!.cursor,
      1,
      async () => ["must-not-build"],
    )).resolves.toMatchObject({ items: ["8-b"] });
  });

  it("page bytes can reduce an item-limit page without losing continuity", () => {
    const catalog = ["a".repeat(399_000), "b".repeat(399_000), "c".repeat(399_000)];
    const first = pageCatalog(catalog, undefined, 500);
    const second = pageCatalog(catalog, first.nextCursor, 500);
    expect(first.items).toHaveLength(2);
    expect(second.items).toHaveLength(1);
    expect([...first.items, ...second.items]).toEqual(catalog);
  });

  it("rejects changed catalogs instead of mixing offset pages", () => {
    const first = pageCatalog(["a", "b", "c"], undefined, 2);
    expect(() => pageCatalog(["inserted", "a", "b", "c"], first.nextCursor, 2))
      .toThrow(/changed during pagination/);
  });

  it("rejects invalid cursors and unbounded page sizes", () => {
    expect(() => pageCatalog([], "again", 100)).toThrow(/cursor/);
    expect(() => pageCatalog([], 0, 100)).toThrow(/cursor/);
    const cursor = pageCatalog(["a", "b"], undefined, 1).nextCursor!;
    expect(() => pageCatalog(["a", "b"], cursor.replace(/:[0-9]+$/, ":999"), 1)).toThrow(/cursor/);
    expect(() => pageCatalog([], undefined, 501)).toThrow(/limit/);
  });

  it("bounds whole catalog items and encoded bytes before paging", () => {
    expect(() => pageCatalog(
      Array.from({ length: MODEL_CATALOG_MAX_ITEMS + 1 }, (_, index) => index),
      undefined,
      500,
    )).toThrow(/item limit/);
    expect(() => pageCatalog(
      Array.from({ length: 22 }, () => "x".repeat(790_000)),
      undefined,
      500,
    )).toThrow(/encoded byte limit/);
  });
});
