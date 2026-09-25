import { chmod, mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
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
  await store.initialize();
  return { home, workspace, store };
}

describe("DisplayArtifactStore", () => {
  it("captures orphan membership after queued grants and preserves owners on discovery failure", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "retained.txt"), "durable");
    const artifact = await value.store.ingest(value.workspace, "retained.txt", "session-a");
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    const live = new Set(["session-a"]);
    const earlier = (value.store as any).serialize(async () => { await barrier; live.add("new-session"); });
    const grant = value.store.grant(artifact.id, "new-session", "session-a");
    const maintained = value.store.maintain(async () => new Set(live));
    try {
      release(); await Promise.all([earlier, grant, maintained]);
      await expect(value.store.maintain(async () => { throw new Error("membership unavailable"); })).rejects.toThrow("membership unavailable");
      const lease = await value.store.acquire(artifact.id, "new-session");
      try { expect((await collect(lease.stream)).toString()).toBe("durable"); }
      finally { await lease.release(); }
    } finally { release(); await Promise.allSettled([earlier, grant, maintained]); await rm(value.home, { recursive: true, force: true }); }
  });

  it("reserves reader capacity before asynchronous validation and releases failed acquisitions", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "read.txt"), "fixture");
    const artifact = await value.store.ingest(value.workspace, "read.txt", "session-a");
    const io = value.store as unknown as { verify(digest: string, size: number, path: string): Promise<void> };
    const verify = io.verify.bind(value.store);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const blocked = vi.spyOn(io, "verify").mockImplementation(async (...args) => { await gate; await verify(...args); });
    const pending = Array.from({ length: 5 }, () => value.store.acquire(artifact.id, "session-a"));
    for (const result of pending) void result.catch(() => {});
    try {
      expect(blocked).toHaveBeenCalledTimes(4);
      release();
      const settled = await Promise.allSettled(pending);
      expect(settled.filter(result => result.status === "fulfilled")).toHaveLength(4);
      expect(settled[4]).toMatchObject({ status: "rejected", reason: { code: "busy" } });
      for (const result of settled) if (result.status === "fulfilled") await result.value.release();
      blocked.mockRejectedValueOnce(new Error("fixture validation failure"));
      await expect(value.store.acquire(artifact.id, "session-a")).rejects.toThrow("fixture validation failure");
      const next = await value.store.acquire(artifact.id, "session-a");
      expect(await collect(next.stream)).toEqual(Buffer.from("fixture"));
      await next.release();
    } finally {
      release();
      const settled = await Promise.allSettled(pending);
      for (const result of settled) if (result.status === "fulfilled") await result.value.release();
      blocked.mockRestore();
      await rm(value.home, { recursive: true, force: true });
    }
  });
  it.each(["revoke", "reconcile", "remove", "maintain"])("%s revokes future reads while an admitted reader finishes and releases storage", async operation => {
    const value = await fixture();
    await writeFile(join(value.workspace, "read.txt"), "fixture");
    const artifact = await value.store.ingest(value.workspace, "read.txt", "session-a");
    const io = value.store as unknown as { verify(digest: string, size: number, path: string): Promise<void> };
    const verify = io.verify.bind(value.store);
    let resume!: () => void;
    const gate = new Promise<void>(resolve => { resume = resolve; });
    const blocked = vi.spyOn(io, "verify").mockImplementation(async (...args) => { await gate; await verify(...args); });
    const pending = value.store.acquire(artifact.id, "session-a");
    try {
      expect(blocked).toHaveBeenCalledOnce();
      if (operation === "revoke") await value.store.revoke(artifact.id, "session-a");
      else if (operation === "reconcile") await value.store.reconcileSession("session-a", new Set());
      else if (operation === "remove") await value.store.removeSession("session-a");
      else await value.store.maintain(async () => new Set());
      expect(value.store.hasOwner(artifact.id, "session-a")).toBe(false);
      await expect(value.store.acquire(artifact.id, "session-a")).rejects.toMatchObject({ code: "not_found" });
      resume();
      const lease = await pending;
      expect(await collect(lease.stream)).toEqual(Buffer.from("fixture"));
      await lease.release();
      await lease.release();
      expect(await readdir(join(value.home, "gateway/display-artifacts/artifacts"))).toEqual([]);
      // Capacity and durable authorization do not survive the last reader.
      const restarted = new DisplayArtifactStore(value.home, { minimumFreeBytes: 0 });
      await restarted.initialize();
      expect(restarted.hasOwner(artifact.id, "session-a")).toBe(false);
    } finally {
      resume();
      await (await pending).release();
      blocked.mockRestore();
      await rm(value.home, { recursive: true, force: true });
    }
  });
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

  it("rejects a NUL anywhere in text artifacts and never publishes undecodable text", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-display-text-"));
    const workspace = join(home, "workspace");
    await mkdir(workspace, { recursive: true });
    // The signature prefix covers only the first 4 KiB, so a late NUL isolates
    // the staged-file UTF-8/NUL validation from content-type signature matching.
    const store = new DisplayArtifactStore(home, {
      maximumItemBytes: 8_192,
      maximumLogicalBytes: 16_384,
      minimumFreeBytes: 0,
    });
    await store.initialize();
    const published = join(home, "gateway", "display-artifacts", "artifacts");
    try {
      await writeFile(join(workspace, "early-nul.txt"), Buffer.from("ab\u0000cd"));
      await expect(store.ingest(workspace, "early-nul.txt", "session-a"))
        .rejects.toMatchObject({ code: "invalid_request" });
      await writeFile(join(workspace, "late-nul.txt"), Buffer.concat([Buffer.alloc(5_000, 0x61), Buffer.from([0])]));
      await expect(store.ingest(workspace, "late-nul.txt", "session-a"))
        .rejects.toMatchObject({ code: "invalid_request" });
      await writeFile(join(workspace, "invalid-utf8.md"), Buffer.from([0x61, 0xff, 0x62]));
      await expect(store.ingest(workspace, "invalid-utf8.md", "session-a"))
        .rejects.toMatchObject({ code: "invalid_request" });
      expect(await readdir(published)).toEqual([]);
      await writeFile(join(workspace, "utf8.txt"), "héllo ✓");
      await expect(store.ingest(workspace, "utf8.txt", "session-a")).resolves.toMatchObject({ kind: "text" });
      expect(await readdir(published)).toHaveLength(1);
    } finally {
      await rm(home, { recursive: true, force: true });
    }
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
    await restarted.initialize();
    await expect(restarted.acquire(artifact.id, "session-a")).rejects.toMatchObject({ code: "conflict" });
  });

  it("preserves artifacts after operational startup validation failure but cleans confirmed corruption", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "operational.txt"), "operational");
    await writeFile(join(value.workspace, "corrupt.txt"), "corrupt");
    const operational = await value.store.ingest(value.workspace, "operational.txt", "session-a");
    const corrupt = await value.store.ingest(value.workspace, "corrupt.txt", "session-a");
    const artifactRoot = join(value.home, "gateway", "display-artifacts", "artifacts");
    const objectRoot = join(value.home, "gateway", "display-artifacts", "objects");
    const operationalFolder = join(artifactRoot, operational.id);
    const corruptFolder = join(artifactRoot, corrupt.id);
    const operationalObject = JSON.parse(await readFile(join(operationalFolder, "metadata.json"), "utf8")).digest;
    const objectPath = join(objectRoot, operationalObject.slice(0, 2), operationalObject.slice(2));
    await chmod(operationalFolder, 0);
    try {
      const restarted = new DisplayArtifactStore(value.home, { maximumItemBytes: 1_024, maximumLogicalBytes: 4_096, maximumItems: 8, minimumFreeBytes: 0 });
      await restarted.initialize();
      expect(await readdir(artifactRoot)).toContain(operational.id);
      await expect(restarted.acquire(operational.id, "session-a")).rejects.toMatchObject({ code: "conflict" });
      expect(await readFile(objectPath, "utf8")).toBe("operational");

      await writeFile(join(corruptFolder, "metadata.json"), "not-json");
      const cleaned = new DisplayArtifactStore(value.home, { maximumItemBytes: 1_024, maximumLogicalBytes: 4_096, maximumItems: 8, minimumFreeBytes: 0 });
      await cleaned.initialize();
      expect(await readdir(artifactRoot)).not.toContain(corrupt.id);
    } finally {
      await chmod(operationalFolder, 0o700).catch(() => {});
      await rm(value.home, { recursive: true, force: true });
    }
  });

  it("retains unavailable sibling references and fails closed for quota and reconciliation", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "shared.txt"), "shared bytes");
    const artifactA = await value.store.ingest(value.workspace, "shared.txt", "session-a");
    const artifactB = await value.store.ingest(value.workspace, "shared.txt", "session-b");
    const artifactRoot = join(value.home, "gateway/display-artifacts/artifacts");
    const objectRoot = join(value.home, "gateway/display-artifacts/objects");
    const folderA = join(artifactRoot, artifactA.id);
    const metadata = JSON.parse(await readFile(join(folderA, "metadata.json"), "utf8")) as { digest: string };
    const objectPath = join(objectRoot, metadata.digest.slice(0, 2), metadata.digest.slice(2));
    await chmod(folderA, 0);
    try {
      const restarted = new DisplayArtifactStore(value.home, {
        maximumItemBytes: 1_024,
        maximumLogicalBytes: 4_096,
        maximumItems: 8,
        minimumFreeBytes: 0,
      });
      await restarted.initialize();
      await expect(restarted.reconcileSession("session-a", new Set())).rejects.toMatchObject({ code: "conflict" });
      await writeFile(join(value.workspace, "new.txt"), "new bytes");
      await expect(restarted.ingest(value.workspace, "new.txt", "session-a")).rejects.toMatchObject({ code: "conflict" });

      await chmod(folderA, 0o700);
      await restarted.removeSession("session-b");
      expect(await readFile(objectPath, "utf8")).toBe("shared bytes");

      const revalidated = new DisplayArtifactStore(value.home, { minimumFreeBytes: 0 });
      await revalidated.initialize();
      expect(revalidated.hasOwner(artifactA.id, "session-a")).toBe(true);
      const lease = await revalidated.acquire(artifactA.id, "session-a");
      expect(await collect(lease.stream)).toEqual(Buffer.from("shared bytes"));
      await lease.release();
      expect(await readdir(artifactRoot)).toEqual([artifactA.id]);
      expect(artifactB.id).not.toBe(artifactA.id);
    } finally {
      await chmod(folderA, 0o700).catch(() => {});
      await rm(value.home, { recursive: true, force: true });
    }
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
    await restarted.initialize();
    expect(restarted.hasOwner(artifact.id, "session-a")).toBe(true);
    await restarted.maintain(async () => new Set());
    await expect(restarted.acquire(artifact.id, "session-a")).rejects.toMatchObject({ code: "not_found" });
  });

  it("treats empty-owner metadata as startup cleanup instead of restored authority", async () => {
    const value = await fixture();
    await writeFile(join(value.workspace, "note.txt"), "durable display");
    const artifact = await value.store.ingest(value.workspace, "note.txt", "session-a");
    const artifacts = join(value.home, "gateway/display-artifacts/artifacts");
    const folder = join(artifacts, artifact.id);
    // Revocation commits empty ownership before the lane removes the folder, so
    // a crash in between leaves startup as the only cleanup owner.
    const metadata = JSON.parse(await readFile(join(folder, "metadata.json"), "utf8")) as { owners: string[] };
    await writeFile(join(folder, "metadata.json"), JSON.stringify({ ...metadata, owners: [] }));
    const restarted = new DisplayArtifactStore(value.home, { minimumFreeBytes: 0 });
    await restarted.initialize();
    expect(await readdir(artifacts)).toEqual([]);
    await expect(restarted.acquire(artifact.id, "session-a")).rejects.toMatchObject({ code: "not_found" });
  });
});
