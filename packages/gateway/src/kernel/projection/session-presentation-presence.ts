import { performance } from "node:perf_hooks";

const SESSION_PRESENTATION_LEASE_MS = 45_000;

export interface SessionPresentationPresenceProjection {
  visible: boolean;
  revision: number;
}

interface SessionPresentationPresenceLease {
  clientId: string;
  sessionId: string;
  subscriptionToken: string;
  revision: number;
  visible: boolean;
  expiresAt: number;
}

export class SessionPresentationPresenceRegistry {
  private readonly leasesByClient = new Map<string, SessionPresentationPresenceLease>();

  constructor(
    private readonly now: () => number = () => performance.now(),
    private readonly leaseMilliseconds = SESSION_PRESENTATION_LEASE_MS,
  ) {
    if (!Number.isFinite(leaseMilliseconds) || leaseMilliseconds <= 0) {
      throw new Error("Session presentation lease duration must be positive");
    }
  }

  set(input: {
    clientId: string;
    sessionId: string;
    subscriptionToken: string;
    revision: number;
    visible: boolean;
  }, onVisible?: () => void): SessionPresentationPresenceProjection {
    const current = this.leasesByClient.get(input.clientId);
    if (current
      && current.sessionId === input.sessionId
      && current.subscriptionToken === input.subscriptionToken
      && input.revision <= current.revision) {
      return { visible: this.isLeaseVisible(current), revision: current.revision };
    }

    const opened = input.visible && (!current
      || current.sessionId !== input.sessionId
      || current.subscriptionToken !== input.subscriptionToken
      || !this.isLeaseVisible(current));
    const lease: SessionPresentationPresenceLease = {
      ...input,
      expiresAt: input.visible ? this.now() + this.leaseMilliseconds : 0,
    };
    this.leasesByClient.set(input.clientId, lease);
    if (opened) onVisible?.();
    return { visible: input.visible, revision: input.revision };
  }

  isVisible(sessionId: string): boolean {
    let visible = false;
    for (const lease of this.leasesByClient.values()) {
      if (lease.sessionId !== sessionId || !lease.visible) continue;
      if (this.isLeaseVisible(lease)) visible = true;
      else lease.visible = false;
    }
    return visible;
  }

  remove(clientId: string, sessionId?: string): void {
    const current = this.leasesByClient.get(clientId);
    if (!current || sessionId !== undefined && current.sessionId !== sessionId) return;
    this.leasesByClient.delete(clientId);
  }

  removeSession(sessionId: string): void {
    for (const [clientId, lease] of this.leasesByClient) {
      if (lease.sessionId === sessionId) this.leasesByClient.delete(clientId);
    }
  }

  rekey(previousSessionId: string, nextSessionId: string): void {
    if (previousSessionId === nextSessionId) return;
    for (const lease of this.leasesByClient.values()) {
      if (lease.sessionId === previousSessionId) lease.sessionId = nextSessionId;
    }
  }

  private isLeaseVisible(lease: SessionPresentationPresenceLease): boolean {
    return lease.visible && lease.expiresAt > this.now();
  }
}
