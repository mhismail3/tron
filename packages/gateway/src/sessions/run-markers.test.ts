import { mkdir, mkdtemp, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { MAXIMUM_RUN_MARKER_OPERATIONS, RunMarkerStore } from "./run-markers.js";

describe("RunMarkerStore", () => {
  it("records accepted work without storing the prompt", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-"));
    const store = new RunMarkerStore(root);
    await store.mark("session", "operation");
    expect(await store.interruptedSessionIds()).toEqual(new Set(["session"]));
    await store.markAssistantCompletion("session", "operation", "completion", "2026-01-01T00:00:00.000Z");
    expect(await store.evidence()).toEqual(new Map([[
      "session",
      [expect.objectContaining({
        operationId: "operation",
        assistantCompletionId: "completion",
        assistantCompletedAt: "2026-01-01T00:00:00.000Z",
      })],
    ]]));
    await expect(store.markAssistantCompletion(
      "session", "older-operation", "other", "2026-01-01T00:00:01.000Z",
    )).rejects.toThrow("ownership changed");
    await store.clear("session", "older-operation");
    expect(await store.interruptedSessionIds()).toEqual(new Set(["session"]));
    await store.clear("session", "operation");
    expect(await store.interruptedSessionIds()).toEqual(new Set());
  });

  it("atomically reasserts missing live ownership with exact completion evidence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-reassert-"));
    const renameMarker = vi.fn((...arguments_: Parameters<typeof rename>) => rename(...arguments_));
    const store = new RunMarkerStore(root, {
      fileSystem: { mkdir, open, rename: renameMarker, rm } as never,
    });

    await store.reassertAssistantCompletion(
      "session", "operation", "completion", "2026-01-01T00:00:00.000Z",
    );
    expect(await store.evidenceFor("session")).toEqual([expect.objectContaining({
      operationId: "operation",
      assistantCompletionId: "completion",
      assistantCompletedAt: "2026-01-01T00:00:00.000Z",
    })]);
    expect(renameMarker).toHaveBeenCalledTimes(1);
    await store.reassertAssistantCompletion(
      "session", "operation", "completion", "2026-01-01T00:00:00.000Z",
    );
    expect(renameMarker).toHaveBeenCalledTimes(1);
    await expect(store.reassertAssistantCompletion(
      "session", "operation", "other", "2026-01-01T00:00:01.000Z",
    )).rejects.toThrow("different assistant completion");
  });

  it("syncs marker files and their directory for accepted and exact completion evidence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-durable-"));
    const events: string[] = [];
    const fileSystem = {
      mkdir,
      rename: async (...arguments_: Parameters<typeof rename>) => {
        events.push("rename");
        await rename(...arguments_);
      },
      rm,
      open: async (...arguments_: Parameters<typeof open>) => {
        const handle = await open(...arguments_);
        const isDirectory = arguments_[1] === "r";
        events.push(isDirectory ? "directory-open" : "temporary-open");
        return new Proxy(handle, {
          get(target, property) {
            if (property === "sync") {
              return async () => {
                events.push(isDirectory ? "directory-sync" : "file-sync");
                await target.sync();
              };
            }
            const value = Reflect.get(target, property, target) as unknown;
            return typeof value === "function" ? value.bind(target) : value;
          },
        });
      },
    };
    const store = new RunMarkerStore(root, { fileSystem: fileSystem as never });
    await store.mark("session", "operation");
    await store.markAssistantCompletion("session", "operation", "completion", "2026-01-01T00:00:00.000Z");
    expect(events).toEqual([
      "temporary-open", "file-sync", "rename", "directory-open", "directory-sync",
      "temporary-open", "file-sync", "rename", "directory-open", "directory-sync",
    ]);
  });

  it("removes an uncommitted temporary marker after a sync failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-failure-"));
    const remove = vi.fn(async () => {});
    const close = vi.fn(async () => {});
    const store = new RunMarkerStore(root, {
      fileSystem: {
        mkdir: vi.fn(async () => undefined),
        open: vi.fn(async () => ({
          writeFile: vi.fn(async () => {}),
          sync: vi.fn(async () => { throw new Error("injected marker sync failure"); }),
          close,
        })),
        rename: vi.fn(async () => {}),
        rm: remove,
      } as never,
    });
    await expect(store.mark("session", "operation")).rejects.toThrow("injected marker sync failure");
    expect(close).toHaveBeenCalledOnce();
    expect(remove).toHaveBeenCalledWith(expect.stringMatching(/\.tmp$/u), { force: true });
  });

  it("migrates v1 evidence on mutation without inventing a completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-v1-"));
    const directory = join(root, "gateway", "runtime-markers");
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, "session.json"), JSON.stringify({
      version: 1,
      sessionId: "session",
      operationId: "legacy-operation",
      acceptedAt: "2026-01-01T00:00:00.000Z",
    }));
    const store = new RunMarkerStore(root);

    expect(await store.evidenceFor("session")).toEqual([expect.objectContaining({
      operationId: "legacy-operation",
    })]);
    expect((await store.evidenceFor("session"))[0]!.assistantCompletionId).toBeUndefined();
    await store.mark("session", "new-operation");
    const migrated = JSON.parse(await readFile(join(directory, "session.json"), "utf8")) as {
      version: number;
      operations: Array<{ operationId: string; assistantCompletionId?: string }>;
    };
    expect(migrated.version).toBe(2);
    expect(migrated.operations.map((operation) => operation.operationId))
      .toEqual(["legacy-operation", "new-operation"]);
    expect(migrated.operations[0]!.assistantCompletionId).toBeUndefined();
  });

  it("rejects new ownership at the document bound without dropping retained evidence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-bound-"));
    const store = new RunMarkerStore(root);
    for (let index = 0; index < MAXIMUM_RUN_MARKER_OPERATIONS; index += 1) {
      await store.mark("session", `operation-${index}`);
    }
    await expect(store.mark("session", "overflow")).rejects.toThrow("bound reached");
    expect((await store.evidenceFor("session")).map((operation) => operation.operationId))
      .toEqual(Array.from({ length: MAXIMUM_RUN_MARKER_OPERATIONS }, (_, index) => `operation-${index}`));
  });

  it("cleans lanes after sequential operations across many sessions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-many-"));
    const store = new RunMarkerStore(root);
    for (let index = 0; index < 100; index += 1) {
      const sessionId = `session-${index}`;
      await store.mark(sessionId, `operation-${index}`);
      await store.clear(sessionId, `operation-${index}`);
    }
    expect((store as unknown as { lanes: Map<string, unknown> }).lanes.size).toBe(0);
  });

  it("keeps queued same-session work serialized and removes the lane after all callers settle", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-queued-"));
    const store = new RunMarkerStore(root);
    await Promise.all([
      ...Array.from({ length: 12 }, (_, index) => store.mark("same-session", `operation-${index}`)),
      ...Array.from({ length: 12 }, (_, index) => store.clear("same-session", `operation-${index}`)),
    ]);
    expect((store as unknown as { lanes: Map<string, unknown> }).lanes.size).toBe(0);
  });
});
