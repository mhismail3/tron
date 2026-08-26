import { randomUUID } from "node:crypto";
import { watch, type FSWatcher } from "node:fs";
import type { JsonValue, ProcessTranscriptLease } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";

const MAX_LEASES_PER_CLIENT = 8;
const MAX_LEASES_PER_CLIENT_SESSION = 2;
const LEASE_TIMEOUT_MS = 30 * 60_000;
const INVALIDATION_DEBOUNCE_MS = 150;

type Lease = {
  id: string;
  clientId: string;
  parentSessionId: string;
  processId: string;
  childSessionRef: string;
  runId: string;
  path: string;
  revision: string;
  watcher: FSWatcher;
  invalidationTimer: NodeJS.Timeout | undefined;
  timeout: NodeJS.Timeout;
  notify: (topic: string, sessionId: string, payload: JsonValue) => void;
};

/** Connection-owned, disposable observer of a validated canonical child file.
 * It stores no transcript mirror and never acquires a child runtime. */
export class ProcessTranscriptLeaseStore {
  private readonly leases = new Map<string, Lease>();

  constructor(private readonly sessions: RuntimeRegistry) {}

  async open(
    clientId: string,
    parentSessionId: string,
    processId: string,
    childSessionRef: string,
    runId: string,
    preferredPath: string | undefined,
    notify: (topic: string, sessionId: string, payload: JsonValue) => void,
  ): Promise<ProcessTranscriptLease> {
    const clientLeases = [...this.leases.values()].filter((lease) => lease.clientId === clientId);
    if (clientLeases.length >= MAX_LEASES_PER_CLIENT
      || clientLeases.filter((lease) => lease.parentSessionId === parentSessionId).length >= MAX_LEASES_PER_CLIENT_SESSION) {
      throw new GatewayError("busy", "Read-only subagent viewer capacity is full", true);
    }
    const path = await this.sessions.resolveReadOnlySubagentPath(childSessionRef, preferredPath, parentSessionId, runId);
    const page = await this.sessions.readOnlySubagentTranscriptPage(childSessionRef, path);
    const id = randomUUID();
    let watcher: FSWatcher;
    try {
      watcher = watch(path, { persistent: false }, () => this.scheduleInvalidation(id));
    } catch {
      throw new GatewayError("conflict", "Subagent session cannot be observed", true);
    }
    const timeout = setTimeout(() => this.closeOwned(clientId, id), LEASE_TIMEOUT_MS);
    timeout.unref();
    const lease: Lease = {
      id,
      clientId,
      parentSessionId,
      processId,
      childSessionRef,
      runId,
      path,
      revision: page.revision,
      watcher,
      invalidationTimer: undefined,
      timeout,
      notify,
    };
    watcher.on("error", () => this.closeOwned(clientId, id, "observer closed"));
    this.leases.set(id, lease);
    return {
      leaseId: id,
      processId,
      childSessionRef,
      revision: page.revision,
      page: {
        items: page.items,
        start: page.start,
        end: page.end,
        total: page.total,
        ...(page.nextEntryId ? { nextEntryId: page.nextEntryId } : {}),
        ...(page.leafEntryId ? { leafEntryId: page.leafEntryId } : {}),
      },
    };
  }

  async page(
    clientId: string,
    leaseId: string,
    before?: number,
    expectedNextEntryId?: string,
    expectedRevision?: string,
  ): Promise<ProcessTranscriptLease["page"] & { revision: string }> {
    const lease = this.owned(clientId, leaseId);
    if (expectedRevision !== undefined && expectedRevision !== lease.revision) {
      throw new GatewayError("conflict", "Subagent transcript changed; refresh the viewer", true);
    }
    const page = await this.sessions.readOnlySubagentTranscriptPage(
      lease.childSessionRef,
      lease.path,
      before,
      expectedNextEntryId,
    );
    lease.revision = page.revision;
    return {
      items: page.items,
      start: page.start,
      end: page.end,
      total: page.total,
      ...(page.nextEntryId ? { nextEntryId: page.nextEntryId } : {}),
      ...(page.leafEntryId ? { leafEntryId: page.leafEntryId } : {}),
      revision: page.revision,
    };
  }

  closeOwned(clientId: string, leaseId: string, reason?: string): boolean {
    const lease = this.leases.get(leaseId);
    if (!lease || lease.clientId !== clientId) return false;
    this.leases.delete(leaseId);
    if (lease.invalidationTimer) clearTimeout(lease.invalidationTimer);
    clearTimeout(lease.timeout);
    lease.watcher.close();
    if (reason) lease.notify("session.processTranscript.changed", lease.parentSessionId, {
      leaseId,
      processId: lease.processId,
      closed: true,
      reason,
    });
    return true;
  }

  releaseClient(clientId: string): void {
    for (const lease of [...this.leases.values()]) {
      if (lease.clientId === clientId) this.closeOwned(clientId, lease.id);
    }
  }

  releaseParent(clientId: string, parentSessionId: string): void {
    for (const lease of [...this.leases.values()]) {
      if (lease.clientId === clientId && lease.parentSessionId === parentSessionId) {
        this.closeOwned(clientId, lease.id);
      }
    }
  }

  releaseSession(parentSessionId: string): void {
    for (const lease of [...this.leases.values()]) {
      if (lease.parentSessionId === parentSessionId) this.closeOwned(lease.clientId, lease.id);
    }
  }

  private owned(clientId: string, leaseId: string): Lease {
    const lease = this.leases.get(leaseId);
    if (!lease || lease.clientId !== clientId) throw new GatewayError("not_found", "Subagent transcript lease is unavailable");
    return lease;
  }

  private scheduleInvalidation(leaseId: string): void {
    const lease = this.leases.get(leaseId);
    if (!lease || lease.invalidationTimer) return;
    lease.invalidationTimer = setTimeout(() => {
      lease.invalidationTimer = undefined;
      void this.invalidate(leaseId);
    }, INVALIDATION_DEBOUNCE_MS);
    lease.invalidationTimer.unref();
  }

  private async invalidate(leaseId: string): Promise<void> {
    const lease = this.leases.get(leaseId);
    if (!lease) return;
    try {
      const page = await this.sessions.readOnlySubagentTranscriptPage(lease.childSessionRef, lease.path);
      if (page.revision === lease.revision) return;
      lease.revision = page.revision;
      lease.notify("session.processTranscript.changed", lease.parentSessionId, {
        leaseId: lease.id,
        processId: lease.processId,
        revision: page.revision,
        total: page.total,
        ...(page.leafEntryId ? { leafEntryId: page.leafEntryId } : {}),
      });
    } catch (error) {
      if (error instanceof GatewayError && error.code === "busy" && error.retryable) {
        this.scheduleInvalidation(leaseId);
        return;
      }
      this.closeOwned(lease.clientId, lease.id, "session unavailable");
    }
  }
}
