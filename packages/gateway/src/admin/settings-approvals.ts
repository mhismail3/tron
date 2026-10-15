import { createHash, randomUUID } from "node:crypto";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { readJson, updateJsonLocked } from "../util/json.js";
import type { Actor, TierBasis } from "./settings-record.js";
import type { FixedSetting, SettingsTarget } from "./settings-resolver.js";
import type { LayerId, Qualifiers, Tier } from "./settings-types.js";

/**
 * Pending settings changes (docs/settings-model.md 5.5, decision 8, Q22).
 *
 * A request whose tier is `approve`, from anyone but the maintainer's own tap,
 * waits here for his decision. The record holds every fact about it (pending,
 * approved, declined, expired, superseded); this store holds only what the
 * record cannot answer cheaply: which requests are still open, the exact diff a
 * decision binds to, and whether the requester has been told of an outcome.
 * A request that is decided and told is dropped; the record keeps it forever.
 */

export const APPROVAL_TTL_MS = 24 * 60 * 60 * 1_000;
/** Open requests are refused past this, so an agent cannot flood the maintainer. */
export const MAXIMUM_PENDING_APPROVALS = 100;
/** Decided requests kept until their requester is told. */
const MAXIMUM_UNTOLD = 400;

export type ApprovalStatus = "pending" | "approved" | "declined" | "expired" | "superseded" | "failed";

export interface PendingChange {
  changeId: string;
  key: string;
  qualifiers?: Qualifiers;
  layer: Exclude<LayerId, "builtin">;
  op: "set" | "unset";
  /** Absent for a redacted key: the diff names the key, never the value. */
  before?: unknown;
  after?: unknown;
  fixedAt?: FixedSetting;
  redacted?: true;
  tier: Tier;
  tierBasis: TierBasis;
}

export interface ApprovalRequest {
  requestId: string;
  createdAt: string;
  expiresAt: string;
  target: SettingsTarget;
  actor: Actor;
  reason?: string;
  changes: PendingChange[];
  /** What a decision binds to (no approve-then-swap). */
  digest: string;
  status: ApprovalStatus;
  decidedAt?: string;
  failure?: string;
  /** The requester's next turn named the outcome (Q22). */
  told?: true;
}

interface ApprovalsDocument { version: 1; requests: ApprovalRequest[] }
const EMPTY: ApprovalsDocument = { version: 1, requests: [] };

/** The digest of a diff: the target and each change's instance, before and after. */
export function approvalDigest(target: SettingsTarget, changes: readonly PendingChange[]): string {
  return createHash("sha256").update(JSON.stringify({
    target,
    changes: changes.map(change => [change.key, change.qualifiers ?? {}, change.layer, change.op, change.before ?? null, change.after ?? null, change.fixedAt ?? null]),
  })).digest("hex");
}

const instanceId = (target: SettingsTarget, change: PendingChange) => JSON.stringify([target, change.layer, change.key, change.qualifiers ?? {}]);

export class SettingsApprovals {
  readonly path: string;

  constructor(tronHome: string) {
    this.path = join(tronHome, "gateway", "settings", "approvals.json");
  }

  /** Opens a request. An open request for any of the same key instances is
   * superseded by it: only the newest diff can be approved. */
  async create(input: Omit<ApprovalRequest, "requestId" | "createdAt" | "expiresAt" | "digest" | "status">, now: Date): Promise<{ request: ApprovalRequest; superseded: ApprovalRequest[] }> {
    const request: ApprovalRequest = {
      ...input, requestId: randomUUID(), createdAt: now.toISOString(), expiresAt: new Date(now.getTime() + APPROVAL_TTL_MS).toISOString(),
      digest: approvalDigest(input.target, input.changes), status: "pending",
    };
    const instances = new Set(request.changes.map(change => instanceId(request.target, change)));
    const superseded: ApprovalRequest[] = [];
    await this.update(document => {
      if (document.requests.filter(candidate => candidate.status === "pending").length >= MAXIMUM_PENDING_APPROVALS) {
        throw new GatewayError("busy", "Too many settings changes are waiting for approval", true);
      }
      for (const candidate of document.requests) {
        if (candidate.status !== "pending" || !candidate.changes.some(change => instances.has(instanceId(candidate.target, change)))) continue;
        candidate.status = "superseded";
        candidate.decidedAt = request.createdAt;
        superseded.push({ ...candidate });
      }
      document.requests.push(request);
    });
    return { request, superseded };
  }

