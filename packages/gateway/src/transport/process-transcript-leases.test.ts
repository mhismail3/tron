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

    const opened = await store.open("client-1", "parent-1", "process-1", "child-1", undefined, notify);
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
    const opened = await store.open("client-1", "parent-1", "process-1", "child-1", undefined, vi.fn());
    store.releaseParent("client-1", "parent-1");
    await expect(store.page("client-1", opened.leaseId)).rejects.toMatchObject({ code: "not_found" });
  });
});
