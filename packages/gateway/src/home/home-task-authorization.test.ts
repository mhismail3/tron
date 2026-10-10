import { describe, expect, it } from "vitest";
import { HomeTaskAuthorization, type HomeTaskAuthorizationState } from "./home-task-authorization.js";
import { issueGrant } from "../../test-support/home-task-grant.js";

function fixture() {
  let state: HomeTaskAuthorizationState = { revision: 1, scopes: [], requests: [], grants: [], decisions: [] };
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
    intentDigest: "intent-digest-1",
    target: "/trusted/project",
    authorizationScope: "project-work",
    restoreEpoch: "epoch-1",
  };
  return { owner, store, request, diagnostics, advance: (delta: number) => { now += delta; }, revokeTrust: (path: string) => trusted.delete(path) };
}

describe("HomeTaskAuthorization", () => {
  it("explicitly reconfirms only active standing scopes, never revoked scopes or restored grants", async () => {
    const { owner, request, store } = fixture();
    const revoked = await owner.enableInitialScope("older-epoch");
    await owner.revokeScope(revoked.id);
    const grant = await issueGrant(owner, request, { decisionId: "restored-grant", expiresAt: 2_000 });
    const active = await owner.enableInitialScope(request.restoreEpoch);
    await expect(owner.authorize({ ...request, restoreEpoch: "restored-epoch" })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
    await owner.reconfirmPermissions("restored-epoch");
    const state = await store.load();
    expect(state.scopes.find(scope => scope.id === active.id)).toMatchObject({ active: true, restoreEpoch: "restored-epoch" });
    expect(state.scopes.find(scope => scope.id === revoked.id)).toMatchObject({ active: false, restoreEpoch: "older-epoch" });
    expect(state.grants.find(candidate => candidate.id === grant.id)).toMatchObject({ state: "available", restoreEpoch: request.restoreEpoch });
    await expect(owner.authorize({ ...request, restoreEpoch: "restored-epoch" })).resolves.toMatchObject({ scopeId: active.id });
    await owner.revokeScope(active.id);
    await owner.reconfirmPermissions("restored-epoch");
    await expect(owner.authorize({ ...request, restoreEpoch: "restored-epoch" })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
  });
  it("binds a standing scope to its restore epoch and requires explicit reconfirmation after restore", async () => {
    const { owner, request, diagnostics } = fixture();
    const scope = await owner.enableInitialScope(request.restoreEpoch);
    await expect(owner.authorize(request)).resolves.toMatchObject({ kind: "standing-scope", scopeId: scope.id });
    await expect(owner.authorize({ ...request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
    diagnostics.length = 0;
    await owner.reconfirmPermissions("epoch-2");
    expect(diagnostics).toEqual([{ event: "home.task.authorization", outcome: "permissions-reconfirmed" }]);
    await expect(owner.authorize({ ...request, restoreEpoch: "epoch-2" })).resolves.toMatchObject({ kind: "standing-scope", scopeId: scope.id });
    await expect(owner.authorize(request)).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
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
    const grant = await issueGrant(owner, request, { decisionId: "decision-1", expiresAt: 2_000 });
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
    await expect(issueGrant(owner, request, {
      decisionId: "denied", approved: false, expiresAt: 2_000,
    })).resolves.toBeNull();
    expect(await store.load()).toMatchObject({
      decisions: [{ id: "denied", approved: false }], grants: [],
    });
    expect(diagnostics).toEqual([
      { event: "home.task.authorization", outcome: "request-recorded", referenceHash: expect.any(String) },
      { event: "home.task.authorization", outcome: "refused", reason: "grant-required", referenceHash: expect.any(String) },
      { event: "home.task.authorization", outcome: "decision-recorded", referenceHash: expect.any(String) },
    ]);

    diagnostics.length = 0;
    await expect(issueGrant(owner, request, {
      decisionId: "expired-input", expiresAt: 1_000,
    })).rejects.toMatchObject({ code: "invalid-decision" });
    const duplicateRequest = { ...request, intentDigest: "other-intent" };
    await issueGrant(owner, duplicateRequest, { decisionId: "duplicate", expiresAt: 2_000 });
    await expect(issueGrant(owner, duplicateRequest, {
      decisionId: "duplicate", expiresAt: 2_000,
    })).rejects.toMatchObject({ code: "invalid-decision" });
    expect(diagnostics).toContainEqual({
      event: "home.task.authorization", outcome: "refused", reason: "invalid-decision", referenceHash: expect.any(String),
    });
    expect(diagnostics.filter((record) => record.event === "home.task.authorization"
      && record.outcome === "refused" && record.reason === "invalid-decision")).toHaveLength(2);
    expect(diagnostics).toContainEqual({
      event: "home.task.authorization", outcome: "decision-recorded", referenceHash: expect.any(String),
    });
  });

  // FM4: removing the task-level dimensions must not widen the remaining match.
  it("consumes a one-use grant only for its exact binding, and only once", async () => {
    const { owner, request } = fixture();
    await issueGrant(owner, request, { decisionId: "exact", expiresAt: 2_000 });
    await expect(owner.authorize({ ...request, intentDigest: "other-intent" })).rejects.toMatchObject({ code: "grant-required" });
    await expect(owner.authorize({ ...request, target: "/trusted/other" })).rejects.toMatchObject({ code: "grant-required" });
    await expect(owner.authorize({ ...request, authorizationScope: "read-only" })).rejects.toMatchObject({ code: "grant-required" });
    await expect(owner.authorize({ ...request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
    await expect(owner.authorize(request)).resolves.toMatchObject({ kind: "one-use-grant" });
    await expect(owner.authorize(request)).rejects.toMatchObject({ code: "grant-required" });
  });

  it("rejects expired, mismatched, revoked, spent and restore-epoch-stale grants", async () => {
    const expired = fixture();
    await issueGrant(expired.owner, expired.request, { decisionId: "expired", expiresAt: 2_000 });
    expired.advance(1_000);
    await expect(expired.owner.authorize(expired.request)).rejects.toMatchObject({ code: "grant-required" });

    const mismatched = fixture();
    await issueGrant(mismatched.owner, mismatched.request, { decisionId: "mismatch", expiresAt: 2_000 });
    await expect(mismatched.owner.authorize({ ...mismatched.request, authorizationScope: "read-only" })).rejects.toMatchObject({ code: "grant-required" });

    const revoked = fixture();
    const grant = await issueGrant(revoked.owner, revoked.request, { decisionId: "revoked", expiresAt: 2_000 });
    await revoked.owner.revokeGrant(grant.id);
    await expect(revoked.owner.authorize(revoked.request)).rejects.toMatchObject({ code: "grant-required" });

    const restored = fixture();
    await issueGrant(restored.owner, restored.request, { decisionId: "stale-epoch", expiresAt: 2_000 });
    await expect(restored.owner.authorize({ ...restored.request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
  });
});
