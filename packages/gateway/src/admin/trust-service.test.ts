import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TrustService } from "./trust-service.js";

describe("TrustService", () => {
  it("blocks project executable resources until an explicit decision", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-trust-"));
    const workspace = join(root, "workspace");
    const agentDir = join(root, "agent");
    await mkdir(join(workspace, ".pi"), { recursive: true });
    await writeFile(join(workspace, ".pi", "settings.json"), "{}\n");
    const trust = new TrustService(agentDir);

    await expect(trust.requireResolved(workspace)).rejects.toMatchObject({ code: "trust_required" });
    await expect(trust.set(workspace, true)).resolves.toMatchObject({ effectiveDecision: true });
    const resolved = await trust.requireResolved(workspace);
    expect(resolved.trusted).toBe(true);
    expect(resolved.cwd).toMatch(/\/workspace$/);
    await expect(trust.set(workspace, false)).resolves.toMatchObject({ effectiveDecision: false });
  });

  it("keeps persisted readers on the prior decision until runtime preparation commits", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-trust-prepare-"));
    try {
      const workspace = join(root, "workspace");
      const agentDir = join(root, "agent");
      await mkdir(join(workspace, ".pi"), { recursive: true });
      await writeFile(join(workspace, ".pi", "settings.json"), "{}\n");
      const trust = new TrustService(agentDir);
      let duringApply: boolean | null | undefined;
      let duringCommit: boolean | null | undefined;

      await expect(trust.setAndApply(
        workspace,
        true,
        async () => { duringApply = (await trust.inspect(workspace)).savedDecision; },
        async () => { duringCommit = (await trust.inspect(workspace)).savedDecision; },
      )).resolves.toMatchObject({ savedDecision: true, effectiveDecision: true });

      expect(duringApply).toBe(null);
      expect(duringCommit).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("inherits parent trust when clearing and does not materialize inherited rollback entries", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-trust-inheritance-"));
    try {
      const parent = join(root, "workspace");
      const child = join(parent, "child");
      const agentDir = join(root, "agent");
      await mkdir(join(child, ".pi"), { recursive: true });
      await writeFile(join(child, ".pi", "settings.json"), "{}\n");
      const trust = new TrustService(agentDir);
      await trust.set(parent, true);
      await trust.set(child, false);
      const clearing: Array<boolean | null> = [];

      await trust.setAndApply(child, null, async (inspection) => {
        clearing.push(inspection.effectiveDecision);
      });
      expect(clearing).toEqual([true]);
      await expect(trust.inspect(child)).resolves.toMatchObject({ savedDecision: true, effectiveDecision: true });

      await expect(trust.setAndApply(child, false, async (inspection) => {
        if (inspection.effectiveDecision === false) throw new Error("reject child override");
      })).rejects.toThrow("reject child override");
      await trust.set(parent, false);
      await expect(trust.inspect(child)).resolves.toMatchObject({ savedDecision: false, effectiveDecision: false });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("restores exact persisted trust and reapplies runtime state when activation fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-trust-transaction-"));
    try {
      const workspace = join(root, "workspace");
      const agentDir = join(root, "agent");
      await mkdir(join(workspace, ".pi"), { recursive: true });
      await writeFile(join(workspace, ".pi", "settings.json"), "{}\n");
      const trust = new TrustService(agentDir);
      const observed: Array<boolean | null> = [];

      await expect(trust.setAndApply(workspace, true, async (inspection) => {
        observed.push(inspection.effectiveDecision);
        if (inspection.effectiveDecision === true) throw new Error("reload rejected new resources");
      })).rejects.toThrow("reload rejected new resources");

      expect(observed).toEqual([true, null]);
      await expect(trust.inspect(workspace)).resolves.toMatchObject({ savedDecision: null, effectiveDecision: null });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("surfaces rollback activation failures without reporting trust success", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-trust-rollback-"));
    try {
      const workspace = join(root, "workspace");
      const agentDir = join(root, "agent");
      await mkdir(join(workspace, ".pi"), { recursive: true });
      await writeFile(join(workspace, ".pi", "settings.json"), "{}\n");
      const trust = new TrustService(agentDir);
      let calls = 0;

      await expect(trust.setAndApply(workspace, true, async () => {
        calls += 1;
        throw new Error(calls === 1 ? "activation failed" : "rollback activation failed");
      })).rejects.toMatchObject({
        code: "internal",
        message: "Project trust failed and the previous runtime state could not be fully restored",
        details: {
          failure: "activation failed",
          rollbackFailure: "rollback activation failed",
        },
      });
      expect(calls).toBe(2);
      await expect(trust.inspect(workspace)).resolves.toMatchObject({ savedDecision: null, effectiveDecision: null });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("propagates a resolved source decision to a new worktree and rolls it back", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-trust-worktree-"));
    try {
      const source = join(root, "source");
      const target = join(root, "target");
      const agentDir = join(root, "agent");
      await mkdir(join(source, ".pi"), { recursive: true });
      await mkdir(join(target, ".pi"), { recursive: true });
      await writeFile(join(source, ".pi", "settings.json"), "{}\n");
      await writeFile(join(target, ".pi", "settings.json"), "{}\n");
      const trust = new TrustService(agentDir);
      await trust.set(source, true);

      const propagated = await trust.propagateResolvedDecision(source, target);
      await expect(trust.inspect(target)).resolves.toMatchObject({ savedDecision: true, effectiveDecision: true });
      await propagated.rollback();
      await expect(trust.inspect(target)).resolves.toMatchObject({ savedDecision: null, effectiveDecision: null });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
