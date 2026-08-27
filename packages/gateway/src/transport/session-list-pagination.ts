import { createHmac, randomBytes } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { SessionSummary } from "../protocol/types.js";

export interface SessionListPage {
  sessions: SessionSummary[];
  listRevision: number;
  nextCursor?: string;
}

interface CatalogGeneration {
  key: string;
  scope: "user" | "all";
  sessions: readonly SessionSummary[];
  listRevision: number;
  byteCount: number;
}

interface SessionListLease {
  id: string;
  clientID: string;
  scope: "user" | "all";
  generationKey: string;
  sessionCount: number;
  byteCount: number;
  listRevision: number;
  expiresAt: number;
  lastAccess: number;
}

/**
 * Bounded, disposable immutable projections for session.list traversals.
 * Cursors are authenticated and bound to one client, scope, offset, revision,
 * and materialization. Canonical catalog truth remains in RuntimeRegistry.
 *
 * RuntimeRegistry supplies a generation for indexed catalog snapshots. The
 * store validates and freezes that source once, then leases share it instead
 * of cloning and JSON-sizing the entire catalog for each client. Catalogs from
 * older/mock callers without a generation retain the conservative per-request
 * behavior.
 */
export class SessionListPaginationStore {
  private readonly leases = new Map<string, SessionListLease>();
  private readonly generations = new Map<string, CatalogGeneration>();
  private readonly secret: Buffer;

  constructor(private readonly options: {
    now?: () => number;
    maxLeases?: number;
    maxSessionsPerLease?: number;
    maxTotalSessions?: number;
    maxBytesPerLease?: number;
    maxTotalBytes?: number;
    maxLeasesPerClient?: number;
    leaseTTLms?: number;
    secret?: Buffer;
  } = {}) {
    this.secret = options.secret ?? randomBytes(32);
  }

  get activeLeaseCount(): number {
    this.prune();
    return this.leases.size;
  }

  releaseClient(clientID: string): void {
    for (const [id, lease] of this.leases) {
      if (lease.clientID === clientID) this.leases.delete(id);
    }
    this.pruneGenerations();
  }

  firstPage(
    clientID: string,
    scope: "user" | "all",
    catalog: { sessions: SessionSummary[]; listRevision: number; generation?: string },
    limit: number,
  ): SessionListPage {
    this.prune();
    // A one-page response needs no cursor lease. Validate its bounded wire
    // size, but do not retain a complete generation that cannot be referenced.
    if (catalog.sessions.length <= limit) {
      this.validateCatalogBudget(catalog.sessions);
      const page: SessionSummary[] = catalog.sessions
        .map((session) => Object.freeze({ ...session }));
      return { sessions: page, listRevision: catalog.listRevision };
    }
    const generation = this.admitGeneration(scope, catalog);
    const sessions = generation.sessions;
    const page: SessionSummary[] = [...sessions.slice(0, limit)];

    this.evictForCapacity(clientID, sessions.length, generation.byteCount);
    const now = this.now();
    let id: string;
    do { id = randomBytes(6).toString("hex"); } while (this.leases.has(id));
    const lease: SessionListLease = {
      id,
      clientID,
      scope,
      generationKey: generation.key,
      sessionCount: sessions.length,
      byteCount: generation.byteCount,
      listRevision: generation.listRevision,
      expiresAt: now + (this.options.leaseTTLms ?? 30_000),
      lastAccess: now,
    };
    this.leases.set(id, lease);
    return {
      sessions: page,
      listRevision: lease.listRevision,
      nextCursor: this.cursor(lease, page.length),
    };
  }

  nextPage(clientID: string, scope: "user" | "all", cursor: string, limit: number): SessionListPage {
    this.prune();
    const parsed = this.parse(cursor);
    const lease = this.leases.get(parsed.leaseID);
    if (!lease || lease.clientID !== clientID || lease.scope !== scope) this.invalidCursor();
    const expected = this.signature(lease!, parsed.offset);
    const generation = this.generations.get(lease!.generationKey);
    if (parsed.signature !== expected || parsed.offset <= 0
      || parsed.offset >= lease!.sessionCount || !generation) {
      this.invalidCursor();
    }

    lease!.lastAccess = this.now();
    const sessions = generation!.sessions.slice(parsed.offset, parsed.offset + limit);
    const nextOffset = parsed.offset + sessions.length;
    if (nextOffset >= lease!.sessionCount) this.leases.delete(lease!.id);
    this.pruneGenerations();
    return {
      sessions,
      listRevision: lease!.listRevision,
      ...(nextOffset < lease!.sessionCount ? { nextCursor: this.cursor(lease!, nextOffset) } : {}),
    };
  }

