import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  assertDelegatedRootCutoverReady,
  discoverDelegatedLegacyRoots,
  preflightDelegatedRootCutover,
} from "./delegated-root-migration.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  delete process.env.PI_SUBAGENTS_TEMP_ROOT;
});
async function fixture(prefix: string) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  roots.push(root);
  return root;
}

function destinationRoot(tronHome: string): string {
  return join(tronHome, "internal", "subagents");
}

async function retainedRun(root: string, state: "complete" | "running" = "complete"): Promise<string> {
  const run = join(root, "async-subagent-runs", "run-1");
  await mkdir(run, { recursive: true, mode: 0o700 });
  await writeFile(join(run, "status.json"), JSON.stringify({
    runId: "run-1", state, asyncDir: run,
    processTerminal: state === "complete" ? { state: "observed" } : undefined,
  }), { mode: 0o600 });
  return run;
}

describe("delegated provider root gate", () => {
  it("reports no migration required when the configured legacy root retains nothing", async () => {
    const tronHome = await fixture("tron-delegated-gate-idle-");
    const absent = join(tronHome, "absent-legacy-root");
    expect(await preflightDelegatedRootCutover({
      legacyRoots: [absent], destinationRoot: destinationRoot(tronHome),
    })).toMatchObject({ status: "not-required", changesMade: false });
    process.env.PI_SUBAGENTS_TEMP_ROOT = absent;
    await expect(assertDelegatedRootCutoverReady(tronHome)).resolves.toBeUndefined();
  });

  it("reports migration required when a legacy root retains a terminal run", async () => {
    const tronHome = await fixture("tron-delegated-gate-retained-");
    const legacyRoot = join(tronHome, "legacy-provider-root");
    await retainedRun(legacyRoot);
    const preflight = await preflightDelegatedRootCutover({
      legacyRoots: [legacyRoot], destinationRoot: destinationRoot(tronHome),
    });
    expect(preflight).toMatchObject({ status: "migration-required", changesMade: false });
    expect(preflight.roots[0]).toMatchObject({ root: legacyRoot, entries: 1, activeRuns: [], resumabilityRefusals: [] });
  });

  it("refuses startup while a legacy root retains work", async () => {
    const tronHome = await fixture("tron-delegated-gate-refusal-");
    const legacyRoot = join(tronHome, "legacy-provider-root");
    await retainedRun(legacyRoot);
    process.env.PI_SUBAGENTS_TEMP_ROOT = legacyRoot;
    await expect(assertDelegatedRootCutoverReady(tronHome)).rejects.toThrow(
      new RegExp(`delegated artifact migration required before startup; retained provider roots outside ${destinationRoot(tronHome)}: ${legacyRoot}\\.`),
    );
  });

  it("refuses startup when a retained legacy root conflicts with a published destination", async () => {
    const tronHome = await fixture("tron-delegated-gate-destination-");
    const legacyRoot = join(tronHome, "legacy-provider-root");
    await retainedRun(legacyRoot);
    const destination = destinationRoot(tronHome);
    await mkdir(destination, { recursive: true, mode: 0o700 });
    await writeFile(join(destination, "published.json"), "later", { mode: 0o600 });
    expect(await preflightDelegatedRootCutover({
      legacyRoots: [legacyRoot], destinationRoot: destination,
    })).toMatchObject({ status: "conflict", changesMade: false });
    process.env.PI_SUBAGENTS_TEMP_ROOT = legacyRoot;
    await expect(assertDelegatedRootCutoverReady(tronHome)).rejects.toThrow(
      new RegExp(`retained provider roots outside ${destination}.*move the retained work into ${destination}`),
    );
  });

  it("refuses an active or unresumable provider run instead of fabricating continuity", async () => {
    const tronHome = await fixture("tron-delegated-gate-active-");
    const legacyRoot = join(tronHome, "legacy-provider-root");
    await retainedRun(legacyRoot, "running");
    const active = await preflightDelegatedRootCutover({
      legacyRoots: [legacyRoot], destinationRoot: destinationRoot(tronHome),
    });
    expect(active.status).toBe("conflict");
    expect(active.roots[0]!.activeRuns).toHaveLength(1);

    await writeFile(join(legacyRoot, "async-subagent-runs", "run-1", "status.json"), JSON.stringify({
      runId: "run-1", state: "new-state",
    }));
    const unknown = await preflightDelegatedRootCutover({
      legacyRoots: [legacyRoot], destinationRoot: destinationRoot(tronHome),
    });
    expect(unknown.status).toBe("conflict");
    expect(unknown.roots[0]!.resumabilityRefusals).toHaveLength(1);
  });

  it("refuses a legacy root with writable-by-others entries or a redirected path", async () => {
    const tronHome = await fixture("tron-delegated-gate-unsafe-");
    const legacyRoot = join(tronHome, "legacy-provider-root");
    const run = await retainedRun(legacyRoot);
    await chmod(join(run, "status.json"), 0o666);
    await expect(preflightDelegatedRootCutover({
      legacyRoots: [legacyRoot], destinationRoot: destinationRoot(tronHome),
    })).rejects.toThrow(/private/);

    await chmod(join(run, "status.json"), 0o600);
    const redirect = join(tronHome, "redirected-legacy-root");
    await symlink(legacyRoot, redirect);
    await expect(preflightDelegatedRootCutover({
      legacyRoots: [redirect], destinationRoot: destinationRoot(tronHome),
    })).rejects.toThrow(/symlink/);
    process.env.PI_SUBAGENTS_TEMP_ROOT = redirect;
    await expect(assertDelegatedRootCutoverReady(tronHome)).rejects.toThrow(/symlink/);
  });

  it("discovers only the pinned provider temporary scope, preserving project history and test fixtures", async () => {
    const root = await fixture("tron-delegated-gate-discovery-");
    const tronHome = join(root, "home");
    const uidRoot = join(root, `pi-subagents-uid-${process.getuid!()}`);
    await retainedRun(uidRoot);
    await retainedRun(join(root, "pi-subagents-tool-desc-fixture"));
    await retainedRun(join(root, ".pi", "subagents"));
    await retainedRun(`${uidRoot}.retired-example`);
    const destination = destinationRoot(tronHome);
    expect(discoverDelegatedLegacyRoots({ destinationRoot: destination, tempDirectory: root })).toEqual([uidRoot]);
    expect(discoverDelegatedLegacyRoots({ destinationRoot: destination, legacyRoot: destination })).toEqual([]);
    expect(discoverDelegatedLegacyRoots({ destinationRoot: destination, legacyRoot: uidRoot })).toEqual([uidRoot]);
  });
});
