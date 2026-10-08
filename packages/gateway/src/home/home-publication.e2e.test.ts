import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

const publication = vi.hoisted(() => ({ failAfterVisibleWrite: false }));
vi.mock("../util/durable-json.js", async importOriginal => {
  const actual = await importOriginal<typeof import("../util/durable-json.js")>();
  return {
    ...actual,
    durablePublishBoundedJson: async (...args: Parameters<typeof actual.durablePublishBoundedJson>) => {
      await actual.durablePublishBoundedJson(...args);
      if (publication.failAfterVisibleWrite) {
        publication.failAfterVisibleWrite = false;
        const error = new Error("injected directory synchronization failure") as Error & { publicationVisible?: true };
        error.publicationVisible = true;
        throw error;
      }
    },
  };
});

import { TrustService } from "../admin/trust-service.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeOwner } from "./home-owner.js";

const roots: string[] = [];
afterEach(async () => {
  publication.failAfterVisibleWrite = false;
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

describe("Home durable publication reconciliation", () => {
  it("retires live Home slots before releasing a visible publication uncertainty fence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-home-publication-retire-"));
    roots.push(root);
    const retired: string[] = [];
    let releaseRetirement!: () => void;
    const retirementBlocked = new Promise<void>(resolve => { releaseRetirement = resolve; });
    let retirementStarted!: () => void;
    const started = new Promise<void>(resolve => { retirementStarted = resolve; });
    const tronHome = join(root, "tron");
    const workspace = new TronWorkspace(join(root, "workspace"));
    const owner = new HomeOwner({
      tronHome,
      trust: new TrustService(join(root, "agent")),
      workspace,
      sessions: {
        createHomeSession: async () => "session-1",
        sessionFile: async () => join(root, "sessions", "session-1.jsonl"),
        sessionPresent: async () => true,
        hasLiveRuntime: () => false,
        applySessionModel: async () => {},
        serializeSessionMutation: async (_id, commit) => commit(),
        replaceRuntimeForProfile: async (_sessionId, commit) => commit(),
        beginHomePublicationReconciliation: () => {},
        retireHomeRuntimes: async () => { retirementStarted(); await retirementBlocked; retired.push("all"); },
      },
      memorySummarizer: () => ({ summarizer: async () => "summary" }),
    });
    try {
      await owner.initialize();
      await owner.designate({ model: { provider: "faux", id: "chat" } }, () => ({ provider: "faux", id: "chat" }));
      publication.failAfterVisibleWrite = true;
      const disabling = owner.disable();
      await started;
      expect(() => owner.routeBinding()).toThrow(/unavailable/);
      expect(retired).toEqual([]);
      releaseRetirement();
      await expect(disabling).rejects.toThrow("injected directory synchronization failure");
      expect(retired).toEqual(["all"]);
      expect(await owner.status()).toMatchObject({ available: true, enabled: false });
    } finally {
      releaseRetirement();
      await workspace.dispose();
    }
  });

  it("reloads a visible disable instead of retaining stale enabled routing after writer error", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-home-publication-"));
    roots.push(root);
    const tronHome = join(root, "tron");
    const homeDirectory = join(tronHome, "gateway", "home");
    await mkdir(homeDirectory, { recursive: true });
    const workspace = new TronWorkspace(join(root, "workspace"));
    const owner = new HomeOwner({
      tronHome,
      trust: new TrustService(join(root, "agent")),
      workspace,
      sessions: {
        createHomeSession: async () => "session-1",
        sessionFile: async () => join(root, "sessions", "session-1.jsonl"),
        sessionPresent: async () => true,
        hasLiveRuntime: () => false,
        applySessionModel: async () => {},
        serializeSessionMutation: async (_id, commit) => commit(),
        replaceRuntimeForProfile: async (_sessionId, commit) => commit(),
        beginHomePublicationReconciliation: () => {},
        retireHomeRuntimes: async () => {},
      },
      memorySummarizer: () => ({ summarizer: async () => "summary" }),
    });
    try {
      await owner.initialize();
      await owner.designate({ model: { provider: "faux", id: "chat" } }, () => ({ provider: "faux", id: "chat" }));
      publication.failAfterVisibleWrite = true;
      await expect(owner.disable()).rejects.toThrow("injected directory synchronization failure");
      expect(JSON.parse(await readFile(join(homeDirectory, "home.json"), "utf8"))).toMatchObject({ enabled: false });
      expect(await owner.status()).toMatchObject({ available: true, enabled: false });
      expect(() => owner.routeBinding()).toThrow(/not enabled/);
    } finally {
      await workspace.dispose();
    }
  });
});
