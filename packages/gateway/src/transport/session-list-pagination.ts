import { createHmac, randomBytes } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { SessionSummary } from "../protocol/types.js";

export interface SessionListPage {
  sessions: SessionSummary[];
  listRevision: number;
  nextCursor?: string;
}

export interface SessionListPageSource {
  readonly generation: string;
  readonly listRevision: number;
  readonly count: number;
  readonly compactByteEstimate: number;
  page(offset: number, limit: number): Promise<SessionSummary[]>;
}

interface CatalogGeneration {
  key: string;
  scope: "user" | "all";
  source: SessionListPageSource;
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
 * RuntimeRegistry supplies a generation-keyed compact page source for indexed
 * catalog snapshots. Leases share that source; only selected rows are hydrated
 * and encoded-budget checked per response.
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

  async firstPage(clientID: string, scope: "user" | "all", source: SessionListPageSource, limit: number): Promise<SessionListPage> {
    this.prune();
    this.validateSource(source, limit);
    // Hydration and wire validation happen before admitting a lease. A broken
    // source or oversized first page therefore cannot leak traversal state or
    // evict a valid lease.
    const page = await this.hydratePage(source, 0, limit);
    if (source.count <= limit) {
      return { sessions: page, listRevision: source.listRevision };
    }

    this.prune();
    const byteCount = source.compactByteEstimate;
    const existing = this.generations.get(source.generation);
    if (existing && (existing.scope !== scope || existing.source !== source
      || existing.listRevision !== source.listRevision || existing.byteCount !== byteCount)) {
      throw new GatewayError("busy", "The session catalog generation changed during traversal", true);
    }
    const generation = existing ?? { key: source.generation, scope, source, listRevision: source.listRevision, byteCount };
    this.evictForCapacity(clientID, source.count, byteCount);
    this.generations.set(source.generation, generation);
    const now = this.now();
    let id: string;
    do { id = randomBytes(6).toString("hex"); } while (this.leases.has(id));
    const lease: SessionListLease = { id, clientID, scope, generationKey: source.generation, sessionCount: source.count, byteCount, listRevision: source.listRevision, expiresAt: now + (this.options.leaseTTLms ?? 30_000), lastAccess: now };
    this.leases.set(id, lease);
    return { sessions: page, listRevision: source.listRevision, nextCursor: this.cursor(lease, page.length) };
  }

  async nextPage(clientID: string, scope: "user" | "all", cursor: string, limit: number): Promise<SessionListPage> {
    this.prune();
    const parsed = this.parse(cursor);
    const lease = this.leases.get(parsed.leaseID);
    const generation = lease ? this.generations.get(lease.generationKey) : undefined;
    if (!lease || !generation?.source || lease.clientID !== clientID || lease.scope !== scope || parsed.signature !== this.signature(lease, parsed.offset)
      || parsed.offset <= 0 || parsed.offset >= lease.sessionCount) this.invalidCursor();
    lease.lastAccess = this.now();
    let sessions: SessionSummary[];
    try {
      sessions = await this.hydratePage(generation.source, parsed.offset, limit);
    } catch (error) {
      // Runtime page sources are immutable in-memory projections. A rejected or
      // malformed slice is a permanent contract violation for this traversal.
      this.leases.delete(lease.id);
      this.pruneGenerations();
      throw error;
    }
    // Another request can evict or release this lease while a custom/test page
    // source is suspended. Never mint a cursor for retired ownership.
    if (this.leases.get(lease.id) !== lease) this.invalidCursor();
    const nextOffset = parsed.offset + sessions.length;
    if (nextOffset >= lease.sessionCount) this.leases.delete(lease.id);
    this.pruneGenerations();
    return { sessions, listRevision: lease.listRevision, ...(nextOffset < lease.sessionCount ? { nextCursor: this.cursor(lease, nextOffset) } : {}) };
  }

  private validateSource(source: SessionListPageSource, limit: number): void {
    const maximumSessions = Math.min(this.options.maxSessionsPerLease ?? 25_000, this.options.maxTotalSessions ?? 50_000);
    const maximumBytes = Math.min(this.options.maxBytesPerLease ?? 4 * 1_024 * 1_024, this.options.maxTotalBytes ?? 8 * 1_024 * 1_024);
    if (!Number.isSafeInteger(limit) || limit <= 0
      || !source.generation || !Number.isSafeInteger(source.listRevision) || source.listRevision < 0
      || !Number.isSafeInteger(source.count) || source.count < 0 || source.count > maximumSessions
      || !Number.isSafeInteger(source.compactByteEstimate) || source.compactByteEstimate < 0 || source.compactByteEstimate > maximumBytes) {
      throw new GatewayError("busy", "The session catalog is too large for one bounded traversal", true);
    }
  }

  private async hydratePage(source: SessionListPageSource, offset: number, limit: number): Promise<SessionSummary[]> {
    const sessions = await source.page(offset, limit);
    const expected = Math.min(limit, source.count - offset);
    if (!Array.isArray(sessions) || sessions.length !== expected
      || new Set(sessions.map((session) => session.id)).size !== sessions.length) {
      throw new GatewayError("busy", "The session catalog page source is inconsistent", true);
    }
    this.validateCatalogBudget(sessions);
    return sessions.map((session) => Object.freeze({ ...session }));
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
