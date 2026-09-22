import { watch, type FSWatcher } from "node:fs";
import type { JsonValue, ProcessTranscriptLease } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { AsyncMutex } from "../util/async-mutex.js";

const MAX_LEASES_PER_CLIENT = 8;
const MAX_LEASES_PER_CLIENT_SESSION = 2;
const LEASE_TIMEOUT_MS = 30 * 60_000;
const INVALIDATION_DEBOUNCE_MS = 150;

type Lease = {
  id: string;
  clientId: string;
  parentSessionId: string;
  parentSubscriptionToken?: string;
  processId: string;
  childSessionRef: string;
  runId: string;
  canAbort: boolean;
  expectedOperationId?: string;
  path: string;
  fileIdentity: string;
  /** Last revision acknowledged by a page response to this client. */
  revision: string;
  /** Newest invalidation announced but not yet acknowledged by a page read. */
  pendingRevision?: string;
  watcher: FSWatcher;
  invalidationTimer: NodeJS.Timeout | undefined;
  timeout: NodeJS.Timeout;
  notify: (topic: string, sessionId: string, payload: JsonValue) => void;
  pageMutex: AsyncMutex;
};

/** Connection-owned, disposable observer of a validated canonical child file.
 * It stores no transcript mirror. Its sole mutation revalidates the exact lease
 * binding before asking the already-owned parent runtime to stop that process. */
export class ProcessTranscriptLeaseStore {
  private readonly leases = new Map<string, Lease>();
  private readonly pendingOpens = new Map<string, { clientId: string; parentSessionId: string; parentSubscriptionToken: string; retired: boolean }>();
  private readonly openingByClient = new Map<string, number>();
  private readonly openingByClientSession = new Map<string, Map<string, number>>();

  constructor(private readonly sessions: RuntimeRegistry) {}

  reserveOpen(
    clientId: string,
    parentSessionId: string,
    viewerId: string,
    parentSubscriptionToken: string,
    signal?: AbortSignal,
  ): {
    open: (processId: string, childSessionRef: string, runId: string, preferredPath: string | undefined,
      notify: (topic: string, sessionId: string, payload: JsonValue) => void,
      abortAuthority?: { expectedOperationId?: string }) => Promise<ProcessTranscriptLease>;
    retire: () => void;
    release: () => void;
  } {
    if (viewerId.length === 0 || viewerId.length > 256 || parentSubscriptionToken.length === 0) {
      throw new GatewayError("invalid_request", "Invalid subagent viewer identity");
    }
    if (signal?.aborted) {
      throw new GatewayError("conflict", "Subagent viewer opening was retired", true);
    }
    if (this.pendingOpens.has(viewerId) || this.leases.has(viewerId)) {
      throw new GatewayError("conflict", "Subagent viewer identity is already in use", true);
    }
    const releaseOpening = this.reserveOpening(clientId, parentSessionId);
    const pending = { clientId, parentSessionId, parentSubscriptionToken, retired: false };
    this.pendingOpens.set(viewerId, pending);
    const retire = () => {
      pending.retired = true;
      if (this.pendingOpens.get(viewerId) === pending) this.closeOwned(clientId, viewerId, "viewer retired");
    };
    signal?.addEventListener("abort", retire, { once: true });
    let released = false;
    return {
      open: async (processId, childSessionRef, runId, preferredPath, notify, abortAuthority) =>
        this.openReserved(
          clientId, parentSessionId, processId, childSessionRef, runId,
          preferredPath, notify, abortAuthority, viewerId, parentSubscriptionToken, pending,
        ),
      retire,
      release: () => {
        if (released) return;
        released = true;
        signal?.removeEventListener("abort", retire);
        this.pendingOpens.delete(viewerId);
        releaseOpening();
      },
    };
  }

