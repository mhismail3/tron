import { describe, expect, it } from "vitest";
import { pageCatalog } from "./model-pagination.js";

describe("model catalog pagination", () => {
  it("preserves extension models beyond the generic JSON array bound", () => {
    const catalog = Array.from({ length: 1_205 }, (_, index) => `model-${index}`);
    const first = pageCatalog(catalog, undefined, 500);
    const second = pageCatalog(catalog, first.nextCursor, 500);
    const third = pageCatalog(catalog, second.nextCursor, 500);
    expect([...first.items, ...second.items, ...third.items]).toEqual(catalog);
    expect(third.nextCursor).toBeUndefined();
  });

  it("rejects invalid cursors and unbounded page sizes", () => {
    expect(() => pageCatalog([], "again", 100)).toThrow(/cursor/);
    expect(() => pageCatalog([], 0, 501)).toThrow(/limit/);
  });
});
