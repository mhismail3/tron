import { createHash, randomUUID } from "node:crypto";
import { AsyncMutex } from "../util/async-mutex.js";

export interface HomeTaskAuthorizationRequest {
  intentRevision: number;
  intentDigest: string;
  target: string;
  authorizationScope: string;
  workerProfile: string;
  policyRevision: number;
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
}

export interface HomeTaskOneUseGrant {
  id: string;
  decisionId: string;
  intentRevision: number;
  intentDigest: string;
  target: string;
  authorizationScope: string;
  workerProfile: string;
  policyRevision: number;
  restoreEpoch: string;
  expiresAt: number;
  state: "available" | "consumed" | "revoked";
}

export interface HomeTaskAuthorizationState {
  /** Durable compare-and-replace revision, advanced only by the store. */
  revision: number;
  scopes: HomeTaskAuthorizationScope[];
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
  outcome: "scope-enabled" | "scope-revoked" | "decision-recorded" | "grant-consumed" | "refused";
  reason?: "untrusted-target" | "grant-required" | "invalid-decision" | "scope-reconfirmation-required";
  referenceHash?: string;
}

export type HomeTaskAuthorizationResult =
  | { kind: "standing-scope"; scopeId: string }
  | { kind: "one-use-grant"; grantId: string };

export class HomeTaskAuthorizationError extends Error {
  constructor(readonly code: "untrusted-target" | "grant-required" | "invalid-decision" | "scope-reconfirmation-required") {
    super(code);
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

  async enableInitialScope(restoreEpoch: string): Promise<HomeTaskAuthorizationScope> {
    return this.mutex.run(async () => {
      const state = await this.options.store.load();
      const existing = state.scopes.find((scope) => scope.kind === "all-trusted-projects"
        && scope.active && scope.restoreEpoch === restoreEpoch);
      if (existing) return existing;
      const createdAt = this.now();
      const scope: HomeTaskAuthorizationScope = {
        id: randomUUID(), kind: "all-trusted-projects", active: true, restoreEpoch, createdAt,
      };
      const retiredScopes = state.scopes.filter((scope) => scope.kind === "all-trusted-projects" && scope.active);
      const scopes = state.scopes.map((scope) => scope.kind === "all-trusted-projects" && scope.active
        ? { ...scope, active: false, revokedAt: createdAt }
        : scope);
      await this.options.store.save({ ...state, scopes: [...scopes, scope] });
      for (const retired of retiredScopes) this.diagnostic("scope-revoked", retired.id);
      this.diagnostic("scope-enabled", scope.id);
      return scope;
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

  async recordDecisionAndGrant(
    request: HomeTaskAuthorizationRequest,
    input: { decisionId: string; approved?: boolean; expiresAt: number },
  ): Promise<HomeTaskOneUseGrant> {
    const target = await this.resolveTarget(request.target);
    if (!input.decisionId || !Number.isFinite(input.expiresAt) || input.expiresAt <= this.now()) {
      this.diagnostic("refused", undefined, "invalid-decision");
      throw new HomeTaskAuthorizationError("invalid-decision");
    }
    return this.mutex.run(async () => {
      const state = await this.options.store.load();
      if (state.decisions.some((decision) => decision.id === input.decisionId)) {
        this.diagnostic("refused", undefined, "invalid-decision");
        throw new HomeTaskAuthorizationError("invalid-decision");
      }
      const decision: HomeTaskAuthorizationDecision = {
        id: input.decisionId, decidedAt: this.now(), approved: input.approved ?? true,
      };
      if (!decision.approved) {
        await this.options.store.save({ ...state, decisions: [...state.decisions, decision] });
        this.diagnostic("decision-recorded", decision.id);
        this.diagnostic("refused", undefined, "grant-required");
        throw new HomeTaskAuthorizationError("grant-required");
      }
      const grant: HomeTaskOneUseGrant = {
        id: randomUUID(), decisionId: decision.id,
        intentRevision: request.intentRevision, intentDigest: request.intentDigest,
        target, authorizationScope: request.authorizationScope,
        workerProfile: request.workerProfile, policyRevision: request.policyRevision,
        restoreEpoch: request.restoreEpoch, expiresAt: input.expiresAt, state: "available",
      };
      await this.options.store.save({
        ...state, decisions: [...state.decisions, decision], grants: [...state.grants, grant],
      });
      this.diagnostic("decision-recorded", decision.id);
      return grant;
    });
  }

  async revokeGrant(grantId: string): Promise<void> {
    await this.mutex.run(async () => {
      const state = await this.options.store.load();
      await this.options.store.save({
        ...state,
        grants: state.grants.map((grant) => grant.id === grantId && grant.state === "available"
          ? { ...grant, state: "revoked" }
          : grant),
      });
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
        && candidate.intentRevision === request.intentRevision
        && candidate.intentDigest === request.intentDigest
        && candidate.target === target
        && candidate.authorizationScope === request.authorizationScope
        && candidate.workerProfile === request.workerProfile
        && candidate.policyRevision === request.policyRevision
        && candidate.restoreEpoch === request.restoreEpoch);
      if (!grant) {
        if (state.scopes.some(candidate => candidate.active && candidate.restoreEpoch !== request.restoreEpoch)
          || state.grants.some(candidate => candidate.state === "available" && candidate.restoreEpoch !== request.restoreEpoch)) {
          this.diagnostic("refused", undefined, "scope-reconfirmation-required");
          throw new HomeTaskAuthorizationError("scope-reconfirmation-required");
        }
        this.diagnostic("refused", undefined, "grant-required");
        throw new HomeTaskAuthorizationError("grant-required");
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
