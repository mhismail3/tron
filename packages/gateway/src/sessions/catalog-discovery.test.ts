import { mkdtemp, mkdir, opendir, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CatalogDiscovery, DEFAULT_CATALOG_DISCOVERY_LIMITS, visitConcurrently } from "./catalog-discovery.js";

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

    const forward = discovery(false);
    const reverse = discovery(true);
    const forwardEvidence = await forward.catalogStructureEvidence();
    const reverseEvidence = await reverse.catalogStructureEvidence();
    expect(reverseEvidence.digest).toBe(forwardEvidence.digest);
    expect(reverseEvidence.factsDigest).toBe(forwardEvidence.factsDigest);
    expect((await reverse.sessionInfos("all")).map((session) => session.id))
      .toEqual((await forward.sessionInfos("all")).map((session) => session.id));
    expect((await forward.sessionInfos("all")).map((session) => session.id)).toEqual(["alpha", "middle", "zeta"]);
  });
});
