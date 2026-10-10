import { createHash, randomUUID } from "node:crypto";
import { AsyncMutex } from "../util/async-mutex.js";

export interface HomeTaskAuthorizationRequest {
  intentDigest: string;
  target: string;
  authorizationScope: string;
  /** Supplied by the restore authority; this owner never creates or advances it. */
  restoreEpoch: string;
}

export interface HomeTaskAuthorizationScope {
  id: string;
  kind: "all-trusted-projects";
  active: boolean;
  restoreEpoch: string;
  createdAt: number;
  revokedAt?: number;
}

export interface HomeTaskAuthorizationDecision {
  id: string;
  decidedAt: number;
  approved: boolean;
  requestId: string;
  expiresAt: number;
}

export interface HomeTaskOneUseGrant {
  id: string;
  decisionId: string;
  intentDigest: string;
  target: string;
  authorizationScope: string;
  restoreEpoch: string;
  expiresAt: number;
  state: "available" | "consumed" | "revoked";
}

export interface HomeTaskAuthorizationState {
  /** Durable compare-and-replace revision, advanced only by the store. */
  revision: number;
  scopes: HomeTaskAuthorizationScope[];
  requests: Array<{ id: string; request: HomeTaskAuthorizationRequest }>;
  decisions: HomeTaskAuthorizationDecision[];
  grants: HomeTaskOneUseGrant[];
}

export interface HomeTaskAuthorizationStore {
  load(): Promise<HomeTaskAuthorizationState>;
  save(state: HomeTaskAuthorizationState): Promise<void>;
}

export interface HomeTaskAuthorizationOptions {
  store: HomeTaskAuthorizationStore;
  now?: () => number;
  /** Canonicalizes and verifies that the directory is trusted at decision time. */
  resolveTrustedTarget(target: string): Promise<string | undefined>;
  diagnostic?: (record: HomeTaskAuthorizationDiagnostic) => void;
}

export interface HomeTaskAuthorizationDiagnostic {
  event: "home.task.authorization";
  outcome: "scope-enabled" | "scope-revoked" | "permissions-reconfirmed" | "request-recorded" | "decision-recorded" | "grant-revoked" | "grant-consumed" | "refused";
  reason?: "untrusted-target" | "grant-required" | "invalid-decision" | "scope-reconfirmation-required";
  referenceHash?: string;
}

export type HomeTaskAuthorizationResult =
  | { kind: "standing-scope"; scopeId: string }
  | { kind: "one-use-grant"; grantId: string };

export class HomeTaskAuthorizationError extends Error {
  constructor(readonly code: "untrusted-target" | "grant-required" | "invalid-decision" | "scope-reconfirmation-required", readonly requestId?: string) {
    super(requestId ? `${code}: ${requestId}` : code);
    this.name = "HomeTaskAuthorizationError";
  }
}

/** Owns task authorization decisions, separately from task execution state. */
export class HomeTaskAuthorization {
  private readonly mutex = new AsyncMutex();
  private readonly now: () => number;

  constructor(private readonly options: HomeTaskAuthorizationOptions) {
    this.now = options.now ?? Date.now;
  }

  /** Appends the first standing scope of a freshly initialized namespace. The
   * store refuses a second active scope, so no earlier scope is retired here. */
  async enableInitialScope(restoreEpoch: string): Promise<HomeTaskAuthorizationScope> {
    return this.mutex.run(async () => {
      const state = await this.options.store.load();
      const scope: HomeTaskAuthorizationScope = {
        id: randomUUID(), kind: "all-trusted-projects", active: true, restoreEpoch, createdAt: this.now(),
      };
      await this.options.store.save({ ...state, scopes: [...state.scopes, scope] });
      this.diagnostic("scope-enabled", scope.id);
      return scope;
    });
  }

  /** Explicit maintainer control only. A restore never renews one-use grants or
   * resurrects revoked scopes; their original authority remains inspectable. */
  async reconfirmPermissions(restoreEpoch: string): Promise<void> {
    await this.mutex.run(async () => {
      const state = await this.options.store.load();
      await this.options.store.save({ ...state, scopes: state.scopes.map(scope => scope.active
        ? { ...scope, restoreEpoch } : scope) });
      this.diagnostic("permissions-reconfirmed");
    });
  }

  async revokeScope(scopeId: string): Promise<void> {
    await this.mutex.run(async () => {
      const state = await this.options.store.load();
      const scope = state.scopes.find((candidate) => candidate.id === scopeId);
      if (!scope || !scope.active) return;
      await this.options.store.save({
        ...state,
        scopes: state.scopes.map((candidate) => candidate.id === scopeId
          ? { ...candidate, active: false, revokedAt: this.now() }
          : candidate),
      });
      this.diagnostic("scope-revoked", scopeId);
    });
  }

  async list(): Promise<HomeTaskAuthorizationState> {
    return this.mutex.run(() => this.options.store.load());
  }

