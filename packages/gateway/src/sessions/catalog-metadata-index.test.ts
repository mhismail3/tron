import { mkdtemp, readFile, rename, truncate, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  CatalogMetadataIndex,
  applyCatalogMetadataEntry,
  CATALOG_METADATA_INDEX_MAX_BYTES,
  CATALOG_METADATA_INDEX_VERSION,
  type CatalogMetadataAccumulator,
  type CatalogMetadataIndexSummary,
} from "./catalog-metadata-index.js";

const roots: string[] = [];
async function fixture() {
  const root = await mkdtemp(join("/tmp", "tron-catalog-index-"));
  roots.push(root);
  const catalog = join(root, "sessions");
  const gateway = join(root, "gateway");
  const path = join(catalog, "session.jsonl");
  await (await import("node:fs/promises")).mkdir(catalog, { recursive: true });
  await writeFile(path, `${JSON.stringify({ type: "session", version: 3, id: "session", timestamp: "2026-01-01T00:00:00.000Z", cwd: "/workspace" })}\n`);
  return { root, catalog, gateway, path };
}

const summary = (path: string): CatalogMetadataIndexSummary => ({
  id: "session", path, cwd: "/workspace", firstMessage: "(no messages)",
  createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", messageCount: 0,
});

const reconcileSaved = (
  index: CatalogMetadataIndex,
  catalog: string,
  rows: readonly NonNullable<Awaited<ReturnType<CatalogMetadataIndex["entryFromSummary"]>>>[],
) => index.reconcile(
  catalog,
  rows.map((row) => ({
    path: row.path,
    id: row.id,
    cwd: row.cwd,
    fileIdentity: row.fileIdentity,
    size: row.size,
    mtimeMs: row.mtimeMs,
  })),
  async () => undefined,
);

