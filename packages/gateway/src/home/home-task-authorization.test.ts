import { describe, expect, it } from "vitest";
import { HomeTaskAuthorization, type HomeTaskAuthorizationState } from "./home-task-authorization.js";

function fixture() {
  let state: HomeTaskAuthorizationState = { scopes: [], grants: [], decisions: [] };
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
  });
  const request = {
    intentRevision: 1,
    intentDigest: "intent-digest-1",
    target: "/trusted/project",
    workerProfile: "home-task-v1",
    policyRevision: 1,
    restoreEpoch: "epoch-1",
  };
  return { owner, store, request, advance: (delta: number) => { now += delta; }, revokeTrust: (path: string) => trusted.delete(path) };
}

describe("HomeTaskAuthorization", () => {
  it("allows all currently trusted project targets under the initial standing scope and rechecks trust at admission", async () => {
    const { owner, request, revokeTrust } = fixture();
    const scope = await owner.enableInitialScope();
    await expect(owner.authorize(request)).resolves.toMatchObject({ kind: "standing-scope", scopeId: scope.id });
    revokeTrust(request.target);
    await expect(owner.authorize(request)).rejects.toMatchObject({ code: "untrusted-target" });
  });

  it("revokes a standing scope and requires explicit authorization outside any active scope", async () => {
    const { owner, request } = fixture();
    const scope = await owner.enableInitialScope();
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

  it("rejects expired, mismatched, revoked, spent and restore-epoch-stale grants", async () => {
    const expired = fixture();
    await expired.owner.recordDecisionAndGrant(expired.request, { decisionId: "expired", expiresAt: 2_000 });
    expired.advance(1_000);
    await expect(expired.owner.authorize(expired.request)).rejects.toMatchObject({ code: "grant-required" });

    const mismatched = fixture();
    await mismatched.owner.recordDecisionAndGrant(mismatched.request, { decisionId: "mismatch", expiresAt: 2_000 });
    await expect(mismatched.owner.authorize({ ...mismatched.request, intentRevision: 2 })).rejects.toMatchObject({ code: "grant-required" });

    const revoked = fixture();
    const grant = await revoked.owner.recordDecisionAndGrant(revoked.request, { decisionId: "revoked", expiresAt: 2_000 });
    await revoked.owner.revokeGrant(grant.id);
    await expect(revoked.owner.authorize(revoked.request)).rejects.toMatchObject({ code: "grant-required" });

    const restored = fixture();
    await restored.owner.recordDecisionAndGrant(restored.request, { decisionId: "stale-epoch", expiresAt: 2_000 });
    await expect(restored.owner.authorize({ ...restored.request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "grant-required" });
  });
});
