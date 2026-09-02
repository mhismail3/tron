import { chmod, mkdtemp, mkdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DisplayArtifactStore } from "./display-artifact-store.js";

async function collect(stream: NodeJS.ReadableStream): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const value of stream) chunks.push(Buffer.isBuffer(value) ? value : Buffer.from(value));
  return Buffer.concat(chunks);
}

async function fixture() {
  const home = await mkdtemp(join(tmpdir(), "tron-display-store-"));
  const workspace = join(home, "workspace");
  await mkdir(workspace, { recursive: true });
  const ids = [
    "0f0bbbac-ded8-45c7-8b3d-93580c5eb9cf",
    "7781e780-0212-4486-b69c-0ea96f249ea6",
    "911a932f-ed76-4524-b9d0-099002928e76",
    "8391b579-b9ca-4db2-9811-e37c0d561441",
    "38173d9f-aa40-462f-97b7-b9cd13f83c46",
    "87c6f5b1-d570-4e45-9dc9-4428845129fe",
  ];
  let index = 0;
  const store = new DisplayArtifactStore(home, {
    maximumItemBytes: 1_024,
    maximumLogicalBytes: 4_096,
    maximumItems: 8,
    minimumFreeBytes: 0,
    uuid: () => ids[index++]!,
  });
  await store.initialize(new Set(["session-a", "session-b"]));
  return { home, workspace, store };
}

describe("DisplayArtifactStore", () => {
  it("snapshots immutable bytes, authorizes session owners, and serves exact ranges", async () => {
    const value = await fixture();
    const data = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from("payload")]);
    await writeFile(join(value.workspace, "preview.png"), data);
    const artifact = await value.store.ingest(value.workspace, "preview.png", "session-a");
    expect(artifact).toMatchObject({ kind: "image", mimeType: "image/png", size: data.length });
    expect(value.store.hasOwner(artifact.id, "session-a")).toBe(true);
    await expect(value.store.acquire(artifact.id, "session-b")).rejects.toMatchObject({ code: "not_found" });

    await expect(value.store.grant(artifact.id, "session-b", "session-unknown"))
      .rejects.toMatchObject({ code: "not_found" });
    await value.store.grant(artifact.id, "session-b", "session-a");
    const lease = await value.store.acquire(artifact.id, "session-b", { start: 2, end: 7 });
    expect(await collect(lease.stream)).toEqual(data.subarray(2, 8));
    expect(lease.totalSize).toBe(data.length);
    await lease.release();

    await value.store.revoke(artifact.id, "session-a");
    expect(value.store.hasOwner(artifact.id, "session-b")).toBe(true);
    await value.store.removeSession("session-b");
    await expect(value.store.acquire(artifact.id, "session-b")).rejects.toMatchObject({ code: "not_found" });
  });

  it("reconciles provisional ownership against the complete canonical tree", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "kept.txt"), "canonical");
    await writeFile(join(value.workspace, "orphan.txt"), "provisional");
    const kept = await value.store.ingest(value.workspace, "kept.txt", "session-a");
    const orphan = await value.store.ingest(value.workspace, "orphan.txt", "session-a");
    await value.store.reconcileSession("session-a", new Set([kept.id]));
    expect(value.store.hasOwner(kept.id, "session-a")).toBe(true);
    expect(value.store.hasOwner(orphan.id, "session-a")).toBe(false);
  });

  it("rejects traversal, symbolic links, and MIME/signature confusion", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "fake.png"), "<html>not an image</html>");
    await expect(value.store.ingest(value.workspace, "../fake.png", "session-a"))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(value.store.ingest(value.workspace, "fake.png", "session-a"))
      .rejects.toMatchObject({ code: "invalid_request" });
    await mkdir(join(value.workspace, ".private"));
    await writeFile(join(value.workspace, ".private", "secret.txt"), "secret");
    await expect(value.store.ingest(value.workspace, ".private/secret.txt", "session-a"))
      .rejects.toMatchObject({ code: "invalid_request" });
    await writeFile(join(value.workspace, "target.txt"), "safe");
    await symlink(join(value.workspace, "target.txt"), join(value.workspace, "link.txt"));
    await expect(value.store.ingest(value.workspace, "link.txt", "session-a"))
      .rejects.toMatchObject({ code: "invalid_request" });
  });

  it("rejects same-size tampering before reusing an existing content object", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "note.txt"), "durable display");
    const artifact = await value.store.ingest(value.workspace, "note.txt", "session-a");
    const content = join(value.home, "gateway", "display-artifacts", "artifacts", artifact.id, "content");
    await chmod(content, 0o600);
    await writeFile(content, "changed-display");
    await writeFile(join(value.workspace, "note.txt"), "durable display");
    await expect(value.store.ingest(value.workspace, "note.txt", "session-a"))
      .rejects.toMatchObject({ code: "conflict" });
  });

  it("fails reads explicitly when immutable object integrity no longer matches metadata", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "note.txt"), "durable display");
    const artifact = await value.store.ingest(value.workspace, "note.txt", "session-a");
    const content = join(value.home, "gateway", "display-artifacts", "artifacts", artifact.id, "content");
    await chmod(content, 0o600);
    await writeFile(content, "changed-display");
    const restarted = new DisplayArtifactStore(value.home, {
      maximumItemBytes: 1_024,
      maximumLogicalBytes: 4_096,
      maximumItems: 8,
      minimumFreeBytes: 0,
    });
    await restarted.initialize(new Set(["session-a"]));
    await expect(restarted.acquire(artifact.id, "session-a")).rejects.toMatchObject({ code: "conflict" });
  });

  it("rebuilds its durable index and prunes owners absent from canonical catalog evidence", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "note.txt"), "durable display");
    const artifact = await value.store.ingest(value.workspace, "note.txt", "session-a");
    const restarted = new DisplayArtifactStore(value.home, {
      maximumItemBytes: 1_024,
      maximumLogicalBytes: 4_096,
      maximumItems: 8,
      minimumFreeBytes: 0,
    });
    await restarted.initialize(new Set(["session-a"]));
    expect(restarted.hasOwner(artifact.id, "session-a")).toBe(true);
    await restarted.maintain(new Set());
    await expect(restarted.acquire(artifact.id, "session-a")).rejects.toMatchObject({ code: "not_found" });
  });
});