  async recordDecisionAndGrant(
    requestId: string,
    input: { decisionId: string; approved: boolean; expiresAt: number; restoreEpoch: string },
  ): Promise<{ decision: HomeTaskAuthorizationDecision; grant: HomeTaskOneUseGrant | null }> {
    return this.mutex.run(async () => {
      const state = await this.options.store.load();
      const pending = state.requests.find(candidate => candidate.id === requestId);
      if (!pending || state.decisions.some(decision => decision.requestId === requestId || decision.id === input.decisionId)
        || !input.decisionId || typeof input.approved !== "boolean" || !Number.isSafeInteger(input.expiresAt)
        || input.expiresAt <= this.now() || pending.request.restoreEpoch !== input.restoreEpoch) {
        this.diagnostic("refused", requestId, "invalid-decision");
        throw new HomeTaskAuthorizationError("invalid-decision");
      }
      const request = pending.request;
      if (await this.resolveTarget(request.target) !== request.target) throw new HomeTaskAuthorizationError("invalid-decision");
      const decision: HomeTaskAuthorizationDecision = {
        id: input.decisionId, requestId, decidedAt: this.now(), approved: input.approved, expiresAt: input.expiresAt,
      };
      const grant: HomeTaskOneUseGrant | null = decision.approved ? {
        id: randomUUID(), decisionId: decision.id, ...request, expiresAt: input.expiresAt, state: "available",
      } : null;
      await this.options.store.save({ ...state, decisions: [...state.decisions, decision],
        grants: grant ? [...state.grants, grant] : state.grants });
      this.diagnostic("decision-recorded", decision.id);
      return { decision, grant };
    });
  }

  async revokeGrant(grantId: string): Promise<void> {
    await this.mutex.run(async () => {
      const state = await this.options.store.load();
      const grant = state.grants.find(candidate => candidate.id === grantId);
      if (!grant || grant.state !== "available") return;
      await this.options.store.save({ ...state,
        grants: state.grants.map(candidate => candidate.id === grantId ? { ...candidate, state: "revoked" } : candidate) });
      this.diagnostic("grant-revoked", grantId);
    });
  }

  async authorize(request: HomeTaskAuthorizationRequest): Promise<HomeTaskAuthorizationResult> {
    const target = await this.resolveTarget(request.target);
    return this.mutex.run(async () => {
      const state = await this.options.store.load();
      const scope = state.scopes.find((candidate) => candidate.kind === "all-trusted-projects"
        && candidate.active && candidate.restoreEpoch === request.restoreEpoch);
      if (scope) return { kind: "standing-scope", scopeId: scope.id };
      const grant = state.grants.find((candidate) => candidate.state === "available"
        && candidate.expiresAt > this.now()
        && candidate.intentDigest === request.intentDigest
        && candidate.target === target
        && candidate.authorizationScope === request.authorizationScope
        && candidate.restoreEpoch === request.restoreEpoch);
      if (!grant) {
        if (state.scopes.some(candidate => candidate.active && candidate.restoreEpoch !== request.restoreEpoch)
          || state.grants.some(candidate => candidate.state === "available" && candidate.restoreEpoch !== request.restoreEpoch)) {
          this.diagnostic("refused", undefined, "scope-reconfirmation-required");
          throw new HomeTaskAuthorizationError("scope-reconfirmation-required");
        }
        // The exact binding owns request identity across refusals/restart. A
        // decided request cannot mint a second grant by asking again.
        const binding = { ...request, target };
        const requestId = authorizationRequestId(binding);
        if (!state.requests.some(candidate => candidate.id === requestId)) {
          await this.options.store.save({ ...state, requests: [...state.requests, { id: requestId, request: binding }] });
          this.diagnostic("request-recorded", requestId);
        }
        this.diagnostic("refused", requestId, "grant-required");
        throw new HomeTaskAuthorizationError("grant-required", requestId);
      }
      await this.options.store.save({
        ...state,
        grants: state.grants.map((candidate) => candidate.id === grant.id ? { ...candidate, state: "consumed" } : candidate),
      });
      this.diagnostic("grant-consumed", grant.id);
      return { kind: "one-use-grant", grantId: grant.id };
    });
  }

  private async resolveTarget(target: string): Promise<string> {
    const resolved = await this.options.resolveTrustedTarget(target);
    if (!resolved) {
      this.diagnostic("refused", undefined, "untrusted-target");
      throw new HomeTaskAuthorizationError("untrusted-target");
    }
    return resolved;
  }

  private diagnostic(
    outcome: HomeTaskAuthorizationDiagnostic["outcome"],
    reference?: string,
    reason?: HomeTaskAuthorizationDiagnostic["reason"],
  ): void {
    this.options.diagnostic?.({
      event: "home.task.authorization", outcome,
      ...(reason === undefined ? {} : { reason }),
      ...(reference === undefined ? {} : {
        referenceHash: createHash("sha256").update(reference).digest("hex").slice(0, 16),
      }),
    });
  }
}

/** Explicit key order makes identity independent of transport object order. */
export function authorizationRequestId(request: HomeTaskAuthorizationRequest): string {
  return createHash("sha256").update(JSON.stringify([request.intentDigest, request.target,
    request.authorizationScope, request.restoreEpoch])).digest("hex");
}
