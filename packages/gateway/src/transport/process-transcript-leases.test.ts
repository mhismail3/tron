import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { ProcessTranscriptLeaseStore } from "./process-transcript-leases.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

function page(revision: string, total = 0) {
  return { items: [], start: 0, end: 0, total, revision };
}

describe("ProcessTranscriptLeaseStore", () => {
  it("keeps leases connection-owned and closes them explicitly", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-lease-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => path),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const notify = vi.fn();

    const opened = await store.open("client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify);
    expect(opened).toMatchObject({ processId: "process-1", childSessionRef: "child-1", revision: "revision-1" });
    await expect(store.page("client-2", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
    await expect(store.page("client-1", opened.leaseId, undefined, undefined, "stale")).rejects.toMatchObject({ code: "conflict" });
    expect(store.closeOwned("client-1", opened.leaseId)).toBe(true);
    await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });

  it("releases every child observer with its parent presentation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-parent-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => path),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const opened = await store.open("client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn());
    store.releaseParent("client-1", "parent-1");
    await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });

  it("emits a lease-scoped invalidation when the canonical child changes", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-invalidation-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let revision = "revision-1";
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => path),
      readOnlySubagentTranscriptPage: vi.fn(async () => page(revision, revision === "revision-1" ? 0 : 1)),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const notify = vi.fn();
    const opened = await store.open("client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify);
    revision = "revision-2";
    await writeFile(path, "{\"changed\":true}\n");
    await vi.waitFor(() => expect(notify).toHaveBeenCalledWith(
      "session.processTranscript.changed",
      "parent-1",
      expect.objectContaining({ leaseId: opened.leaseId, revision: "revision-2", total: 1 }),
    ));
    store.releaseClient("client-1");
  });

  it("retires an inactive lease at its bounded timeout", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-timeout-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => path),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    vi.useFakeTimers();
    try {
      const store = new ProcessTranscriptLeaseStore(sessions);
      const opened = await store.open("client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn());
      await vi.advanceTimersByTimeAsync(30 * 60_000);
      await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
    } finally {
      vi.useRealTimers();
    }
  });

  it("enforces a bounded lease count for each client and parent session", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-capacity-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => path),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const first = await store.open("client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn());
    await store.open("client-1", "parent-1", "process-2", "child-2", "run-1", undefined, vi.fn());
    await expect(store.open("client-1", "parent-1", "process-3", "child-3", "run-1", undefined, vi.fn()))
      .rejects.toMatchObject({ code: "busy", retryable: true });
    store.releaseClient("client-1");
    await expect(store.page("client-1", first.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });
});
