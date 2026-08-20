import { mkdirSync, writeFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { UploadStore } from "./upload-store.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function root(): Promise<string> {
  const value = await mkdtemp(join(tmpdir(), "tron-upload-"));
  roots.push(value);
  return value;
}

describe("UploadStore", () => {
  it("passes images as Pi image content and documents as bounded path envelopes", async () => {
    const store = new UploadStore(await root(), 1024);
    const image = await store.save("photo.png", "image/png", Buffer.from("image"));
    const document = await store.save("notes.txt", "text/plain", Buffer.from("text"));
    await expect(store.acquire(document.id)).rejects.toMatchObject({ code: "not_found" });
    const materialized = await store.materialize([image.id, document.id], "session");
    expect(materialized.images[0]?.mimeType).toBe("image/png");
    expect(materialized.photoCount).toBe(1);
    expect(materialized.fileAttachmentCount).toBe(1);
    expect(materialized.envelope).toContain("<attachment");
    expect(materialized.envelope).toContain("notes.txt");
    const lease = await store.acquire(document.id);
    const chunks: Buffer[] = [];
    for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
    await lease.release();
    expect(Buffer.concat(chunks).toString("utf8")).toBe("text");
    expect(lease).toMatchObject({ name: "notes.txt", mimeType: "text/plain", size: 4 });
    await expect(store.materialize([image.id], "other-session")).rejects.toMatchObject({ code: "conflict" });

    await store.removeSession("session");
    await expect(store.acquire(document.id)).rejects.toMatchObject({ code: "not_found" });
    await expect(store.materialize([image.id], "session")).rejects.toMatchObject({ code: "not_found" });
  });

  it("streams request chunks into atomic owned files without retaining a body buffer", async () => {
    const home = await root();
    const store = new UploadStore(home, 8, { maximumAggregateBytes: 16 });
    async function* chunks(): AsyncGenerator<Buffer> {
      yield Buffer.from("1234");
      yield Buffer.from("5678");
    }

    const upload = await store.saveStream("stream.txt", "text/plain", chunks(), 8);
    expect(upload.size).toBe(8);
    expect(await readFile(upload.path, "utf8")).toBe("12345678");
    expect(await readdir(join(home, "gateway", "upload-bodies"))).toEqual([]);
  });

  it("cleans interrupted, oversized, and declared-size-mismatched staged bodies", async () => {
    const home = await root();
    const store = new UploadStore(home, 8, { maximumAggregateBytes: 8 });
    await expect(store.saveStream("large", "text/plain", [Buffer.from("12345"), Buffer.from("6789")]))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(store.saveStream("short", "text/plain", [Buffer.from("1234")], 8))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(store.saveStream("interrupted", "text/plain", (async function* () {
      yield Buffer.from("1234");
      throw new Error("connection closed");
    })(), 8)).rejects.toThrow("connection closed");
    expect(await readdir(join(home, "gateway", "upload-bodies"))).toEqual([]);
    await expect(store.save("replacement", "text/plain", Buffer.from("12345678")))
      .resolves.toMatchObject({ size: 8 });
  });

  it("fails closed without traversing a symlinked staging root", async () => {
    const home = await root();
    const outside = join(home, "outside-staging");
    await mkdir(outside);
    await writeFile(join(outside, "keep"), "keep");
    await mkdir(join(home, "gateway"));
    await symlink(outside, join(home, "gateway", "upload-bodies"));
    const store = new UploadStore(home, 8);

    await expect(store.save("value", "text/plain", Buffer.from("value")))
      .rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(outside, "keep"), "utf8")).toBe("keep");
  });

  it("fails closed without traversing a symlinked final upload root", async () => {
    const home = await root();
    const outside = join(home, "outside-uploads");
    await mkdir(outside);
    await writeFile(join(outside, "keep"), "keep");
    await mkdir(join(home, "gateway"));
    await symlink(outside, join(home, "gateway", "uploads"));
    const store = new UploadStore(home, 8);

    await expect(store.save("value", "text/plain", Buffer.from("value")))
      .rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(outside, "keep"), "utf8")).toBe("keep");
  });

  it("reserves aggregate quota before consuming concurrent upload streams", async () => {
    const store = new UploadStore(await root(), 8, { maximumAggregateBytes: 8 });
    let releaseFirst!: () => void;
    const holdFirst = new Promise<void>((resolve) => { releaseFirst = resolve; });
    let firstStarted!: () => void;
    const started = new Promise<void>((resolve) => { firstStarted = resolve; });
    const first = store.saveStream("first", "text/plain", (async function* () {
      firstStarted();
      yield Buffer.from("1234");
      await holdFirst;
      yield Buffer.from("5678");
    })(), 8);
    await started;
    let secondConsumed = false;
    const second = store.saveStream("second", "text/plain", (async function* () {
      secondConsumed = true;
      yield Buffer.from("12345678");
    })(), 8);
    await expect(second).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(secondConsumed).toBe(false);
    releaseFirst();
    await expect(first).resolves.toMatchObject({ size: 8 });
  });

  it("bounds concurrent body accumulation and releases admission exactly once", async () => {
    const store = new UploadStore(await root(), 8, { maximumAggregateBytes: 32 });
    const first = store.beginBodyAdmission();
    const second = store.beginBodyAdmission();
    expect(() => store.beginBodyAdmission()).toThrow(/Concurrent upload bodies/);
    first();
    first();
    const replacement = store.beginBodyAdmission();
    replacement();
    second();
  });

  it("scopes body admission across success, failure, and concurrent rejection", async () => {
    const store = new UploadStore(await root(), 8, { maximumAggregateBytes: 16 });
    let reject!: (error: Error) => void;
    const held = store.withBodyAdmission(async () => new Promise<never>((_, rejectOperation) => {
      reject = rejectOperation;
    }));
    await expect(store.withBodyAdmission(async () => "second")).rejects.toMatchObject({ code: "busy" });
    reject(new Error("read failed"));
    await expect(held).rejects.toThrow("read failed");
    await expect(store.withBodyAdmission(async () => "recovered")).resolves.toBe("recovered");
  });

  it("serializes aggregate count and byte admission without partial folders", async () => {
    const store = new UploadStore(await root(), 8, {
      maximumEntries: 1,
      maximumAggregateBytes: 8,
    });
    const results = await Promise.allSettled([
      store.save("first", "text/plain", Buffer.from("12345678")),
      store.save("second", "text/plain", Buffer.from("12345678")),
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejection = results.find((result) => result.status === "rejected");
    expect(rejection).toMatchObject({ reason: { code: "busy", retryable: true } });
  });

  it("prunes expired unclaimed and malformed entries before quota admission", async () => {
    let now = 1_000;
    const home = await root();
    const store = new UploadStore(home, 8, {
      maximumEntries: 1,
      maximumAggregateBytes: 8,
      maximumUnclaimedAgeMs: 100,
      now: () => now,
    });
    const expired = await store.save("expired", "text/plain", Buffer.from("12345678"));
    const malformed = join(home, "gateway", "uploads", "malformed");
    const oversized = join(home, "gateway", "uploads", "oversized");
    await Promise.all([mkdir(malformed, { recursive: true }), mkdir(oversized, { recursive: true })]);
    await writeFile(join(malformed, "metadata.json"), "not-json");
    await writeFile(join(oversized, "metadata.json"), "x".repeat(64 * 1_024 + 1));
    now = 1_101;

    await expect(store.materialize([expired.id], "session")).rejects.toMatchObject({ code: "not_found" });
    await expect(store.save("replacement", "text/plain", Buffer.from("12345678"))).resolves.toMatchObject({
      name: "replacement",
      size: 8,
    });
    expect(await readdir(join(home, "gateway", "uploads"))).not.toEqual(expect.arrayContaining(["malformed", "oversized"]));
  });

  it("removes oversized metadata on direct lookup and returns not found", async () => {
    const home = await root();
    const store = new UploadStore(home, 16);
    const upload = await store.save("value", "text/plain", Buffer.from("value"));
    const folder = join(home, "gateway", "uploads", upload.id);
    await writeFile(join(folder, "metadata.json"), "x".repeat(64 * 1_024 + 1));

    await expect(store.materialize([upload.id], "session")).rejects.toMatchObject({ code: "not_found" });
    expect(await readdir(join(home, "gateway", "uploads"))).not.toContain(upload.id);
  });

  it("rejects a symlinked upload child on direct lookup without touching its target", async () => {
    const home = await root();
    const store = new UploadStore(home, 16);
    const upload = await store.save("value", "text/plain", Buffer.from("value"));
    const folder = join(home, "gateway", "uploads", upload.id);
    const outside = join(home, "outside-upload");
    await rename(folder, outside);
    await symlink(outside, folder);

    await expect(store.materialize([upload.id], "session")).rejects.toMatchObject({ code: "not_found" });
    expect(await readFile(join(outside, "content"), "utf8")).toBe("value");
    expect(await readdir(join(home, "gateway", "uploads"))).not.toContain(upload.id);
  });

  it("removes upload metadata with a noncanonical timestamp", async () => {
    const home = await root();
    const store = new UploadStore(home, 16);
    const upload = await store.save("value", "text/plain", Buffer.from("value"));
    const folder = join(home, "gateway", "uploads", upload.id);
    const metadataPath = join(folder, "metadata.json");
    const metadata = JSON.parse(await readFile(metadataPath, "utf8"));
    metadata.createdAt = metadata.createdAt.replace(/\.\d{3}Z$/, "Z");
    await writeFile(metadataPath, JSON.stringify(metadata));

    await expect(store.materialize([upload.id], "session")).rejects.toMatchObject({ code: "not_found" });
    expect(await readdir(join(home, "gateway", "uploads"))).not.toContain(upload.id);
  });

  it("admits upload metadata at the exact encoded byte ceiling", async () => {
    const home = await root();
    const store = new UploadStore(home, 16);
    const upload = await store.save("value", "text/plain", Buffer.from("value"));
    const metadataPath = join(home, "gateway", "uploads", upload.id, "metadata.json");
    const compact = JSON.stringify(JSON.parse(await readFile(metadataPath, "utf8")));
    const exact = `${compact}${" ".repeat(64 * 1_024 - Buffer.byteLength(compact))}`;
    expect(Buffer.byteLength(exact)).toBe(64 * 1_024);
    await writeFile(metadataPath, exact);

    await expect(store.materialize([upload.id], "session")).resolves.toMatchObject({
      envelope: expect.stringContaining("value"),
    });
  });

  it("replaces partial or symlinked import staging inside the owned folder", async () => {
    const home = await root();
    const store = new UploadStore(home, 32);
    const upload = await store.save("session.jsonl", "application/jsonl", Buffer.from("canonical"));
    const outside = join(home, "outside");
    await writeFile(outside, "outside");
    const staged = join(home, "gateway", "uploads", upload.id, `tron-import-${upload.id}.jsonl`);
    await symlink(outside, staged);

    const result = await store.prepareSessionImport(upload.id);
    expect(result.startsWith(`${await realpath(join(home, "gateway", "uploads", upload.id))}/`)).toBe(true);
    expect(await readFile(result, "utf8")).toBe("canonical");
    expect(await readFile(outside, "utf8")).toBe("outside");
  });

  it("cleans content whose actual size no longer matches metadata", async () => {
    const store = new UploadStore(await root(), 16);
    const upload = await store.save("image.png", "image/png", Buffer.from("small"));
    await writeFile(upload.path, "a larger replacement");
    await expect(store.materialize([upload.id], "session")).rejects.toMatchObject({ code: "not_found" });
  });

  it("retries UUID collisions without deleting the existing folder", async () => {
    const home = await root();
    const first = "00000000-0000-0000-0000-000000000001";
    const second = "00000000-0000-0000-0000-000000000002";
    let calls = 0;
    const collisionFolder = join(home, "gateway", "uploads", first);
    const store = new UploadStore(home, 16, {
      uuid: () => {
        calls += 1;
        if (calls === 1) {
          mkdirSync(collisionFolder, { recursive: true });
          writeFileSync(join(collisionFolder, "marker"), "keep");
          return first;
        }
        return second;
      },
    });

    const upload = await store.save("value", "text/plain", Buffer.from("value"));
    expect(upload.id).toBe(second);
    expect(await readFile(join(collisionFolder, "marker"), "utf8")).toBe("keep");
  });

  it("rejects prompt attachment aggregates before image materialization", async () => {
    const store = new UploadStore(await root(), 8, {
      maximumEntries: 4,
      maximumAggregateBytes: 32,
    });
    const first = await store.save("first.png", "image/png", Buffer.from("12345"));
    const second = await store.save("second.png", "image/png", Buffer.from("6789"));
    await expect(store.materialize([first.id, second.id], "session")).rejects.toMatchObject({
      code: "invalid_request",
    });
    await expect(store.materialize([first.id, first.id], "session")).rejects.toMatchObject({
      code: "invalid_request",
    });
  });
});
