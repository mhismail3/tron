import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { AutomationPage } from "./automation-service.js";
import type { AutomationSummary } from "./types.js";

const MAXIMUM_LEASES = 64;
const LEASE_TTL_MS = 60_000;

interface Lease {
  id: string;
  clientId: string;
  catalogRevision: number;
  items: AutomationSummary[];
  offset: number;
  expiresAt: number;
}

export class AutomationPaginationStore {
  private readonly leases = new Map<string, Lease>();

  constructor(private readonly now: () => number = Date.now) {}

  page(
    clientId: string,
    source: AutomationPage,
    cursor: string | undefined,
    limit: number,
  ): { catalogRevision: number; items: AutomationSummary[]; nextCursor?: string } {
    this.prune();
    let lease: Lease;
    if (cursor) {
      const existing = this.leases.get(cursor);
      if (!existing || existing.clientId !== clientId) {
        throw new GatewayError("conflict", "Automation page expired; reload from the first page", true);
      }
      if (existing.catalogRevision !== source.catalogRevision) {
        this.leases.delete(cursor);
        throw new GatewayError("conflict", "Automations changed while loading; reload from the first page", true);
      }
      this.leases.delete(cursor);
      lease = existing;
    } else {
      lease = {
        id: randomUUID(),
        clientId,
        catalogRevision: source.catalogRevision,
        items: structuredClone(source.items),
        offset: 0,
        expiresAt: this.now() + LEASE_TTL_MS,
      };
    }
    const items = lease.items.slice(lease.offset, lease.offset + limit);
    lease.offset += items.length;
    lease.expiresAt = this.now() + LEASE_TTL_MS;
    if (lease.offset >= lease.items.length) {
      return { catalogRevision: lease.catalogRevision, items };
    }
    if (this.leases.size >= MAXIMUM_LEASES) {
      const oldest = [...this.leases.values()].sort((left, right) => left.expiresAt - right.expiresAt)[0];
      if (oldest) this.leases.delete(oldest.id);
    }
    this.leases.set(lease.id, lease);
    return { catalogRevision: lease.catalogRevision, items, nextCursor: lease.id };
  }

  releaseClient(clientId: string): void {
    for (const [id, lease] of this.leases) if (lease.clientId === clientId) this.leases.delete(id);
  }

  private prune(): void {
    const now = this.now();
    for (const [id, lease] of this.leases) if (lease.expiresAt <= now) this.leases.delete(id);
  }
}
