import { mkdtemp, mkdir, opendir, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { BackgroundWorkScheduler } from "../background-work.js";
import { CatalogDiscovery, DEFAULT_CATALOG_DISCOVERY_LIMITS, buildCatalogSessionInfo, visitConcurrently } from "./catalog-discovery.js";

const roots: string[] = [];

afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

describe("catalog discovery", () => {
  it("stops admitting folders after the first failure and settles admitted work", async () => {
    const failure = new Error("folder read failed");
    const admitted: number[] = [];
    let releaseSlow!: () => void;
    let markSlowStarted!: () => void;
    const slowGate = new Promise<void>((resolve) => { releaseSlow = resolve; });
    const slowStarted = new Promise<void>((resolve) => { markSlowStarted = resolve; });
    const visit = visitConcurrently([0, 1, 2, 3], 2, async (value) => {
      admitted.push(value);
      if (value === 0) throw failure;
      if (value === 1) {
        markSlowStarted();
        await slowGate;
      }
    });
    await slowStarted;
    releaseSlow();
    await expect(visit).rejects.toBe(failure);
    expect(admitted).toEqual([0, 1]);
  });

  it("yields long metadata parses through the background scheduler without losing rows", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-yield-"));
    roots.push(root);
    const path = join(root, "large.jsonl");
    const header = { type: "session", id: "large", cwd: root, timestamp: "2026-01-01T00:00:00.000Z" };
    const messages = Array.from({ length: 600 }, (_, index) => ({
      type: "message", message: { role: "user", content: [{ type: "text", text: `entry-${index}-${"x".repeat(50)}` }] },
    }));
    await writeFile(path, [header, ...messages].map((entry) => JSON.stringify(entry)).join("\n") + "\n");
    const scheduler = new BackgroundWorkScheduler();
    scheduler.start({ requestsInFlight: () => false, eventLoopP99Ms: () => 0 });
    let yields = 0;
    try {
      const summary = await buildCatalogSessionInfo(path, async () => {
        yields += 1;
        await scheduler.yieldToLoop();
      });
      expect(summary).toMatchObject({ id: "large", messageCount: 600, firstMessage: "entry-0-" + "x".repeat(50) });
      expect(yields).toBeGreaterThan(1);
    } finally {
      scheduler.stop();
    }
  });

  it("returns identical evidence and path-ordered rows for different directory walk orders", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-order-"));
    roots.push(root);
    for (const name of ["zeta", "alpha", "middle"]) {
      const directory = join(root, name);
      await mkdir(directory);
      await writeFile(join(directory, `${name}.jsonl`), `${JSON.stringify({
        type: "session", id: name, cwd: root, timestamp: "2026-01-01T00:00:00.000Z",
      })}\n`);
    }
    const discovery = (reverse: boolean) => new CatalogDiscovery({
      limits: DEFAULT_CATALOG_DISCOVERY_LIMITS,
      catalogDirectory: () => root,
      catalogCapacityExceeded: () => { throw new Error("fixture exceeded discovery bounds"); },
      isLiveRuntimeOwnedPath: () => false,
      canonicalSessionPath: (path) => realpath(path),
      delegatedTopologyParentPath: () => undefined,
      openDirectory: reverse ? async (directory) => {
        const entries = await readdir(directory, { withFileTypes: true });
        return (async function* () { for (const entry of entries.reverse()) yield entry; })();
      } : async (directory) => opendir(directory),
    });

    // The walk's own cut and one read per candidate file, the two seams every
    // catalog reader shares; a reversed directory walk must not reorder either.
    const catalogIds = async (instance: CatalogDiscovery): Promise<string[]> => {
      const evidence = await instance.catalogStructureEvidence();
      const infos = await Promise.all([...evidence.identitiesByPath.keys()].map((path) => buildCatalogSessionInfo(path)));
      return infos.filter((info) => info !== null).map((info) => info!.id);
    };
    const forward = discovery(false);
    const reverse = discovery(true);
    const forwardEvidence = await forward.catalogStructureEvidence();
    const reverseEvidence = await reverse.catalogStructureEvidence();
    expect(reverseEvidence.digest).toBe(forwardEvidence.digest);
    expect(reverseEvidence.factsDigest).toBe(forwardEvidence.factsDigest);
    expect(await catalogIds(reverse)).toEqual(await catalogIds(forward));
    expect(await catalogIds(forward)).toEqual(["alpha", "middle", "zeta"]);
  });
});
