import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { HomeTaskAuthorization, type HomeTaskAuthorizationState } from "./home-task-authorization.js";

function fixture() {
  let state: HomeTaskAuthorizationState = { scopes: [], grants: [], decisions: [] };
  const diagnostics: Array<{ event: string; outcome: string; reason?: string }> = [];
  const store = {
    load: async () => structuredClone(state),
    save: async (next: HomeTaskAuthorizationState) => { state = structuredClone(next); },
  };
  let now = 1_000;
  const trusted = new Set(["/trusted/project", "/trusted/other"]);
  const owner = new HomeTaskAuthorization({
    store,
    now: () => now,
    resolveTrustedTarget: async (target) => trusted.has(target) ? target : undefined,
    diagnostic: (record) => diagnostics.push(record),
  });
  const request = {
    intentRevision: 1,
    intentDigest: "intent-digest-1",
    target: "/trusted/project",
    authorizationScope: "project-work",
    workerProfile: "home-task-v1",
    policyRevision: 1,
    restoreEpoch: "epoch-1",
  };
  return { owner, store, request, diagnostics, advance: (delta: number) => { now += delta; }, revokeTrust: (path: string) => trusted.delete(path) };
}

describe("HomeTaskAuthorization", () => {
  it("binds a standing scope to its restore epoch and requires explicit reconfirmation after restore", async () => {
    const { owner, request, diagnostics } = fixture();
    const scope = await owner.enableInitialScope(request.restoreEpoch);
    await expect(owner.authorize(request)).resolves.toMatchObject({ kind: "standing-scope", scopeId: scope.id });
    await expect(owner.authorize({ ...request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "grant-required" });
    diagnostics.length = 0;
    const confirmed = await owner.enableInitialScope("epoch-2");
    expect(confirmed.id).not.toBe(scope.id);
    const hash = (id: string) => createHash("sha256").update(id).digest("hex").slice(0, 16);
    expect(diagnostics).toEqual([
      { event: "home.task.authorization", outcome: "scope-revoked", referenceHash: hash(scope.id) },
      { event: "home.task.authorization", outcome: "scope-enabled", referenceHash: hash(confirmed.id) },
    ]);
    await expect(owner.authorize({ ...request, restoreEpoch: "epoch-2" })).resolves.toMatchObject({ kind: "standing-scope", scopeId: confirmed.id });
    await expect(owner.authorize(request)).rejects.toMatchObject({ code: "grant-required" });
  });

  it("allows all currently trusted project targets under a same-epoch standing scope and rechecks trust at admission", async () => {
    const { owner, request, revokeTrust } = fixture();
    await owner.enableInitialScope(request.restoreEpoch);
    await expect(owner.authorize(request)).resolves.toMatchObject({ kind: "standing-scope" });
    revokeTrust(request.target);
    await expect(owner.authorize(request)).rejects.toMatchObject({ code: "untrusted-target" });
  });

  it("revokes a standing scope and requires explicit authorization outside any active scope", async () => {
    const { owner, request } = fixture();
    const scope = await owner.enableInitialScope(request.restoreEpoch);
    await owner.revokeScope(scope.id);
    await expect(owner.authorize(request)).rejects.toMatchObject({ code: "grant-required" });
  });

  it("stores a human decision separately and atomically consumes an exact one-use grant", async () => {
    const { owner, request, store } = fixture();
    const grant = await owner.recordDecisionAndGrant(request, { decisionId: "decision-1", expiresAt: 2_000 });
    const saved = await store.load();
    expect(saved.decisions).toHaveLength(1);
    expect(saved.grants).toHaveLength(1);
    expect(saved.decisions[0]).not.toHaveProperty("grantId");
    expect(grant).not.toHaveProperty("decision");
    await expect(owner.authorize(request)).resolves.toMatchObject({ kind: "one-use-grant", grantId: grant.id });
    await expect(owner.authorize(request)).rejects.toMatchObject({ code: "grant-required" });
  });

  it("records denied decisions and emits bounded diagnostics for denied, invalid, and duplicate decisions", async () => {
    const { owner, request, store, diagnostics } = fixture();
    await expect(owner.recordDecisionAndGrant(request, {
      decisionId: "denied", approved: false, expiresAt: 2_000,
    })).rejects.toMatchObject({ code: "grant-required" });
    expect(await store.load()).toMatchObject({
      decisions: [{ id: "denied", approved: false }], grants: [],
    });
    expect(diagnostics).toEqual([
      { event: "home.task.authorization", outcome: "decision-recorded", referenceHash: expect.any(String) },
      { event: "home.task.authorization", outcome: "refused", reason: "grant-required" },
    ]);

    diagnostics.length = 0;
    await expect(owner.recordDecisionAndGrant(request, {
      decisionId: "expired-input", expiresAt: 1_000,
    })).rejects.toMatchObject({ code: "invalid-decision" });
    await owner.recordDecisionAndGrant(request, { decisionId: "duplicate", expiresAt: 2_000 });
    await expect(owner.recordDecisionAndGrant(request, {
      decisionId: "duplicate", expiresAt: 2_000,
    })).rejects.toMatchObject({ code: "invalid-decision" });
    expect(diagnostics).toContainEqual({
      event: "home.task.authorization", outcome: "refused", reason: "invalid-decision",
    });
    expect(diagnostics.filter((record) => record.event === "home.task.authorization"
      && record.outcome === "refused" && record.reason === "invalid-decision")).toHaveLength(2);
    expect(diagnostics).toContainEqual({
      event: "home.task.authorization", outcome: "decision-recorded", referenceHash: expect.any(String),
    });
  });

  it("rejects expired, mismatched, revoked, spent and restore-epoch-stale grants", async () => {
    const expired = fixture();
    await expired.owner.recordDecisionAndGrant(expired.request, { decisionId: "expired", expiresAt: 2_000 });
    expired.advance(1_000);
    await expect(expired.owner.authorize(expired.request)).rejects.toMatchObject({ code: "grant-required" });

    const mismatched = fixture();
    await mismatched.owner.recordDecisionAndGrant(mismatched.request, { decisionId: "mismatch", expiresAt: 2_000 });
    await expect(mismatched.owner.authorize({ ...mismatched.request, authorizationScope: "read-only" })).rejects.toMatchObject({ code: "grant-required" });

    const revoked = fixture();
    const grant = await revoked.owner.recordDecisionAndGrant(revoked.request, { decisionId: "revoked", expiresAt: 2_000 });
    await revoked.owner.revokeGrant(grant.id);
    await expect(revoked.owner.authorize(revoked.request)).rejects.toMatchObject({ code: "grant-required" });

    const restored = fixture();
    await restored.owner.recordDecisionAndGrant(restored.request, { decisionId: "stale-epoch", expiresAt: 2_000 });
    await expect(restored.owner.authorize({ ...restored.request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "grant-required" });
  });
});
