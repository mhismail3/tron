import { mkdirSync, writeFileSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
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
    expect(materialized.attachments).toEqual([
      { id: `upload:${image.id}`, name: "photo.png", mimeType: "image/png", size: 5 },
      { id: `upload:${document.id}`, name: "notes.txt", mimeType: "text/plain", size: 4 },
    ]);
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
    const store = new UploadStore(home, 8, { maximumStagingBytes: 16 });
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
    const store = new UploadStore(home, 8, { maximumStagingBytes: 8 });
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

  it("fails closed without traversing a symlinked content-addressed object root", async () => {
    const home = await root();
    const outside = join(home, "outside-objects");
    await mkdir(outside);
    await writeFile(join(outside, "keep"), "keep");
    await mkdir(join(home, "gateway"));
    await symlink(outside, join(home, "gateway", "upload-objects"));
    const store = new UploadStore(home, 8);

    await expect(store.save("value", "text/plain", Buffer.from("value")))
      .rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(outside, "keep"), "utf8")).toBe("keep");
  });

  it("reserves aggregate quota before consuming concurrent upload streams", async () => {
    const store = new UploadStore(await root(), 8, { maximumStagingBytes: 8 });
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
    const store = new UploadStore(await root(), 8, { maximumStagingBytes: 32 });
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
    const store = new UploadStore(await root(), 8, { maximumStagingBytes: 16 });
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
      maximumStagingEntries: 1,
      maximumStagingBytes: 8,
    });
    const results = await Promise.allSettled([
      store.save("first", "text/plain", Buffer.from("12345678")),
      store.save("second", "text/plain", Buffer.from("12345678")),
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejection = results.find((result) => result.status === "rejected");
    expect(rejection).toMatchObject({ reason: { code: "busy", retryable: true } });
  });

  it("reports bounded aggregate capacity and a machine-readable rejection reason", async () => {
    const store = new UploadStore(await root(), 8, {
      maximumStagingEntries: 2,
      maximumStagingBytes: 8,
    });
    await store.save("full", "text/plain", Buffer.from("12345678"));

    await expect(store.status()).resolves.toMatchObject({
      entryCount: 1,
      logicalBytes: 8,
      stagingEntryCount: 1,
      maximumStagingEntries: 2,
      stagingLogicalBytes: 8,
      maximumStagingBytes: 8,
      stagingAvailableBytes: 0,
      unclaimedCount: 1,
      claimedCount: 0,
      objectCount: 1,
      objectBytes: 8,
    });
    await expect(store.save("overflow", "text/plain", Buffer.from("1"))).rejects.toMatchObject({
      code: "busy",
      retryable: true,
      details: {
        reason: "staging_bytes",
        stagingLogicalBytes: 8,
        maximumStagingBytes: 8,
        stagingAvailableBytes: 0,
      },
    });
  });

  it("claimed history never consumes the independent staging byte quota", async () => {
    const store = new UploadStore(await root(), 8, {
      maximumStagingBytes: 8,
      maximumStagingEntries: 1,
    });
    const claimed = await store.save("claimed", "text/plain", Buffer.from("12345678"));
    await store.materialize([claimed.id], "session");

    const next = await store.save("next", "text/plain", Buffer.from("abcdefgh"));
    expect(next.size).toBe(8);
    await expect(store.status()).resolves.toMatchObject({
      claimedCount: 1,
      claimedBytes: 8,
      stagingEntryCount: 1,
      stagingLogicalBytes: 8,
      stagingAvailableBytes: 0,
    });
  });

  it("enforces retained entry and logical-byte quotas only when a prompt claims staging", async () => {
    const entryStore = new UploadStore(await root(), 8, {
      maximumStagingBytes: 16,
      maximumRetainedEntries: 1,
      maximumRetainedLogicalBytes: 16,
    });
    const first = await entryStore.save("first", "text/plain", Buffer.from("1234"));
    const second = await entryStore.save("second", "text/plain", Buffer.from("5678"));
    await entryStore.materialize([first.id], "session-a");
    await expect(entryStore.materialize([second.id], "session-b")).rejects.toMatchObject({
      code: "busy", details: { reason: "retained_entries" },
    });
    // Retained pressure never blocks independent staging admission.
    await expect(entryStore.save("third", "text/plain", Buffer.from("90")))
      .resolves.toMatchObject({ size: 2 });

    const byteStore = new UploadStore(await root(), 4, {
      maximumStagingBytes: 8,
      maximumRetainedEntries: 4,
      maximumRetainedLogicalBytes: 4,
    });
    const retained = await byteStore.save("retained", "text/plain", Buffer.from("123"));
    const overflow = await byteStore.save("overflow", "text/plain", Buffer.from("456"));
    await byteStore.materialize([retained.id], "session-a");
    await expect(byteStore.materialize([overflow.id], "session-b")).rejects.toMatchObject({
      code: "busy", details: { reason: "retained_bytes" },
    });
  });

  it("deduplicates exact bytes while preserving logical upload ownership", async () => {
    const home = await root();
    const store = new UploadStore(home, 16, { maximumStagingBytes: 32 });
    const first = await store.save("first.txt", "text/plain", Buffer.from("same bytes"));
    const second = await store.save("second.bin", "application/octet-stream", Buffer.from("same bytes"));
    const [firstInfo, secondInfo] = await Promise.all([stat(first.path), stat(second.path)]);
    expect(firstInfo.ino).toBe(secondInfo.ino);
    expect(first.id).not.toBe(second.id);
    await expect(store.status()).resolves.toMatchObject({
      entryCount: 2,
      logicalBytes: 20,
      objectCount: 1,
      objectBytes: 10,
      deduplicatedBytes: 10,
    });

    await store.discard(first.id);
    await expect(store.materialize([second.id], "session")).resolves.toMatchObject({
      envelope: expect.stringContaining("second.bin"),
    });
    await expect(store.status()).resolves.toMatchObject({ objectCount: 1, objectBytes: 10 });
  });

  it("reports and retries orphan-object cleanup without retaining ghost logical ownership", async () => {
    const home = await root();
    const store = new UploadStore(home, 16);
    const upload = await store.save("draft.txt", "text/plain", Buffer.from("draft"));
    const metadata = JSON.parse(await readFile(
      join(home, "gateway", "uploads", upload.id, "metadata.json"),
      "utf8",
    ));
    const shard = join(home, "gateway", "upload-objects", metadata.digest.slice(0, 2));
    await chmod(shard, 0o500);
    await store.discard(upload.id);
    await expect(store.status()).resolves.toMatchObject({
      entryCount: 0,
      orphanObjectCount: 1,
      orphanObjectBytes: 5,
    });

    await chmod(shard, 0o700);
    await store.maintain();
    await expect(store.status()).resolves.toMatchObject({
      entryCount: 0,
      objectCount: 0,
      orphanObjectCount: 0,
      orphanObjectBytes: 0,
    });
  });

  it("canonical session cleanup retires only its logical references to shared objects", async () => {
    const store = new UploadStore(await root(), 16, { maximumStagingBytes: 32 });
    const first = await store.save("first.txt", "text/plain", Buffer.from("shared"));
    const second = await store.save("second.txt", "text/plain", Buffer.from("shared"));
    await store.materialize([first.id], "session-a");
    await store.materialize([second.id], "session-b");

    await store.removeSession("session-a");
    await expect(store.acquire(first.id)).rejects.toMatchObject({ code: "not_found" });
    await expect(store.materialize([second.id], "session-b")).resolves.toMatchObject({
      envelope: expect.stringContaining("second.txt"),
    });
    await expect(store.status()).resolves.toMatchObject({
      claimedCount: 1, objectCount: 1, objectBytes: 6,
    });

    await store.removeSession("session-b");
    await expect(store.status()).resolves.toMatchObject({
      claimedCount: 0, objectCount: 0, objectBytes: 0,
    });
  });

  it("preserves the filesystem free-space floor before consuming a request body", async () => {
    let consumed = false;
    const store = new UploadStore(await root(), 8, {
      maximumStagingBytes: 16,
      minimumFreeBytes: 4,
      availableDiskBytes: async () => 10,
    });
    await expect(store.saveStream("too-large", "text/plain", (async function* () {
      consumed = true;
      yield Buffer.from("1234567");
    })(), 7)).rejects.toMatchObject({
      code: "busy",
      retryable: true,
      details: { reason: "disk", diskAvailableBytes: 10, minimumFreeBytes: 4 },
    });
    expect(consumed).toBe(false);
    await expect(store.status()).resolves.toMatchObject({
      diskAvailableBytes: 10,
      minimumFreeBytes: 4,
      storagePressure: "low",
    });
  });

  it("migrates legacy upload folders into resumable content-addressed objects", async () => {
    const home = await root();
    const firstStore = new UploadStore(home, 16);
    const upload = await firstStore.save("legacy.txt", "text/plain", Buffer.from("legacy"));
    const metadataPath = join(home, "gateway", "uploads", upload.id, "metadata.json");
    const current = JSON.parse(await readFile(metadataPath, "utf8"));
    delete current.digest;
    current.version = 1;
    await writeFile(metadataPath, JSON.stringify(current));
    await rm(join(home, "gateway", "upload-objects"), { recursive: true, force: true });
    await chmod(upload.path, 0o600);

    const migratedStore = new UploadStore(home, 16);
    await expect(migratedStore.maintain(new Set())).resolves.toMatchObject({
      entryCount: 1,
      objectCount: 1,
      objectBytes: 6,
    });
    const migrated = JSON.parse(await readFile(metadataPath, "utf8"));
    expect(migrated).toMatchObject({ version: 2, digest: expect.stringMatching(/^[0-9a-f]{64}$/) });
    await expect(migratedStore.materialize([upload.id], "session")).resolves.toMatchObject({
      envelope: expect.stringContaining("legacy.txt"),
    });
  });

  it("maintenance reclaims expired staging and claims whose canonical session no longer exists", async () => {
    let now = 1_000;
    const home = await root();
    const store = new UploadStore(home, 8, {
      maximumStagingEntries: 2,
      maximumStagingBytes: 16,
      maximumUnclaimedAgeMs: 100,
      now: () => now,
    });
    const claimed = await store.save("claimed", "text/plain", Buffer.from("claimed"));
    await store.materialize([claimed.id], "deleted-session");
    const unclaimed = await store.save("unclaimed", "text/plain", Buffer.from("orphan"));
    const staleBody = join(home, "gateway", "upload-bodies", "stale");
    await mkdir(staleBody, { recursive: true });
    await writeFile(join(staleBody, "content"), "partial");
    now = 1_101;

    const status = await store.maintain(new Set(["different-session"]));
    expect(status).toMatchObject({ entryCount: 0, logicalBytes: 0, objectBytes: 0 });
    expect(await readdir(join(home, "gateway", "upload-bodies"))).toEqual([]);
    await expect(store.materialize([claimed.id], "deleted-session")).rejects.toMatchObject({ code: "not_found" });
    await expect(store.materialize([unclaimed.id], "different-session")).rejects.toMatchObject({ code: "not_found" });
  });

  it("maintenance retains claims while the canonical session still exists", async () => {
    const store = new UploadStore(await root(), 16);
    const upload = await store.save("claimed", "text/plain", Buffer.from("value"));
    await store.materialize([upload.id], "live-session");

    await expect(store.maintain(new Set(["live-session"]))).resolves.toMatchObject({
      entryCount: 1,
      claimedCount: 1,
      claimedBytes: 5,
    });
    await expect(store.materialize([upload.id], "live-session")).resolves.toMatchObject({
      envelope: expect.stringContaining("claimed"),
    });
  });

  it("expires indexed staging during admission and leaves full corruption scans to maintenance", async () => {
    let now = 1_000;
    const home = await root();
    const store = new UploadStore(home, 8, {
      maximumStagingEntries: 1,
      maximumStagingBytes: 8,
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
    expect(await readdir(join(home, "gateway", "uploads"))).toEqual(expect.arrayContaining([
      "malformed", "oversized",
    ]));
    await new UploadStore(home, 8, {
      maximumStagingEntries: 1,
      maximumStagingBytes: 8,
      maximumUnclaimedAgeMs: 100,
      now: () => now,
    }).maintain();
    expect(await readdir(join(home, "gateway", "uploads"))).not.toEqual(expect.arrayContaining([
      "malformed", "oversized",
    ]));
  });

  it("discards only unclaimed client staging", async () => {
    const home = await root();
    const store = new UploadStore(home, 32);
    const abandoned = await store.save("abandoned", "text/plain", Buffer.from("draft"));
    const claimed = await store.save("claimed", "text/plain", Buffer.from("prompt"));
    await store.materialize([claimed.id], "session");

    await expect(store.discard(abandoned.id)).resolves.toBeUndefined();
    expect(await readdir(join(home, "gateway", "uploads"))).not.toContain(abandoned.id);
    await expect(store.discard(claimed.id)).rejects.toMatchObject({ code: "conflict" });
    await expect(store.materialize([claimed.id], "session")).resolves.toMatchObject({
      envelope: expect.stringContaining("claimed"),
    });
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

  it("rejects session-import copies at the filesystem floor without leaving staging", async () => {
    const home = await root();
    const seed = new UploadStore(home, 16);
    const upload = await seed.save("session.jsonl", "application/jsonl", Buffer.from("canonical"));
    const bounded = new UploadStore(home, 16, {
      minimumFreeBytes: 4,
      availableDiskBytes: async () => 12,
    });
    await expect(bounded.prepareSessionImport(upload.id)).rejects.toMatchObject({
      code: "busy", details: { reason: "disk", requestedBytes: 9 },
    });
    expect(await readdir(join(home, "gateway", "upload-imports"))).toEqual([]);
  });

  it("includes in-flight upload reservations in session-import disk admission", async () => {
    const home = await root();
    const seed = new UploadStore(home, 16);
    const source = await seed.save("session.jsonl", "application/jsonl", Buffer.from("canonical"));
    const store = new UploadStore(home, 16, {
      maximumStagingBytes: 32,
      minimumFreeBytes: 4,
      availableDiskBytes: async () => 20,
    });
    let releaseBody!: () => void;
    const heldBody = new Promise<void>((resolve) => { releaseBody = resolve; });
    let started!: () => void;
    const bodyStarted = new Promise<void>((resolve) => { started = resolve; });
    const uploading = store.saveStream("held", "text/plain", (async function* () {
      started();
      yield Buffer.from("1234");
      await heldBody;
      yield Buffer.from("5678");
    })(), 8);
    await bodyStarted;

    await expect(store.prepareSessionImport(source.id)).rejects.toMatchObject({
      code: "busy",
      details: { reason: "disk", requestedBytes: 9, reservedBytes: 8 },
    });
    releaseBody();
    await expect(uploading).resolves.toMatchObject({ size: 8 });
  });

  it("uses unique import leases that survive source cleanup and release independently", async () => {
    const home = await root();
    const store = new UploadStore(home, 32);
    const upload = await store.save("session.jsonl", "application/jsonl", Buffer.from("canonical"));
    const first = await store.prepareSessionImport(upload.id);
    const second = await store.prepareSessionImport(upload.id);
    expect(first.path).not.toBe(second.path);
    expect(first.path.startsWith(`${await realpath(join(home, "gateway", "upload-imports"))}/`)).toBe(true);
    expect(await readFile(first.path, "utf8")).toBe("canonical");
    expect(await readFile(second.path, "utf8")).toBe("canonical");
    await expect(store.status()).resolves.toMatchObject({
      activeImportLeaseCount: 2,
      activeImportLeaseBytes: 18,
    });

    await first.release();
    await expect(readFile(first.path, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    expect(await readFile(second.path, "utf8")).toBe("canonical");
    await expect(store.status()).resolves.toMatchObject({ activeImportLeaseCount: 1 });
    await store.remove(upload.id);
    expect(await readFile(second.path, "utf8")).toBe("canonical");
    await second.release();
    expect(await readdir(join(home, "gateway", "upload-imports"))).toEqual([]);
  });

  it("fails closed without traversing a symlinked import staging root", async () => {
    const home = await root();
    const seed = new UploadStore(home, 32);
    const upload = await seed.save("session.jsonl", "application/jsonl", Buffer.from("canonical"));
    const outside = join(home, "outside-imports");
    await mkdir(outside);
    await writeFile(join(outside, "keep"), "keep");
    await symlink(outside, join(home, "gateway", "upload-imports"));
    const store = new UploadStore(home, 32);

    await expect(store.prepareSessionImport(upload.id)).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(outside, "keep"), "utf8")).toBe("keep");
  });

  it("marks same-size digest corruption unavailable on the next process read", async () => {
    const home = await root();
    const store = new UploadStore(home, 16);
    const upload = await store.save("image.png", "image/png", Buffer.from("small"));
    await chmod(upload.path, 0o600);
    await writeFile(upload.path, "other");
    const restarted = new UploadStore(home, 16);
    await expect(restarted.materialize([upload.id], "session")).rejects.toMatchObject({ code: "not_found" });
    await expect(restarted.status()).resolves.toMatchObject({
      entryCount: 1,
      unavailableObjectCount: 1,
      unavailableObjectBytes: 5,
    });
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
      maximumStagingEntries: 4,
      maximumStagingBytes: 32,
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