  async open(
    clientId: string,
    parentSessionId: string,
    processId: string,
    childSessionRef: string,
    runId: string,
    preferredPath: string | undefined,
    notify: (topic: string, sessionId: string, payload: JsonValue) => void,
    abortAuthority: { expectedOperationId?: string } | undefined,
    options: { viewerId: string; parentSubscriptionToken: string; signal?: AbortSignal },
  ): Promise<ProcessTranscriptLease> {
    const reservation = this.reserveOpen(
      clientId, parentSessionId, options.viewerId, options.parentSubscriptionToken, options.signal,
    );
    try {
      return await reservation.open(processId, childSessionRef, runId, preferredPath, notify, abortAuthority);
    } finally {
      reservation.release();
    }
  }

  private async openReserved(
    clientId: string,
    parentSessionId: string,
    processId: string,
    childSessionRef: string,
    runId: string,
    preferredPath: string | undefined,
    notify: (topic: string, sessionId: string, payload: JsonValue) => void,
    abortAuthority: { expectedOperationId?: string } | undefined,
    viewerId: string,
    parentSubscriptionToken: string,
    pending: { clientId: string; parentSessionId: string; parentSubscriptionToken: string; retired: boolean },
  ): Promise<ProcessTranscriptLease> {
    const ensureOpen = (): void => {
      if (pending.retired || this.pendingOpens.get(viewerId) !== pending) {
        throw new GatewayError("conflict", "Subagent viewer opening was retired", true);
      }
    };
    ensureOpen();
    const admission = await this.sessions.resolveReadOnlySubagentPath(
      childSessionRef, preferredPath, parentSessionId, processId, runId,
    );
    ensureOpen();
    const id = viewerId;
    let changedDuringOpen = false;
    let watcher: FSWatcher;
    try {
      // Install observation before the baseline read. Until the lease enters
      // the map, callbacks latch a dirty bit so an append in the open window
      // cannot disappear between baseline capture and ownership publication.
      watcher = watch(admission.path, { persistent: false }, () => {
        if (this.leases.get(id)?.watcher === watcher) this.scheduleInvalidation(id);
        else if (this.pendingOpens.get(id) === pending) changedDuringOpen = true;
      });
      // Install the error fence before the baseline read. A failed watcher
      // retires the pending owner instead of leaving an opening without an
      // observer or allowing a late response to publish it.
      watcher.on("error", () => {
        pending.retired = true;
        if (this.pendingOpens.get(id) === pending || this.leases.get(id)?.watcher === watcher) {
          this.closeOwned(clientId, id, "observer closed");
        }
      });
    } catch {
      throw new GatewayError("conflict", "Subagent session cannot be observed", true);
    }
    try {
      ensureOpen();
    } catch (error) {
      watcher.close();
      throw error;
    }
    let page: Awaited<ReturnType<RuntimeRegistry["readOnlySubagentTranscriptPage"]>>;
    try {
      page = await this.sessions.readOnlySubagentTranscriptPage(
        childSessionRef, admission.path, parentSessionId, processId, runId,
        undefined, undefined, admission.fileIdentity,
      );
    } catch (error) {
      watcher.close();
      throw error;
    }
    try {
      ensureOpen();
    } catch (error) {
      watcher.close();
      throw error;
    }
    const timeout = setTimeout(() => {
      if (this.leases.get(id) === lease) this.closeOwned(clientId, id, "viewer expired");
    }, LEASE_TIMEOUT_MS);
    timeout.unref();
    const lease: Lease = {
      id,
      clientId,
      parentSessionId,
      ...(parentSubscriptionToken === undefined ? {} : { parentSubscriptionToken }),
      processId,
      childSessionRef,
      runId,
      canAbort: abortAuthority !== undefined,
      ...(abortAuthority?.expectedOperationId
        ? { expectedOperationId: abortAuthority.expectedOperationId }
        : {}),
      path: admission.path,
      fileIdentity: page.fileIdentity,
      revision: page.revision,
      watcher,
      invalidationTimer: undefined,
      timeout,
      notify,
      pageMutex: new AsyncMutex(),
    };
    this.leases.set(id, lease);
    if (changedDuringOpen) this.scheduleInvalidation(id);
    return {
      leaseId: id,
      processId,
      childSessionRef,
      canAbort: abortAuthority !== undefined,
      revision: page.revision,
      page: {
        items: page.items,
        start: page.start,
        end: page.end,
        total: page.total,
        ...(page.nextEntryId ? { nextEntryId: page.nextEntryId } : {}),
        ...(page.leafEntryId ? { leafEntryId: page.leafEntryId } : {}),
        ...(page.forkBoundary ? { forkBoundary: page.forkBoundary } : {}),
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
    const admittedLease = this.owned(clientId, leaseId);
    return admittedLease.pageMutex.run(async () => {
      // Revalidate ownership and the expected generation inside the per-lease
      // lane. A canceled mobile request may still finish at the Gateway, so
      // concurrent prepend/refresh reads must not both advance one revision.
      const lease = this.owned(clientId, leaseId);
      if (lease !== admittedLease) throw new GatewayError("conflict", "Subagent transcript lease changed", true);
      if (expectedRevision !== undefined && expectedRevision !== lease.revision) {
        throw new GatewayError("conflict", "Subagent transcript changed; refresh the viewer", true);
      }
      // A watcher announces pendingRevision without advancing the client's
      // acknowledged revision. This lets the mounted read-only viewer refresh
      // the newest page on the same lease using the revision it actually owns.
      const pendingAtStart = lease.pendingRevision;
      let page: Awaited<ReturnType<RuntimeRegistry["readOnlySubagentTranscriptPage"]>>;
      try {
        page = await this.sessions.readOnlySubagentTranscriptPage(
          lease.childSessionRef,
          lease.path,
          lease.parentSessionId,
          lease.processId,
          lease.runId,
          before,
          expectedNextEntryId,
          lease.fileIdentity,
        );
      } catch (error) {
        if (!(error instanceof GatewayError && error.code === "busy" && error.retryable)) {
          this.closeOwned(clientId, leaseId, "session unavailable");
        }
        throw error;
      }
      if (this.leases.get(leaseId) !== admittedLease) {
        throw new GatewayError("not_found", "Subagent transcript lease is unavailable");
      }
      lease.revision = page.revision;
      if (lease.pendingRevision === pendingAtStart) delete lease.pendingRevision;
      return {
        items: page.items,
        start: page.start,
        end: page.end,
        total: page.total,
        ...(page.nextEntryId ? { nextEntryId: page.nextEntryId } : {}),
        ...(page.leafEntryId ? { leafEntryId: page.leafEntryId } : {}),
        ...(page.forkBoundary ? { forkBoundary: page.forkBoundary } : {}),
        revision: page.revision,
      };
    });
  }

  async abortOwned(clientId: string, leaseId: string): Promise<void> {
    const admittedLease = this.owned(clientId, leaseId);
    if (!admittedLease.canAbort) {
      throw new GatewayError("conflict", "This subagent transcript lease is not stoppable", true);
    }
    await admittedLease.pageMutex.run(async () => {
      const lease = this.owned(clientId, leaseId);
      if (lease !== admittedLease) {
        throw new GatewayError("conflict", "Subagent transcript lease changed", true);
      }
      const admission = await this.sessions.resolveReadOnlySubagentPath(
        lease.childSessionRef,
        lease.path,
        lease.parentSessionId,
        lease.processId,
        lease.runId,
      );
      if (this.owned(clientId, leaseId) !== admittedLease
        || admission.path !== lease.path
        || admission.fileIdentity !== lease.fileIdentity) {
        throw new GatewayError("conflict", "Subagent session ownership changed", true);
      }
      await (await this.sessions.acquire(lease.parentSessionId)).abortSubagentProcess(
        lease.processId,
        lease.runId,
        lease.expectedOperationId,
      );
    });
  }

  closeOwned(clientId: string, leaseId: string, reason?: string): boolean {
    const pending = this.pendingOpens.get(leaseId);
    const ownedPending = pending?.clientId === clientId;
    if (ownedPending) pending.retired = true;
    // Publication precedes reservation release. Retire both states during that
    // handoff, rather than returning early and leaving the published watcher live.
    const lease = this.leases.get(leaseId);
    if (!lease || lease.clientId !== clientId) return ownedPending;
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
    for (const pending of this.pendingOpens.values()) {
      if (pending.clientId === clientId) pending.retired = true;
    }
    for (const lease of [...this.leases.values()]) {
      if (lease.clientId === clientId) this.closeOwned(clientId, lease.id);
    }
  }

  releaseParent(clientId: string, parentSessionId: string, parentSubscriptionToken?: string): void {
    for (const pending of this.pendingOpens.values()) {
      if (pending.clientId === clientId && pending.parentSessionId === parentSessionId
        && (parentSubscriptionToken === undefined || pending.parentSubscriptionToken === parentSubscriptionToken)) pending.retired = true;
    }
    for (const lease of [...this.leases.values()]) {
      if (lease.clientId === clientId && lease.parentSessionId === parentSessionId
        && (parentSubscriptionToken === undefined || lease.parentSubscriptionToken === parentSubscriptionToken)) {
        this.closeOwned(clientId, lease.id);
      }
    }
  }

  releaseSession(parentSessionId: string): void {
    for (const pending of this.pendingOpens.values()) {
      if (pending.parentSessionId === parentSessionId) pending.retired = true;
    }
    for (const lease of [...this.leases.values()]) {
      if (lease.parentSessionId === parentSessionId) this.closeOwned(lease.clientId, lease.id);
    }
  }

  private reserveOpening(clientId: string, parentSessionId: string): () => void {
    let activeClient = 0;
    let activeSession = 0;
    for (const lease of this.leases.values()) {
      if (lease.clientId !== clientId) continue;
      activeClient += 1;
      if (lease.parentSessionId === parentSessionId) activeSession += 1;
    }
    const clientOpenings = this.openingByClient.get(clientId) ?? 0;
    const sessionOpenings = this.openingByClientSession.get(clientId)?.get(parentSessionId) ?? 0;
    if (activeClient + clientOpenings >= MAX_LEASES_PER_CLIENT
      || activeSession + sessionOpenings >= MAX_LEASES_PER_CLIENT_SESSION) {
      throw new GatewayError("busy", "Read-only subagent viewer capacity is full", true);
    }
    this.openingByClient.set(clientId, clientOpenings + 1);
    const sessions = this.openingByClientSession.get(clientId) ?? new Map<string, number>();
    sessions.set(parentSessionId, sessionOpenings + 1);
    this.openingByClientSession.set(clientId, sessions);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const remainingClient = (this.openingByClient.get(clientId) ?? 1) - 1;
      if (remainingClient > 0) this.openingByClient.set(clientId, remainingClient);
      else this.openingByClient.delete(clientId);
      const currentSessions = this.openingByClientSession.get(clientId);
      const remainingSession = (currentSessions?.get(parentSessionId) ?? 1) - 1;
      if (remainingSession > 0) currentSessions?.set(parentSessionId, remainingSession);
      else currentSessions?.delete(parentSessionId);
      if (currentSessions?.size === 0) this.openingByClientSession.delete(clientId);
    };
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
      if (this.leases.get(leaseId) === lease) void this.invalidate(leaseId);
    }, INVALIDATION_DEBOUNCE_MS);
    lease.invalidationTimer.unref();
  }

  private async invalidate(leaseId: string): Promise<void> {
    const admittedLease = this.leases.get(leaseId);
    if (!admittedLease) return;
    await admittedLease.pageMutex.run(async () => {
      const lease = this.leases.get(leaseId);
      if (lease !== admittedLease) return;
      try {
        const page = await this.sessions.readOnlySubagentTranscriptPage(
          lease.childSessionRef,
          lease.path,
          lease.parentSessionId,
          lease.processId,
          lease.runId,
          undefined,
          undefined,
          lease.fileIdentity,
        );
        if (this.leases.get(leaseId) !== admittedLease) return;
        if (page.revision === lease.revision || page.revision === lease.pendingRevision) return;
        lease.pendingRevision = page.revision;
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
    });
  }
}
