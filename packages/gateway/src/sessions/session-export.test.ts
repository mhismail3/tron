import { appendFile, mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { copyCanonicalSessionCut, writeSessionProjectionCut } from "./session-export.js";

const roots: string[] = [];

async function root(label: string): Promise<string> {
  const value = await mkdtemp(join(tmpdir(), `tron-session-export-${label}-`));
  roots.push(value);
  return value;
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true })));
});

describe("session export cuts", () => {
  it("copies only the descriptor length captured before later canonical appends", async () => {
    const directory = await root("prefix");
    const source = join(directory, "source.jsonl");
    const destination = join(directory, "snapshot.jsonl");
    const original = "{\"type\":\"session\",\"id\":\"cut\"}\n";
    await writeFile(source, original);
    const handle = await open(source, "r");
    const size = (await handle.stat()).size;
    await appendFile(source, "{\"type\":\"message\",\"id\":\"later\"}\n");
    try {
      await copyCanonicalSessionCut({ handle, size }, destination);
    } finally {
      await handle.close();
    }
    expect(await readFile(destination, "utf8")).toBe(original);
  });

  it("serializes a captured first-turn or active-branch projection as complete JSONL lines", async () => {
    const directory = await root("projection");
    const destination = join(directory, "snapshot.jsonl");
    const size = await writeSessionProjectionCut({
      header: { type: "session", version: 3, id: "projection" },
      entries: [{ type: "message", id: "entry", parentId: null }],
    }, destination);
    const value = await readFile(destination, "utf8");
    expect(Buffer.byteLength(value)).toBe(size);
    expect(value.endsWith("\n")).toBe(true);
    expect(value.trimEnd().split("\n").map(line => JSON.parse(line))).toHaveLength(2);
  });
});
