import { createHash, randomUUID } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { RecordingStore } from "./recording-store.js";

const roots: string[] = [];
async function fixture(options: ConstructorParameters<typeof RecordingStore>[2] = {}) {
  const home = await mkdtemp(join(tmpdir(), "tron-recording-test-")); roots.push(home);
  const workspace = new TronWorkspace(home); await workspace.initialize();
  await mkdir(join(home, "workspace", "files"), { mode: 0o700 });
  return { home, workspace, store: new RecordingStore(workspace, "gateway-machine", options) };
}
const bytes = Buffer.from("fixture audio bytes\0same source");
const digest = createHash("sha256").update(bytes).digest("hex");
const device = "paired-device-hash";
const id = "6f3241c1-496e-4dbd-b452-2c724937f5d0";
function capture(segmentCount: number, recovered = false) {
  return {
    schemaVersion: 1 as const,
    source: { appVersion: "1.0", platform: "watchOS" as const, platformVersion: "26.0" },
    startedAt: "2026-01-01T00:00:00.000Z", stoppedAt: "2026-01-01T00:00:01.000Z",
    clockOffsetMilliseconds: 0,
    stopReason: recovered ? "recovered-partial" as const : "user" as const,
    recoveryStatus: recovered ? "interrupted" as const : "complete" as const,
    timeline: Array.from({ length: segmentCount }, (_, i) => ({ segment: i + 1, startMonotonicMilliseconds: i * 1000, durationMilliseconds: 1000, pauseBeforeMilliseconds: 0, frameCount: 48_000, codec: "AAC", format: "m4a" })),
  };
}
function source(body: Buffer) { return (async function* () { yield body; })(); }
afterEach(async () => { await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true }))); });

describe("durable recording ingestion", () => {
  it("keeps the published cross-language fixture in sync with the raw source bytes", async () => {
    const fixture = JSON.parse(await readFile(new URL("../../test-fixtures/watch-recording-v1.json", import.meta.url), "utf8"));
    expect(fixture.segment.size).toBe(bytes.length);
    expect(fixture.segment.sha256).toBe(digest);
    expect(fixture.finalizeRequest.capture).toEqual(capture(1));
    expect(fixture.commitReceipt.contentSha256).toBe(createHash("sha256").update(`1:${digest}:${bytes.length}\\n`).digest("hex"));
  });

  it("admits reordered segments idempotently, finalizes exact bytes, and reopens durable receipts", async () => {
    const { home, workspace, store } = await fixture();
    const second = Buffer.from("second segment");
    const secondHash = createHash("sha256").update(second).digest("hex");
    await store.acceptSegment(id, 2, second.length, secondHash, device, source(second));
    await store.acceptSegment(id, 1, bytes.length, digest, device, source(bytes));
    const replay = await store.acceptSegment(id, 1, bytes.length, digest, device, source(bytes));
    expect(replay.segment).toBe(1);
    await expect(store.acceptSegment(id, 1, bytes.length, "f".repeat(64), device, source(bytes))).rejects.toMatchObject({ code: "conflict" });
    await expect(store.finalize(id, device, { segmentCount: 1, capture: capture(1) })).rejects.toMatchObject({ code: "conflict" });
    const receipt = await store.finalize(id, device, { segmentCount: 2, capture: capture(2, true) });
    expect(receipt).toMatchObject({ recordingId: id, destinationId: "gateway-machine", totalBytes: bytes.length + second.length, segmentCount: 2, capture: { recoveryStatus: "interrupted" } });
    const reopened = new RecordingStore(workspace, "gateway-machine");
    const status = await reopened.status(id, device, 0, 1);
    expect(status).toMatchObject({ finalized: true, receipt });
    expect(status.segments).toHaveLength(1);
    expect(status.nextOffset).toBe(1);
    expect(await readFile(join(home, "workspace", "files", "recordings", id, "segments", "000001.audio"))).toEqual(bytes);
    expect(await reopened.finalize(id, device, { segmentCount: 2, capture: capture(2, true) })).toEqual(receipt);
  });

  it("does not finalize missing segments and rejects foreign ownership", async () => {
    const { store } = await fixture();
    await store.acceptSegment(id, 2, bytes.length, digest, device, source(bytes));
    await expect(store.finalize(id, device, { segmentCount: 2, capture: capture(2) })).rejects.toMatchObject({ code: "conflict" });
    await expect(store.status(id, "other-paired-device", 0, 10)).rejects.toMatchObject({ code: "not_found" });
  });

  it("rejects a segments-directory symlink escape without reading outside bytes", async () => {
    const { home, store } = await fixture();
    await store.acceptSegment(id, 1, bytes.length, digest, device, source(bytes));
    const segments = join(home, "workspace", "files", "recordings", id, "segments");
    const outside = join(home, "outside");
    await mkdir(outside, { mode: 0o700 });
    await rm(segments, { recursive: true, force: true });
    await symlink(outside, segments);
    await expect(store.status(id, device, 0, 10)).rejects.toMatchObject({ code: "conflict" });
    expect(await readdir(outside)).toEqual([]);
  });

  it("fails closed when the retained files workspace is unavailable", async () => {
    const { home, workspace, store } = await fixture();
    await rm(join(home, "workspace", "files"), { recursive: true, force: true });
    await expect(store.acceptSegment(id, 1, bytes.length, digest, device, source(bytes))).rejects.toMatchObject({ code: "conflict" });
    await expect(store.status(id, device, 0, 10)).rejects.toBeDefined();
  });

  it("enforces the filesystem safety floor without publishing source audio", async () => {
    const { home, workspace } = await fixture();
    const available = { bytes: 1_000 };
    const store = new RecordingStore(workspace, "gateway-machine", { minimumFreeBytes: 100, availableDiskBytes: async () => available.bytes });
    await store.acceptSegment(id, 1, bytes.length, digest, device, source(bytes));
    available.bytes = 100;
    await expect(store.acceptSegment(id, 2, bytes.length, digest, device, source(bytes))).rejects.toMatchObject({ code: "busy" });
    const durable = await readFile(join(home, "workspace", "files", "recordings", id, "segments", "000001.audio"));
    expect(durable).toEqual(bytes);
  });

  it("rejects altered durable source bytes and accepts only a verified replay", async () => {
    const { home, workspace, store } = await fixture();
    await expect(store.acceptSegment(id, 1, bytes.length, digest, device, source(Buffer.from("truncated")))).rejects.toMatchObject({ code: "conflict" });
    await store.acceptSegment(id, 1, bytes.length, digest, device, source(bytes));
    const path = join(home, "workspace", "files", "recordings", id, "segments", "000001.audio");
    await chmod(path, 0o600);
    await writeFile(path, Buffer.from("tampered"));
    const reopened = new RecordingStore(workspace, "gateway-machine");
    await expect(reopened.finalize(id, device, { segmentCount: 1, capture: capture(1) })).rejects.toMatchObject({ code: "conflict" });
  });

  it("keeps separate recording lanes independent and enforces bounded pages", async () => {
    const { store } = await fixture();
    const another = randomUUID();
    await store.acceptSegment(id, 1, bytes.length, digest, device, source(bytes));
    await store.acceptSegment(another, 1, bytes.length, digest, device, source(bytes));
    await expect(store.status(id, device, 0, 101)).rejects.toMatchObject({ code: "invalid_request" });
    expect((await store.status(another, device, 0, 1)).segments[0]?.sha256).toBe(digest);
  });
});