  private admitGeneration(
    scope: "user" | "all",
    catalog: { sessions: SessionSummary[]; listRevision: number; generation?: string },
  ): CatalogGeneration {
    const maximumSessions = Math.min(
      this.options.maxSessionsPerLease ?? 25_000,
      this.options.maxTotalSessions ?? 50_000,
    );
    if (catalog.sessions.length > maximumSessions) {
      throw new GatewayError("busy", "The session catalog is too large for one bounded traversal", true);
    }
    const maximumBytes = Math.min(
      this.options.maxBytesPerLease ?? 4 * 1_024 * 1_024,
      this.options.maxTotalBytes ?? 8 * 1_024 * 1_024,
    );
    const key = catalog.generation ?? `request:${scope}:${catalog.listRevision}:${randomBytes(8).toString("hex")}`;
    const existing = this.generations.get(key);
    if (existing) {
      if (existing.scope !== scope || existing.listRevision !== catalog.listRevision) this.invalidCursor();
      return existing;
    }

    const byteCount = this.validateCatalogBudget(catalog.sessions, maximumBytes);
    // One clone/freeze establishes an immutable generation. Subsequent clients
    // and pages share these objects and do not repeat whole-catalog work.
    const sessions = Object.freeze(catalog.sessions.map((session) => Object.freeze({ ...session })));
    const generation: CatalogGeneration = {
      key,
      scope,
      sessions,
      listRevision: catalog.listRevision,
      byteCount,
    };
    this.generations.set(key, generation);
    return generation;
  }

  private validateCatalogBudget(sessions: readonly SessionSummary[], maximumBytes?: number): number {
    const maxBytes = maximumBytes ?? Math.min(
      this.options.maxBytesPerLease ?? 4 * 1_024 * 1_024,
      this.options.maxTotalBytes ?? 8 * 1_024 * 1_024,
    );
    let byteCount = 0;
    for (const session of sessions) {
      byteCount += Buffer.byteLength(JSON.stringify(session));
      if (byteCount > maxBytes) {
        throw new GatewayError("busy", "The session catalog is too large for one bounded traversal", true);
      }
    }
    return byteCount;
  }

  private cursor(lease: SessionListLease, offset: number): string {
    return `${lease.id}.${offset.toString(36)}.${this.signature(lease, offset)}`;
  }

  private signature(lease: SessionListLease, offset: number): string {
    return createHmac("sha256", this.secret)
      .update(`${lease.id}\0${lease.clientID}\0${lease.scope}\0${lease.listRevision}\0${lease.generationKey}\0${offset}`)
      .digest("base64url")
      .slice(0, 11);
  }

  private parse(cursor: string): { leaseID: string; offset: number; signature: string } {
    const parts = cursor.split(".");
    if (parts.length !== 3 || !/^[a-f0-9]{12}$/.test(parts[0]!) || !/^[0-9a-z]+$/.test(parts[1]!)
      || !/^[A-Za-z0-9_-]{11}$/.test(parts[2]!)) this.invalidCursor();
    const offset = Number.parseInt(parts[1]!, 36);
    if (!Number.isSafeInteger(offset)) this.invalidCursor();
    return { leaseID: parts[0]!, offset, signature: parts[2]! };
  }

  private prune(): void {
    const now = this.now();
    for (const [id, lease] of this.leases) {
      if (lease.expiresAt <= now) this.leases.delete(id);
    }
    this.pruneGenerations();
  }

  private pruneGenerations(): void {
    const referenced = new Set([...this.leases.values()].map((lease) => lease.generationKey));
    for (const key of this.generations.keys()) {
      if (!referenced.has(key)) this.generations.delete(key);
    }
  }

  private evictForCapacity(clientID: string, incomingSessionCount: number, incomingBytes: number): void {
    const maxLeases = this.options.maxLeases ?? 16;
    const maxLeasesPerClient = this.options.maxLeasesPerClient ?? 2;
    const maxTotalSessions = this.options.maxTotalSessions ?? 50_000;
    const maxTotalBytes = this.options.maxTotalBytes ?? 8 * 1_024 * 1_024;
    let retainedSessions = [...this.leases.values()]
      .reduce((total, lease) => total + lease.sessionCount, 0);
    let retainedBytes = [...this.leases.values()]
      .reduce((total, lease) => total + lease.byteCount, 0);
    let clientLeaseCount = [...this.leases.values()].filter((lease) => lease.clientID === clientID).length;
    while (this.leases.size >= maxLeases
      || clientLeaseCount >= maxLeasesPerClient
      || retainedSessions + incomingSessionCount > maxTotalSessions
      || retainedBytes + incomingBytes > maxTotalBytes) {
      const clientOverLimit = clientLeaseCount >= maxLeasesPerClient;
      let oldest: SessionListLease | undefined;
      for (const lease of this.leases.values()) {
        if (clientOverLimit && lease.clientID !== clientID) continue;
        if (!oldest || lease.lastAccess < oldest.lastAccess) oldest = lease;
      }
      if (!oldest) break;
      this.leases.delete(oldest.id);
      retainedSessions -= oldest.sessionCount;
      retainedBytes -= oldest.byteCount;
      if (oldest.clientID === clientID) clientLeaseCount -= 1;
    }
  }

  private now(): number {
    return (this.options.now ?? Date.now)();
  }

  private invalidCursor(): never {
    throw new GatewayError("invalid_request", "The session list cursor is invalid or expired", true);
  }
}
