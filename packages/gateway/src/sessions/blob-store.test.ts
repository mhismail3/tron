import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { BlobStore, type BlobLease } from "./blob-store.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function root(): Promise<string> {
  const value = await mkdtemp(join(tmpdir(), "tron-blob-"));
  roots.push(value);
  return value;
}

async function leaseData(lease: BlobLease): Promise<Buffer> {
  const chunks: Buffer[] = [];
  try {
    for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
    return Buffer.concat(chunks);
  } finally {
    await lease.release();
  }
}

describe("bounded blob store", () => {
  it("deduplicates exact content without consuming another slot", () => {
    const store = new BlobStore({ maximumItemBytes: 4, maximumItems: 1, maximumTotalBytes: 4 });
    const first = store.registerData(Buffer.from("same"), "text/plain");
    const second = store.registerData(Buffer.from("same"), "text/plain");
    expect(second).toBe(first);
    expect(store.get(first).data.toString()).toBe("same");
  });

  it("bounds MIME metadata and rejects controls without changing valid content identities", () => {
    const store = new BlobStore({ maximumItemBytes: 3, maximumItems: 2, maximumTotalBytes: 6 });
    expect(() => store.registerData(Buffer.from("one"), "x".repeat(1_025))).toThrow(/metadata limit/);
    expect(() => store.registerData(Buffer.from("one"), "text/plain\0image/png")).toThrow(/control/);
    expect(() => store.registerData(Buffer.from("one"), "text/plain\r\nmalformed")).toThrow(/control/);
    const id = store.registerData(Buffer.from("one"), "text/plain; charset=utf-8");
    expect(id).toBe(createHash("sha256")
      .update("text/plain; charset=utf-8")
      .update("\0")
      .update("one")
      .digest("base64url"));
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

  it("reserves capacity before concurrent distinct file copies", async () => {
    const home = await root();
    const directory = join(home, "blobs");
    const store = new BlobStore(
      { maximumItemBytes: 8, maximumItems: 1, maximumTotalBytes: 8 },
      Date.now,
      directory,
    );
    await store.initialize();
    const firstSource = join(home, "first-concurrent");
    const secondSource = join(home, "second-concurrent");
    await writeFile(firstSource, "first");
    await writeFile(secondSource, "second");
    const results = await Promise.allSettled([
      store.registerFile(firstSource, "text/plain"),
      store.registerFile(secondSource, "text/plain"),
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.find((result) => result.status === "rejected"))
      .toMatchObject({ reason: { code: "busy", retryable: true } });
    expect((await readdir(directory)).filter((name) => name.startsWith("blob-"))).toHaveLength(1);
    await store.dispose();
  });

  it("adopts export files without retaining the source and deduplicates exact content", async () => {
    const home = await root();
    const directory = join(home, "blobs");
    const store = new BlobStore(
      { maximumItemBytes: 8, maximumItems: 2, maximumTotalBytes: 16 },
      Date.now,
      directory,
    );
    await store.initialize();
    const firstSource = join(home, "first");
    const secondSource = join(home, "second");
    await writeFile(firstSource, "content");
    await writeFile(secondSource, "content");
    const first = await store.registerFile(firstSource, "text/plain");
    const second = await store.registerFile(secondSource, "text/plain");
    expect(second).toBe(first);
    await rm(firstSource);
    await rm(secondSource);
    expect((await leaseData(await store.acquire(first))).toString()).toBe("content");
    expect((await readdir(directory)).filter((name) => name.startsWith("blob-"))).toHaveLength(1);
    await store.dispose();
  });

  it("keeps an active reader alive across expiry and unlinks after idempotent final release", async () => {
    let now = 1;
    const home = await root();
    const directory = join(home, "blobs");
    const store = new BlobStore(
      { maximumItemBytes: 8, maximumItems: 1, maximumTotalBytes: 8 },
      () => now,
      directory,
    );
    await store.initialize();
    const source = join(home, "source");
    await writeFile(source, "content");
    const id = await store.registerFile(source, "text/plain");
    const first = await store.acquire(id);
    const second = await store.acquire(id);
    now = 12;
    store.prune(10);
    await expect(store.acquire(id)).rejects.toMatchObject({ code: "not_found" });
    expect((await leaseData(first)).toString()).toBe("content");
    expect((await leaseData(second)).toString()).toBe("content");
    await second.release();
    expect((await readdir(directory)).filter((name) => name.startsWith("blob-"))).toEqual([]);
    await store.dispose();
  });

  it("drains registration and cannot recreate or publish storage after disposal", async () => {
    const home = await root();
    const directory = join(home, "blobs");
    const store = new BlobStore(
      { maximumItemBytes: 8, maximumItems: 1, maximumTotalBytes: 8 },
      Date.now,
      directory,
    );
    await store.initialize();
    const source = join(home, "dispose-source");
    await writeFile(source, "content");
    const registration = store.registerFile(source, "text/plain");
    const disposal = store.dispose();
    await expect(registration).rejects.toMatchObject({ code: "internal" });
    await disposal;
    await expect(readdir(directory)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(store.registerFile(source, "text/plain")).rejects.toMatchObject({ code: "internal" });
    await expect(readdir(directory)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("normalizes a confirmed missing file to not found and retires its identity", async () => {
    const home = await root();
    const directory = join(home, "blobs");
    const store = new BlobStore(
      { maximumItemBytes: 8, maximumItems: 1, maximumTotalBytes: 8 },
      Date.now,
      directory,
    );
    await store.initialize();
    const source = join(home, "missing-source");
    await writeFile(source, "content");
    const id = await store.registerFile(source, "text/plain");
    const body = (await readdir(directory)).find((name) => name.startsWith("blob-"));
    expect(body).toBeDefined();
    await rm(join(directory, body!));
    await expect(store.acquire(id)).rejects.toMatchObject({ code: "not_found" });
    await expect(store.acquire(id)).rejects.toMatchObject({ code: "not_found" });
    await store.dispose();
  });

  it("does not retire a blob for a transient descriptor failure", async () => {
    const home = await root();
    const directory = join(home, "blobs");
    const store = new BlobStore(
      { maximumItemBytes: 8, maximumItems: 1, maximumTotalBytes: 8 },
      Date.now,
      directory,
    );
    await store.initialize();
    const source = join(home, "permission-source");
    await writeFile(source, "content");
    const id = await store.registerFile(source, "text/plain");
    const body = (await readdir(directory)).find((name) => name.startsWith("blob-"));
    expect(body).toBeDefined();
    const path = join(directory, body!);
    await chmod(path, 0o000);
    await expect(store.acquire(id)).rejects.toMatchObject({ code: "EACCES" });
    await chmod(path, 0o600);
    expect((await leaseData(await store.acquire(id))).toString()).toBe("content");
    await store.dispose();
  });

  it("scavenges transient startup files and removes owned storage on dispose", async () => {
    const home = await root();
    const directory = join(home, "blobs");
    await mkdir(directory);
    await writeFile(join(directory, "stale"), "stale");
    const store = new BlobStore(
      { maximumItemBytes: 8, maximumItems: 1, maximumTotalBytes: 8 },
      Date.now,
      directory,
    );
    await store.initialize();
    expect(await readdir(directory)).toEqual([]);
    const source = join(home, "source");
    await writeFile(source, "value");
    await store.registerFile(source, "text/plain");
    await store.dispose();
    await expect(readFile(directory)).rejects.toMatchObject({ code: "ENOENT" });
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
