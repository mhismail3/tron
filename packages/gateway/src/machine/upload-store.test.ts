import { mkdirSync, writeFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
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
    const materialized = await store.materialize([image.id, document.id], "session");
    expect(materialized.images[0]?.mimeType).toBe("image/png");
    expect(materialized.envelope).toContain("<attachment");
    expect(materialized.envelope).toContain("notes.txt");
    await expect(store.materialize([image.id], "other-session")).rejects.toMatchObject({ code: "conflict" });

    await store.removeSession("session");
    await expect(store.materialize([image.id], "session")).rejects.toMatchObject({ code: "not_found" });
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
    await mkdir(malformed, { recursive: true });
    await writeFile(join(malformed, "metadata.json"), "not-json");
    now = 1_101;

    await expect(store.materialize([expired.id], "session")).rejects.toMatchObject({ code: "not_found" });
    await expect(store.save("replacement", "text/plain", Buffer.from("12345678"))).resolves.toMatchObject({
      name: "replacement",
      size: 8,
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
