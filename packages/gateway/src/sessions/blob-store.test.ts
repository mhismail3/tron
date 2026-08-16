import { describe, expect, it } from "vitest";
import { BlobStore } from "./blob-store.js";

describe("bounded blob store", () => {
  it("deduplicates exact content without consuming another slot", () => {
    const store = new BlobStore({ maximumItemBytes: 4, maximumItems: 1, maximumTotalBytes: 4 });
    const first = store.registerData(Buffer.from("same"), "text/plain");
    const second = store.registerData(Buffer.from("same"), "text/plain");
    expect(second).toBe(first);
    expect(store.get(first).data.toString()).toBe("same");
  });

  it("bounds MIME metadata before content hashing", () => {
    const store = new BlobStore({ maximumItemBytes: 3, maximumItems: 2, maximumTotalBytes: 6 });
    expect(() => store.registerData(Buffer.from("one"), "x".repeat(1_025))).toThrow(/metadata limit/);
  });

  it("preflights oversized base64 before decoded admission", () => {
    const store = new BlobStore({ maximumItemBytes: 3, maximumItems: 2, maximumTotalBytes: 6 });
    expect(() => store.register("A".repeat(9), "image/png")).toThrow(/item limit/);
  });

  it("rejects one oversized item without evicting admitted data", () => {
    const store = new BlobStore({ maximumItemBytes: 4, maximumItems: 2, maximumTotalBytes: 8 });
    const retained = store.registerData(Buffer.from("keep"), "text/plain");
    expect(() => store.registerData(Buffer.from("large"), "text/plain")).toThrow(/item limit/);
    expect(store.get(retained).data.toString()).toBe("keep");
  });

  it("rejects capacity overflow without invalidating already projected IDs", () => {
    let now = 1;
    const store = new BlobStore(
      { maximumItemBytes: 4, maximumItems: 2, maximumTotalBytes: 6 },
      () => now,
    );
    const first = store.registerData(Buffer.from("aaa"), "text/plain");
    now += 1;
    const second = store.registerData(Buffer.from("bbb"), "text/plain");
    now += 1;
    store.get(first);
    now += 1;
    expect(() => store.registerData(Buffer.from("ccc"), "text/plain")).toThrow(/temporarily full/);

    expect(store.get(first).data.toString()).toBe("aaa");
    expect(store.get(second).data.toString()).toBe("bbb");
  });

  it("prunes expired values while retaining the exact age boundary", () => {
    let now = 10;
    const store = new BlobStore(
      { maximumItemBytes: 4, maximumItems: 3, maximumTotalBytes: 12 },
      () => now,
    );
    const expired = store.registerData(Buffer.from("old"), "text/plain");
    now = 11;
    const boundary = store.registerData(Buffer.from("new"), "text/plain");
    now = 21;
    store.prune(10);

    expect(() => store.get(expired)).toThrow(/not available/);
    expect(store.get(boundary).data.toString()).toBe("new");
  });
});
