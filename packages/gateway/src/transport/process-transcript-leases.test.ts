import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { ProcessTranscriptLeaseStore } from "./process-transcript-leases.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

function page(revision: string, total = 0, fileIdentity = "1:1", forkBoundary?: { kind: "sessionFork" | "subagentFork"; inheritedAnchorId: string; gapOrdinal: number }) {
  return { items: [], start: 0, end: 0, total, revision, fileIdentity, ...(forkBoundary ? { forkBoundary } : {}) };
}

function admission(path: string) {
  return { path, fileIdentity: "1:1" };
}

async function openLease(store: ProcessTranscriptLeaseStore, ...args: any[]) {
  const final = args.at(-1);
  const hasOptions = final && typeof final === "object" && typeof final.viewerId === "string";
  if (hasOptions) return store.open(...args as any);
  const options = { viewerId: `viewer-${String(args[2])}`, parentSubscriptionToken: "token-1" };
  return args.length === 7
    ? store.open(...args, undefined, options)
    : store.open(...args, options);
}

describe("ProcessTranscriptLeaseStore", () => {
  it("retains retired viewers' physical read capacity until their reads settle", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-read-retirement-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    let blocked = false;
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => { if (blocked) await barrier; return page("revision-1"); }),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const reads: Promise<unknown>[] = [];
    let excess: ReturnType<ProcessTranscriptLeaseStore["reserveOpen"]> | undefined;
    try {
      for (const process of ["one", "two"]) {
        blocked = false;
        const lease = await openLease(store, "client", "parent", process, "child", "run", undefined, vi.fn());
        blocked = true;
        const count = vi.mocked(sessions.readOnlySubagentTranscriptPage).mock.calls.length;
        reads.push(store.page("client", lease.leaseId).catch(error => error));
        await vi.waitFor(() => expect(sessions.readOnlySubagentTranscriptPage).toHaveBeenCalledTimes(count + 1));
        store.closeOwned("client", lease.leaseId);
        store.closeOwned("client", lease.leaseId); // repeated close must not release physical ownership
      }
      expect(() => { excess = store.reserveOpen("client", "parent", "viewer-three", "token"); }).toThrow(/capacity/u);
      release();
      expect(await Promise.all(reads)).toEqual([expect.objectContaining({ code: "not_found" }), expect.objectContaining({ code: "not_found" })]);
      const next = await openLease(store, "client", "parent", "four", "child", "run", undefined, vi.fn());
      expect(next.processId).toBe("four");
    } finally { release(); excess?.release(); await Promise.all(reads); store.releaseClient("client"); }
  });

  it("retires a published viewer before its opening reservation is released", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-handoff-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const store = new ProcessTranscriptLeaseStore({
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry);
    const pending = store.reserveOpen("client", "parent", "viewer", "token");
    const notify = vi.fn();
    try {
      await pending.open("process", "child", "run", undefined, notify);
      pending.retire();
      await expect(store.page("client", "viewer")).rejects.toMatchObject({ code: "not_found" });
      expect(notify).toHaveBeenCalledWith("session.processTranscript.changed", "parent", expect.objectContaining({ leaseId: "viewer", closed: true }));
    } finally { pending.release(); store.releaseClient("client"); }
  });
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

    const opened = await openLease(store, "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify);
    expect(opened).toMatchObject({
      processId: "process-1", childSessionRef: "child-1", canAbort: false, revision: "revision-1",
    });
    await expect(store.abortOwned("client-1", opened.leaseId))
      .rejects.toMatchObject({ code: "conflict", retryable: true });
    await expect(store.page("client-2", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
    await expect(store.page("client-1", opened.leaseId, undefined, undefined, "stale")).rejects.toMatchObject({ code: "conflict" });
    await store.page("client-1", opened.leaseId);
    expect(sessions.readOnlySubagentTranscriptPage).toHaveBeenLastCalledWith(
      "child-1", path, "parent-1", "process-1", "run-1", undefined, undefined, "1:1", expect.any(AbortSignal),
    );
    expect(store.closeOwned("client-1", opened.leaseId)).toBe(true);
    await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });

  it("preserves fork-boundary annotations across open and page wire responses", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-boundary-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const boundary = { kind: "subagentFork" as const, inheritedAnchorId: "hidden", gapOrdinal: 0 };
    let reads = 0;
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => page(`revision-${++reads}`, 1, "1:1", boundary)),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const opened = await openLease(store, "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn());
    expect(opened.page.forkBoundary).toEqual(boundary);
    await expect(store.page("client-1", opened.leaseId, undefined, undefined, "revision-1"))
      .resolves.toMatchObject({ revision: "revision-2", forkBoundary: boundary });
    store.releaseClient("client-1");
  });

  it("revalidates an owned lease before forwarding the ordinary child abort", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-abort-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const abortSubagentProcess = vi.fn(async () => undefined);
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
      acquire: vi.fn(async () => ({ abortSubagentProcess })),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const opened = await openLease(store,
      "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn(),
      { expectedOperationId: "operation-1" },
    );

    expect(opened.canAbort).toBe(true);
    await expect(store.abortOwned("client-2", opened.leaseId))
      .rejects.toMatchObject({ code: "not_found" });
    await expect(store.abortOwned("client-1", opened.leaseId)).resolves.toBeUndefined();
    expect(sessions.resolveReadOnlySubagentPath).toHaveBeenLastCalledWith(
      "child-1", path, "parent-1", "process-1", "run-1",
    );
    expect(sessions.acquire).toHaveBeenCalledWith("parent-1");
    expect(abortSubagentProcess).toHaveBeenCalledWith(
      "process-1", "run-1", "operation-1",
    );
    store.releaseClient("client-1");
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
    const opened = await openLease(store,
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

  it("serializes invalidation behind the acknowledged page lane", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-invalidation-lane-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let releasePage: (() => void) | undefined;
    let reads = 0;
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => {
        reads += 1;
        if (reads === 1) return page("revision-1");
        if (reads === 2) {
          await new Promise<void>((resolve) => { releasePage = resolve; });
        }
        return page("revision-2", 1);
      }),
    } as unknown as RuntimeRegistry;
    const notify = vi.fn();
    const store = new ProcessTranscriptLeaseStore(sessions);
    const opened = await openLease(store,
      "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify,
    );
    const requestedPage = store.page(
      "client-1", opened.leaseId, undefined, undefined, "revision-1",
    );
    await vi.waitFor(() => expect(reads).toBe(2));
    const invalidation = (store as unknown as { invalidate: (leaseId: string) => Promise<void> })
      .invalidate(opened.leaseId);
    await Promise.resolve();
    expect(reads).toBe(2);
    releasePage?.();
    await expect(requestedPage).resolves.toMatchObject({ revision: "revision-2" });
    await invalidation;
    expect(reads).toBe(3);
    expect(notify).not.toHaveBeenCalled();
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
    const opened = await openLease(store, "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn());
    store.releaseParent("client-1", "parent-1");
    await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });

  it("does not let an old parent token retire a replacement viewer", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-parent-token-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => admission(path)),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const opened = await openLease(store,
      "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn(), undefined,
      { viewerId: "viewer-1", parentSubscriptionToken: "new-token" },
    );
    store.releaseParent("client-1", "parent-1", "old-token");
    await expect(store.page("client-1", opened.leaseId)).resolves.toMatchObject({ revision: "revision-1" });
    store.releaseParent("client-1", "parent-1", "new-token");
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
    const opened = await openLease(store, "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify);
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
    const opened = await openLease(store,
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
    const opened = await openLease(store, "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, notify);
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
      const opened = await openLease(store, "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn());
      await vi.advanceTimersByTimeAsync(30 * 60_000);
      await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects an already-aborted viewer reservation without consuming capacity", async () => {
    const sessions = {} as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const controller = new AbortController();
    controller.abort();
    expect(() => store.reserveOpen("client-1", "parent-1", "viewer-1", "token-1", controller.signal))
      .toThrowError(/retired/u);
  });

  it("retires a canceled open before a late admission response can publish a lease", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-open-cancel-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let releaseAdmission: (() => void) | undefined;
    const admission = new Promise<void>((resolve) => { releaseAdmission = resolve; });
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => {
        await admission;
        return { path, fileIdentity: "1:1" };
      }),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const controller = new AbortController();
    const opening = openLease(store,
      "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn(), undefined,
      { viewerId: "viewer-1", parentSubscriptionToken: "token-1", signal: controller.signal },
    );
    await vi.waitFor(() => expect(sessions.resolveReadOnlySubagentPath).toHaveBeenCalled());
    controller.abort();
    releaseAdmission?.();
    await expect(opening).rejects.toMatchObject({ code: "conflict", retryable: true });
    expect(sessions.readOnlySubagentTranscriptPage).not.toHaveBeenCalled();
    await expect(openLease(store,
      "client-1", "parent-1", "process-2", "child-2", "run-1", undefined, vi.fn(), undefined,
      { viewerId: "viewer-1", parentSubscriptionToken: "token-1" },
    )).resolves.toMatchObject({ leaseId: "viewer-1" });
  });

  it("enforces the per-parent viewer bound across in-flight and settled leases", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-opening-capacity-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let releaseAdmissions: (() => void) | undefined;
    const admissionBarrier = new Promise<void>((resolve) => { releaseAdmissions = resolve; });
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => {
        await admissionBarrier;
        return admission(path);
      }),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const first = openLease(store, "client-1", "parent-1", "process-1", "child-1", "run-1", undefined, vi.fn());
    const second = openLease(store, "client-1", "parent-1", "process-2", "child-2", "run-1", undefined, vi.fn());
    await vi.waitFor(() => expect(sessions.resolveReadOnlySubagentPath).toHaveBeenCalledTimes(2));
    await expect(openLease(store,
      "client-1", "parent-1", "process-3", "child-3", "run-1", undefined, vi.fn(),
    )).rejects.toMatchObject({ code: "busy", retryable: true });
    releaseAdmissions?.();
    const [firstLease] = await Promise.all([first, second]);
    await expect(openLease(store,
      "client-1", "parent-1", "process-3", "child-3", "run-1", undefined, vi.fn(),
    )).rejects.toMatchObject({ code: "busy", retryable: true });
    store.releaseClient("client-1");
    await expect(store.page("client-1", firstLease.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });

  it("reserves the total client capacity across concurrent parent opens", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-process-client-capacity-"));
    roots.push(root);
    const path = join(root, "child.jsonl");
    await writeFile(path, "{}\n");
    let releaseAdmissions: (() => void) | undefined;
    const admissionBarrier = new Promise<void>((resolve) => { releaseAdmissions = resolve; });
    const sessions = {
      resolveReadOnlySubagentPath: vi.fn(async () => {
        await admissionBarrier;
        return admission(path);
      }),
      readOnlySubagentTranscriptPage: vi.fn(async () => page("revision-1")),
    } as unknown as RuntimeRegistry;
    const store = new ProcessTranscriptLeaseStore(sessions);
    const openings = Array.from({ length: 8 }, (_, index) => openLease(store,
      "client-1", `parent-${index}`, `process-${index}`, `child-${index}`, "run-1", undefined, vi.fn(),
    ));
    await vi.waitFor(() => expect(sessions.resolveReadOnlySubagentPath).toHaveBeenCalledTimes(8));
    await expect(openLease(store,
      "client-1", "parent-9", "process-9", "child-9", "run-1", undefined, vi.fn(),
    )).rejects.toMatchObject({ code: "busy", retryable: true });
    releaseAdmissions?.();
    await Promise.all(openings);
    store.releaseClient("client-1");
  });
});