  /** Every request past its 24 hours becomes expired (never applied). */
  async expire(now: Date): Promise<ApprovalRequest[]> {
    const expired: ApprovalRequest[] = [];
    const due = (await this.read()).requests.some(request => request.status === "pending" && Date.parse(request.expiresAt) <= now.getTime());
    if (!due) return expired;
    await this.update(document => {
      for (const request of document.requests) {
        if (request.status !== "pending" || Date.parse(request.expiresAt) > now.getTime()) continue;
        request.status = "expired";
        request.decidedAt = now.toISOString();
        expired.push({ ...request });
      }
    });
    return expired;
  }

  async pending(): Promise<ApprovalRequest[]> {
    return (await this.read()).requests.filter(request => request.status === "pending");
  }

  async get(requestId: string): Promise<ApprovalRequest | undefined> {
    return (await this.read()).requests.find(request => request.requestId === requestId);
  }

  /** Settles an open request; refused unless it is still pending. */
  async settle(requestId: string, status: Exclude<ApprovalStatus, "pending">, now: Date, failure?: string): Promise<ApprovalRequest> {
    let settled: ApprovalRequest | undefined;
    await this.update(document => {
      const request = document.requests.find(candidate => candidate.requestId === requestId);
      if (!request) throw new GatewayError("not_found", "No such settings approval");
      if (request.status !== "pending") throw new GatewayError("conflict", `This change is no longer waiting for approval (${request.status})`);
      request.status = status;
      request.decidedAt = now.toISOString();
      if (failure) request.failure = failure;
      // An approved change was the requester's own wish; nothing to tell.
      if (status === "approved") request.told = true;
      settled = { ...request };
    });
    return settled!;
  }

  /** The requester's untold outcomes, marked told (Q22). */
  async takeOutcomes(sessionId: string): Promise<ApprovalRequest[]> {
    const untold = (await this.read()).requests.some(request => request.actor.sessionId === sessionId && request.status !== "pending" && !request.told);
    if (!untold) return [];
    const taken: ApprovalRequest[] = [];
    await this.update(document => {
      for (const request of document.requests) {
        if (request.actor.sessionId !== sessionId || request.status === "pending" || request.told) continue;
        request.told = true;
        taken.push({ ...request });
      }
    });
    return taken;
  }

  private async read(): Promise<ApprovalsDocument> {
    const document = await readJson<ApprovalsDocument>(this.path, EMPTY);
    if (document.version !== 1 || !Array.isArray(document.requests)) throw new GatewayError("conflict", "The settings approvals store could not be read");
    return document;
  }

  private async update(change: (document: ApprovalsDocument) => void): Promise<void> {
    await updateJsonLocked<ApprovalsDocument>(this.path, EMPTY, current => {
      if (current.version !== 1 || !Array.isArray(current.requests)) throw new GatewayError("conflict", "The settings approvals store could not be read");
      const document: ApprovalsDocument = { version: 1, requests: current.requests.map(request => ({ ...request })) };
      change(document);
      // Decided and told requests live on only in the record; untold ones are
      // bounded, oldest first, so a requester that never runs again cannot grow it.
      const open = document.requests.filter(request => request.status === "pending");
      const untold = document.requests.filter(request => request.status !== "pending" && !request.told).slice(-MAXIMUM_UNTOLD);
      document.requests = [...open, ...untold].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
      return document;
    });
  }
}
