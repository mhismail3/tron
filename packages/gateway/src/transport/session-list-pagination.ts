import { createHmac, randomBytes } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { SessionSummary } from "../protocol/types.js";

export interface SessionListPage {
  sessions: SessionSummary[];
  listRevision: number;
  nextCursor?: string;
}

interface SessionListLease {
  id: string;
  clientID: string;
  scope: "user" | "all";
  sessions: readonly SessionSummary[];
  listRevision: number;
  byteCount: number;
  expiresAt: number;
  lastAccess: number;
}

/**
 * Bounded, disposable immutable projections for session.list traversals.
 * Cursors are authenticated and bound to one client, scope, offset, revision,
 * and materialization. Canonical catalog truth remains in RuntimeRegistry.
 */
export class SessionListPaginationStore {
  private readonly leases = new Map<string, SessionListLease>();
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
  }

  firstPage(
    clientID: string,
    scope: "user" | "all",
    catalog: { sessions: SessionSummary[]; listRevision: number },
    limit: number,
  ): SessionListPage {
    this.prune();
    const maxSessions = Math.min(
      this.options.maxSessionsPerLease ?? 25_000,
      this.options.maxTotalSessions ?? 50_000,
    );
    if (catalog.sessions.length > maxSessions) {
      throw new GatewayError("busy", "The session catalog is too large for one bounded traversal", true);
    }
    const maxBytes = Math.min(
      this.options.maxBytesPerLease ?? 4 * 1_024 * 1_024,
      this.options.maxTotalBytes ?? 8 * 1_024 * 1_024,
    );
    let byteCount = 0;
    for (const session of catalog.sessions) {
      byteCount += Buffer.byteLength(JSON.stringify(session));
      if (byteCount > maxBytes) {
        throw new GatewayError("busy", "The session catalog is too large for one bounded traversal", true);
      }
    }
    const sessions = Object.freeze(catalog.sessions.map((session) => Object.freeze({ ...session })));
    const page = sessions.slice(0, limit);
    if (page.length >= sessions.length) {
      return { sessions: page, listRevision: catalog.listRevision };
    }

    this.evictForCapacity(clientID, sessions.length, byteCount);
    const now = this.now();
    let id: string;
    do { id = randomBytes(6).toString("hex"); } while (this.leases.has(id));
    const lease: SessionListLease = {
      id,
      clientID,
      scope,
      sessions,
      listRevision: catalog.listRevision,
      byteCount,
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
    if (parsed.signature !== expected || parsed.offset <= 0 || parsed.offset >= lease!.sessions.length) {
      this.invalidCursor();
    }

    lease!.lastAccess = this.now();
    const sessions = lease!.sessions.slice(parsed.offset, parsed.offset + limit);
    const nextOffset = parsed.offset + sessions.length;
    if (nextOffset >= lease!.sessions.length) this.leases.delete(lease!.id);
    return {
      sessions,
      listRevision: lease!.listRevision,
      ...(nextOffset < lease!.sessions.length ? { nextCursor: this.cursor(lease!, nextOffset) } : {}),
    };
  }

  private cursor(lease: SessionListLease, offset: number): string {
    return `${lease.id}.${offset.toString(36)}.${this.signature(lease, offset)}`;
  }

  private signature(lease: SessionListLease, offset: number): string {
    return createHmac("sha256", this.secret)
      .update(`${lease.id}\0${lease.clientID}\0${lease.scope}\0${lease.listRevision}\0${offset}`)
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
  }

  private evictForCapacity(clientID: string, incomingSessionCount: number, incomingBytes: number): void {
    const maxLeases = this.options.maxLeases ?? 16;
    const maxLeasesPerClient = this.options.maxLeasesPerClient ?? 2;
    const maxTotalSessions = this.options.maxTotalSessions ?? 50_000;
    const maxTotalBytes = this.options.maxTotalBytes ?? 8 * 1_024 * 1_024;
    let retainedSessions = [...this.leases.values()]
      .reduce((total, lease) => total + lease.sessions.length, 0);
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
      retainedSessions -= oldest.sessions.length;
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
