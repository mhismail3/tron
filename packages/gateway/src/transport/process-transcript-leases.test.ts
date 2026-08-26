import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { ProcessTranscriptLeaseStore } from "./process-transcript-leases.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

function page(revision: string, total = 0, fileIdentity = "1:1") {
  return { items: [], start: 0, end: 0, total, revision, fileIdentity };
}

function admission(path: string) {
  return { path, fileIdentity: "1:1" };
}

describe("ProcessTranscriptLeaseStore", () => {
  it("keeps leases connection-owned and closes them explicitly", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-lease-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const notify = vi.fn();

    const opened = await store.open("client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify);
    expect(opened).toMatchObject({ processId: "process-1", childSessionRef: "child-1", revision: "revision-1" });
    await expect(store.page("client-2", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
    await expect(store.page("client-1", opened.leaseId, undefined, undefined, "stale")).rejects.toMatchObject({ code: "conflict" });
    await store.page("client-1", opened.leaseId);
    expect(sessions.readOnlySubagentTranscriptPage).toHaveBeenLastCalledWith(
      "child-1", path, "parent-1", "process-1", "run-1", undefined, undefined, "1:1",
    );
    expect(store.closeOwned("client-1", opened.leaseId)).toBe(true);
    await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });

  it("serializes same-lease page and refresh revisions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-page-lane-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let releaseFirstPage: (() => void) | undefined;
    let reads = 0;
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => {
        reads += 1;
        if (reads === 1) return page("revision-1");
        if (reads === 2) {
          await new Promise<void>((resolve) => { releaseFirstPage = resolve; });
          return page("revision-2", 1);
        }
        return page("revision-3", 2);
      }),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const opened = await store.open(
      "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn(),
    );
    const first = store.page("client-1", opened.leaseId, undefined, undefined, "revision-1");
    await vi.waitFor(() => expect(reads).toBe(2));
    const staleConcurrent = store.page("client-1", opened.leaseId, undefined, undefined, "revision-1");
    await Promise.resolve();
    expect(reads).toBe(2);
    releaseFirstPage?.();
    await expect(first).resolves.toMatchObject({ revision: "revision-2" });
    await expect(staleConcurrent).rejects.toMatchObject({ code: "conflict", retryable: true });
    expect(reads).toBe(2);
    store.releaseClient("client-1");
  });

  it("releases every child observer with its parent presentation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-parent-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
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
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
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
    // Invalidation announces revision-2 but revision-1 remains the client's
    // acknowledged lease generation until this same-lease refresh completes.
    await expect(store.page(
      "client-1", opened.leaseId, undefined, undefined, "revision-1",
    )).resolves.toMatchObject({ revision: "revision-2", total: 1 });
    await expect(store.page(
      "client-1", opened.leaseId, undefined, undefined, "revision-1",
    )).rejects.toMatchObject({ code: "conflict" });
    store.releaseClient("client-1");
  });

  it("does not lose an append between watcher installation and baseline publication", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-open-race-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let reads = 0;
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => {
        reads += 1;
        if (reads === 1) {
          await writeFile(path, "{\"appendedDuringOpen\":true}\n");
          return page("revision-1");
        }
        return page("revision-2", 1);
      }),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const notify = vi.fn();
    const opened = await store.open(
      "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify,
    );
    await vi.waitFor(() => expect(notify).toHaveBeenCalledWith(
      "session.processTranscript.changed",
      "parent-1",
      expect.objectContaining({ leaseId: opened.leaseId, revision: "revision-2" }),
    ));
    store.releaseClient("client-1");
  });

  it("closes an invalidated lease when exact authorization or file identity changes", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-replaced-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let replaced = false;
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => {
        if (replaced) throw Object.assign(new Error("replaced"), { code: "conflict", retryable: true });
        return page("revision-1");
      }),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const notify = vi.fn();
    const opened = await store.open("client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify);
    replaced = true;
    await writeFile(path, "{\"replaced\":true}\n");
    await vi.waitFor(() => expect(notify).toHaveBeenCalledWith(
      "session.processTranscript.changed",
      "parent-1",
      expect.objectContaining({ leaseId: opened.leaseId, closed: true, reason: "session unavailable" }),
    ));
    await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });

  it("retires an inactive lease at its bounded timeout", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-timeout-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
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
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
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