afterEach(async () => {
  const { rm } = await import("node:fs/promises");
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("CatalogMetadataIndex", () => {
  it("keeps full and suffix metadata semantics aligned for arrays, tool results, timestamps, and clears", () => {
    const target: CatalogMetadataAccumulator = {
      messageCount: 0, firstMessage: "(no messages)", name: "named", updatedAt: "2026-01-01T00:00:00.000Z",
    };
    applyCatalogMetadataEntry(target, { type: "message", timestamp: 1_704_067_200_000, message: {
      role: "toolResult", content: "ignored for preview and recency",
    } });
    expect(target.messageCount).toBe(1);
    expect(target.updatedAt).toBe("2026-01-01T00:00:00.000Z");
    applyCatalogMetadataEntry(target, { type: "message", timestamp: Date.parse("2027-01-02T00:00:00.000Z"), message: {
      role: "user", content: [{ type: "text", text: "array first user" }, { type: "image", data: "omitted" }],
    } });
    expect(target.messageCount).toBe(2);
    expect(target.firstMessage).toBe("array first user");
    expect(target.updatedAt).toBe("2027-01-02T00:00:00.000Z");
    applyCatalogMetadataEntry(target, { type: "message", message: null });
    applyCatalogMetadataEntry(target, { type: "message", timestamp: "2026-06-01T00:00:00.000Z", message: {
      role: "assistant", content: "older activity",
    } });
    applyCatalogMetadataEntry(target, { type: "message", message: {
      role: "assistant", content: "non-positive activity", timestamp: 0,
    } });
    expect(target.messageCount).toBe(5);
    expect(target.updatedAt).toBe("2027-01-02T00:00:00.000Z");
    applyCatalogMetadataEntry(target, { type: "session_info", name: "" });
    applyCatalogMetadataEntry(target, { type: "session_info", name: "restored" });
    applyCatalogMetadataEntry(target, { type: "session_info", name: null });
    expect(target.name).toBeUndefined();
  });

  it("keeps machine-authored skill and command envelopes out of session titles", () => {
    const skillTarget: CatalogMetadataAccumulator = {
      messageCount: 0, firstMessage: "(no messages)", name: undefined, updatedAt: "2026-01-01T00:00:00.000Z",
    };
    applyCatalogMetadataEntry(skillTarget, { type: "message", message: {
      role: "user",
      content: `<skill name="review" location="/skills/review/SKILL.md">\nReferences are relative to /skills/review.\n\nInstructions\n</skill>`,
    } });
    expect(skillTarget.firstMessage).toBe("Review");

    const commandTarget = { ...skillTarget, firstMessage: "(no messages)" };
    applyCatalogMetadataEntry(commandTarget, { type: "message", message: {
      role: "user", content: "/release-notes summarize v2",
    } });
    expect(commandTarget.firstMessage).toBe("summarize v2");
  });

  it("atomically saves and reloads unchanged canonical metadata", async () => {
    const f = await fixture();
    const index = new CatalogMetadataIndex(f.gateway);
    const row = await index.entryFromSummary({
      ...summary(f.path),
      creationOrigin: {
        kind: "automation",
        automationId: "20000000-0000-4000-8000-000000000021",
      },
    });
    expect(row).toBeDefined();
    expect(await index.save(f.catalog, [row!])).toBe(true);
    const loaded = await reconcileSaved(index, f.catalog, [row!]);
    expect(loaded).toHaveLength(1);
    expect(loaded![0]).toMatchObject({
      id: "session",
      creationOrigin: {
        kind: "automation",
        automationId: "20000000-0000-4000-8000-000000000021",
      },
    });
    expect((await readFile(index.path, "utf8"))).not.toContain("allMessagesText");
  });

  it("reconciles changed files independently while retaining unchanged rows", async () => {
    const f = await fixture();
    const second = join(f.catalog, "second.jsonl");
    await writeFile(second, `${JSON.stringify({ type: "session", version: 3, id: "second", timestamp: "2026-01-01T00:00:00.000Z", cwd: "/workspace" })}\n`);
    const index = new CatalogMetadataIndex(f.gateway);
    const first = (await index.entryFromSummary(summary(f.path)))!;
    const secondRow = (await index.entryFromSummary({ ...summary(second), id: "second" }))!;
    await index.save(f.catalog, [first, secondRow]);
    await writeFile(f.path, `${await readFile(f.path, "utf8")}${JSON.stringify({ type: "message", message: { role: "user", content: "new" }, timestamp: "2026-01-01T00:01:00.000Z" })}\n`);
    const rows = await index.reconcile(f.catalog, [
      { path: f.path, id: "session", cwd: "/workspace", fileIdentity: first.fileIdentity, size: (await (await import("node:fs/promises")).stat(f.path)).size, mtimeMs: (await (await import("node:fs/promises")).stat(f.path)).mtimeMs },
      { path: second, id: "second", cwd: "/workspace", fileIdentity: secondRow.fileIdentity, size: secondRow.size, mtimeMs: secondRow.mtimeMs },
    ], async (candidate) => ({
      id: candidate.id, path: candidate.path, cwd: candidate.cwd,
      firstMessage: candidate.id === "session" ? "new" : "(no messages)",
      createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:01:00.000Z", messageCount: candidate.id === "session" ? 1 : 99,
    }));
    expect(rows).toHaveLength(2);
    expect(rows?.find((row) => row.id === "second")?.messageCount).toBe(0);
    expect(rows?.find((row) => row.id === "session")?.messageCount).toBe(1);
  });

  it("updates exact summary fields from newline-complete appended bytes", async () => {
    const f = await fixture();
    const index = new CatalogMetadataIndex(f.gateway);
    const row = (await index.entryFromSummary(summary(f.path)))!;
    await writeFile(f.path, `${await readFile(f.path, "utf8")}${JSON.stringify({ type: "message", timestamp: "2026-01-01T00:01:00.000Z", message: { role: "user", content: "hello" } })}\n`);
    const next = await index.append(row);
    expect(next).toMatchObject({ messageCount: 1, firstMessage: "hello", eofOffset: (await (await import("node:fs/promises")).stat(f.path)).size });
  });

  it("rejects partial append, truncation, inode replacement, and same-size mutation", async () => {
    const f = await fixture();
    const index = new CatalogMetadataIndex(f.gateway);
    const row = (await index.entryFromSummary(summary(f.path)))!;
    await writeFile(f.path, `${await readFile(f.path, "utf8")}partial`);
    expect(await index.append(row)).toBeUndefined();
    await truncate(f.path, row.eofOffset - 1);
    expect(await index.append(row)).toBeUndefined();
    await writeFile(join(f.root, "replacement.jsonl"), "replacement\n");
    await rename(join(f.root, "replacement.jsonl"), f.path);
    expect(await index.append(row)).toBeUndefined();
  });

  it("discards corrupt, oversized, wrong-root, wrong-schema, and ahead indexes", async () => {
    const f = await fixture();
    const index = new CatalogMetadataIndex(f.gateway);
    const row = (await index.entryFromSummary(summary(f.path)))!;
    await index.save(f.catalog, [row]);
    await writeFile(index.path, "not-json");
    expect(await reconcileSaved(index, f.catalog, [row])).toBeUndefined();
    await index.save(f.catalog, [row]);
    const document = JSON.parse(await readFile(index.path, "utf8"));
    document.version = 99;
    await writeFile(index.path, JSON.stringify(document));
    expect(await reconcileSaved(index, f.catalog, [row])).toBeUndefined();
    await index.save(f.catalog, [row]);
    document.version = CATALOG_METADATA_INDEX_VERSION;
    document.root = "/outside";
    await writeFile(index.path, JSON.stringify(document));
    expect(await reconcileSaved(index, f.catalog, [row])).toBeUndefined();
    await index.save(f.catalog, [row]);
    await writeFile(index.path, "x".repeat(CATALOG_METADATA_INDEX_MAX_BYTES + 1));
    expect(await reconcileSaved(index, f.catalog, [row])).toBeUndefined();
  });

  it("rebuilds an omitted or same-size changed row without discarding its unchanged sibling", async () => {
    const f = await fixture();
    const second = join(f.catalog, "second.jsonl");
    await writeFile(second, `${JSON.stringify({
      type: "session", version: 3, id: "second", timestamp: "2026-01-01T00:00:00.000Z", cwd: "/workspace",
    })}\n`);
    const index = new CatalogMetadataIndex(f.gateway);
    const first = (await index.entryFromSummary(summary(f.path)))!;
    const secondRow = (await index.entryFromSummary({ ...summary(second), id: "second" }))!;
    // Persist an intentionally incomplete prior projection. Reconciliation must
    // derive membership from current canonical candidates, not sidecar rows.
    await index.save(f.catalog, [first]);
    const original = await readFile(f.path, "utf8");
    await writeFile(f.path, original.replace("2026-01-01", "2027-01-01"));
    const firstFacts = await (await import("node:fs/promises")).stat(f.path);
    const rebuilt: string[] = [];
    const rows = await index.reconcile(f.catalog, [
      {
        path: f.path, id: first.id, cwd: first.cwd, fileIdentity: first.fileIdentity,
        size: firstFacts.size, mtimeMs: firstFacts.mtimeMs,
      },
      {
        path: second, id: secondRow.id, cwd: secondRow.cwd, fileIdentity: secondRow.fileIdentity,
        size: secondRow.size, mtimeMs: secondRow.mtimeMs,
      },
    ], async (candidate) => {
      rebuilt.push(candidate.id);
      return candidate.id === first.id
        ? { ...summary(candidate.path), id: candidate.id, createdAt: "2027-01-01T00:00:00.000Z" }
        : { ...summary(candidate.path), id: candidate.id };
    });
    expect(rows?.map((row) => row.id).sort()).toEqual(["second", "session"]);
    expect(rebuilt.sort()).toEqual(["second", "session"]);
  });

  it("does not reconcile a sidecar row over a partial canonical final line", async () => {
    const f = await fixture();
    const index = new CatalogMetadataIndex(f.gateway);
    const row = (await index.entryFromSummary(summary(f.path)))!;
    await index.save(f.catalog, [row]);
    await writeFile(f.path, `${await readFile(f.path, "utf8")}{\"type\":\"message\"`);
    const facts = await (await import("node:fs/promises")).stat(f.path);
    await expect(index.reconcile(f.catalog, [{
      path: row.path, id: row.id, cwd: row.cwd, fileIdentity: row.fileIdentity,
      size: facts.size, mtimeMs: facts.mtimeMs,
    }], async () => summary(f.path))).resolves.toBeUndefined();
  });

  it("serializes concurrent saves and keeps the final document valid", async () => {
    const f = await fixture();
    const index = new CatalogMetadataIndex(f.gateway);
    const row = (await index.entryFromSummary(summary(f.path)))!;
    await Promise.all([
      index.save(f.catalog, [row]),
      index.save(f.catalog, [row]),
      index.save(f.catalog, [row]),
    ]);
    const loaded = await reconcileSaved(index, f.catalog, [row]);
    expect(loaded).toHaveLength(1);
  });

  it("fails closed on symlinked canonical files and persistence errors", async () => {
    const f = await fixture();
    const index = new CatalogMetadataIndex(f.gateway);
    const row = await index.entryFromSummary(summary(f.path));
    expect(row).toBeDefined();
    await rename(f.path, `${f.path}.real`);
    await (await import("node:fs/promises")).symlink(`${f.path}.real`, f.path);
    expect(await index.entryFromSummary(summary(f.path))).toBeUndefined();
    const blocked = join(f.root, "blocked");
    await writeFile(blocked, "file");
    const failing = new CatalogMetadataIndex(join(blocked, "gateway"));
    await expect(failing.save(f.catalog, [])).rejects.toBeDefined();
  });
});
