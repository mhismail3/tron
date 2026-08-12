import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { UploadStore } from "./upload-store.js";

describe("UploadStore", () => {
  it("passes images as Pi image content and documents as bounded path envelopes", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-upload-"));
    const store = new UploadStore(root, 1024);
    const image = await store.save("photo.png", "image/png", Buffer.from("image"));
    const document = await store.save("notes.txt", "text/plain", Buffer.from("text"));
    const materialized = await store.materialize([image.id, document.id], "session");
    expect(materialized.images[0]?.mimeType).toBe("image/png");
    expect(materialized.envelope).toContain("<attachment");
    expect(materialized.envelope).toContain("notes.txt");
  });
});
