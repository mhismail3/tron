import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { GatewayError } from "../errors.js";
import { observeBrowserCDP, type CapturedBrowserFrame } from "./browser-live-cdp.js";

export function browserCDPEndpoint(value: string): URL {
  let endpoint: URL;
  try {
    if (value.length > 512) throw new Error("too long");
    endpoint = new URL(value);
  } catch { throw new GatewayError("invalid_request", "Browser CDP endpoint is invalid"); }
  if (endpoint.href !== value || endpoint.protocol !== "ws:" || endpoint.username || endpoint.password || endpoint.search || endpoint.hash
    || !["127.0.0.1", "[::1]"].includes(endpoint.hostname) || !endpoint.port
    || !/^\/devtools\/browser\/[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(endpoint.pathname)) {
    throw new GatewayError("invalid_request", "Browser CDP endpoint must be an exact loopback browser UUID without credentials");
  }
  return endpoint;
}

export const BROWSER_LIVE_VIEW_SCHEMA = "tron.browser-live-view.v1" as const;
export const BROWSER_LIVE_VIEW_CAPABILITY = "browser-live-view.v1" as const;
export const BROWSER_LIVE_VIEW_MAXIMUM_VIEWERS = 4;
export const BROWSER_LIVE_VIEW_MAXIMUM_TOTAL_VIEWERS = 16;
export const BROWSER_LIVE_VIEW_MAXIMUM_REGISTRATIONS = 64;
export const BROWSER_LIVE_VIEW_LEASE_IDLE_MS = 15_000;

export interface BrowserLiveViewFrame extends CapturedBrowserFrame { sequence: number }
export interface BrowserLiveViewDescriptor {
  schema: typeof BROWSER_LIVE_VIEW_SCHEMA;
  viewId: string;
  generation: string;
  title: string;
  fallbackText: string;
}
export interface BrowserLiveViewRegistration {
  sessionId: string;
  viewId: string;
  generation: string;
  title?: string;
  fallbackText?: string;
  /** The concrete extension load, not the longer-lived RuntimeSlot identity. */
  loadToken: string;
  cdpUrl: string;
}
interface Viewer { leaseId: string; viewerId: string; lastSeenAt: number; delivery?: { cancel: () => void } }
interface View {
  registration: BrowserLiveViewRegistration;
  viewers: Map<string, Viewer>;
  latest: BrowserLiveViewFrame | undefined;
  observer: ReturnType<typeof observeBrowserCDP> | undefined;
  epoch: number;
  sequence: number;
}
export type BrowserLiveViewFrameResult = BrowserLiveViewFrame | { status: "waiting" | "unchanged" };
type ViewIdentity = { sessionId: string; viewId: string; generation: string };
function key(sessionId: string, viewId: string): string { return `${sessionId}\0${viewId}`; }
const MAXIMUM_OBSERVED_GENERATIONS = 4_096;
function generationKey(sessionId: string, generation: string, cdpUrl: string): string {
  return `${sessionId}\0${generation}\0${cdpUrl}`;
}
function bounded(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximum
    && !/[\u0000-\u001f\u007f]/.test(value);
}

/** Disposable observer ownership only. The provider remains the sole browser
 * authority. No registration launches, reconnects, journals or caches frames. */
export class BrowserLiveViewRegistry {
  private readonly views = new Map<string, View>();
  private readonly leases = new Map<string, View>();
  // Admission reserves a retirement receipt. Never forget a closed generation
  // merely to admit another: late producer results must not resurrect it.
  private readonly observedGenerations = new Map<string, BrowserLiveViewDescriptor>();
  private readonly activeLoadTokens = new Map<string, string>();
  private expiryTimer: NodeJS.Timeout | undefined;

  constructor(private readonly connect: (endpoint: string, maximumPayload: number) => WebSocket =
    (endpoint, maximumPayload) => new WebSocket(endpoint, { maxPayload: maximumPayload })) {}

  beginSessionLoad(sessionId: string): string {
    this.retireSession(sessionId);
    const token = randomUUID();
    this.activeLoadTokens.set(sessionId, token);
    return token;
  }
  isLoadActive(sessionId: string, loadToken: string): boolean {
    return this.activeLoadTokens.get(sessionId) === loadToken;
  }
  register(registration: BrowserLiveViewRegistration): BrowserLiveViewDescriptor {
    this.assertRegistration(registration);
    if (!this.isLoadActive(registration.sessionId, registration.loadToken)) {
      throw new GatewayError("conflict", "Browser extension load is no longer active");
    }
    // Public explicit-get and native-bound actions can name their scope
    // differently. Exact endpoint/generation owns the viewer, not that alias.
    for (const view of this.views.values()) {
      const old = view.registration;
      if (old.sessionId === registration.sessionId && old.generation === registration.generation
        && old.cdpUrl === registration.cdpUrl) return this.descriptor(view.registration);
    }
    const observed = generationKey(registration.sessionId, registration.generation, registration.cdpUrl);
    if (this.observedGenerations.has(observed)) throw new GatewayError("conflict", "This browser generation has ended");
    if (this.observedGenerations.size >= MAXIMUM_OBSERVED_GENERATIONS) {
      throw new GatewayError("busy", "The Gateway has reached its browser generation capacity", true);
    }
    const identity = key(registration.sessionId, registration.viewId);
    const existing = this.views.get(identity);
    if (!existing && this.views.size >= BROWSER_LIVE_VIEW_MAXIMUM_REGISTRATIONS) {
      throw new GatewayError("busy", "The Gateway has reached its browser view capacity", true);
    }
    if (existing) this.retire(existing);
    const descriptor = this.descriptor(registration);
    this.observedGenerations.set(observed, descriptor);
    const view: View = { registration: { ...registration }, viewers: new Map(), latest: undefined, observer: undefined, epoch: 0, sequence: 0 };
    this.views.set(identity, view);
    return { ...descriptor };
  }
  describe(sessionId: string, viewId: string, generation: string): BrowserLiveViewDescriptor {
    return this.descriptor(this.requireView(sessionId, viewId, generation).registration);
  }
  /** Synchronous admission lets the transport couple auth/branch fences and
   * lease creation without a revocation window across an await. */
  open(sessionId: string, viewId: string, generation: string, viewerId: string): { leaseId: string; descriptor: BrowserLiveViewDescriptor } {
    if (!bounded(viewerId, 256)) throw new GatewayError("invalid_request", "Live view viewer identity is invalid");
    this.expire();
    const view = this.requireView(sessionId, viewId, generation);
    if (view.viewers.size >= BROWSER_LIVE_VIEW_MAXIMUM_VIEWERS || this.leases.size >= BROWSER_LIVE_VIEW_MAXIMUM_TOTAL_VIEWERS) {
      throw new GatewayError("busy", "This browser view has reached its viewer capacity", true);
    }
    const leaseId = randomUUID();
    view.viewers.set(leaseId, { leaseId, viewerId, lastSeenAt: Date.now() });
    this.leases.set(leaseId, view);
    try {
      if (view.viewers.size === 1) this.start(view);
      if (!this.expiryTimer) {
        this.expiryTimer = setInterval(() => this.expire(), 1_000);
        this.expiryTimer.unref();
      }
    } catch {
      this.close(leaseId);
      throw new GatewayError("busy", "The browser observer could not connect", true);
    }
    return { leaseId, descriptor: this.descriptor(view.registration) };
  }
  /** A viewer owns at most one unfinished response, including backpressure.
   * Retirement cancels that write; completed reads release without closing it. */
  acquireFrame(sessionId: string, viewId: string, generation: string, leaseId: string, viewerId: string, cancel: () => void, after = 0): { frame: BrowserLiveViewFrameResult; release: () => void } {
    if (!Number.isSafeInteger(after) || after < 0) throw new GatewayError("invalid_request", "Frame sequence is invalid");
    const view = this.requireView(sessionId, viewId, generation);
    const viewer = view.viewers.get(leaseId);
    if (!viewer || this.leases.get(leaseId) !== view || viewer.viewerId !== viewerId) {
      throw new GatewayError("not_found", "Browser viewing has ended");
    }
    if (Date.now() - viewer.lastSeenAt >= BROWSER_LIVE_VIEW_LEASE_IDLE_MS) {
      this.close(leaseId);
      throw new GatewayError("not_found", "Browser viewing has ended");
    }
    if (viewer.delivery) throw new GatewayError("busy", "This viewer already has an outstanding frame response", true);
    viewer.lastSeenAt = Date.now();
    const delivery = { cancel };
    viewer.delivery = delivery;
    return {
      frame: !view.latest ? { status: "waiting" } : view.latest.sequence <= after ? { status: "unchanged" } : view.latest,
      release: () => { if (viewer.delivery === delivery) delete viewer.delivery; },
    };
  }
  close(leaseId: string, viewerId?: string, expected?: ViewIdentity): boolean {
    const view = this.leases.get(leaseId);
    const viewer = view?.viewers.get(leaseId);
    if (!view || !viewer || (viewerId !== undefined && viewer.viewerId !== viewerId)) return false;
    const registration = view.registration;
    if (expected && (registration.sessionId !== expected.sessionId || registration.viewId !== expected.viewId
      || registration.generation !== expected.generation)) return false;
    this.leases.delete(leaseId);
    view.viewers.delete(leaseId);
    const delivery = viewer.delivery;
    delete viewer.delivery;
    // A failed transport cancellation must not retain other viewers or capture.
    try { delivery?.cancel(); } catch { /* the lease has already been fenced */ }
    if (view.viewers.size === 0) this.stop(view);
    if (this.leases.size === 0 && this.expiryTimer) {
      clearInterval(this.expiryTimer);
      this.expiryTimer = undefined;
    }
    return true;
  }
  closeViewerIdentity(viewerId: string): void {
    for (const [leaseId, view] of this.leases) {
      if (view.viewers.get(leaseId)?.viewerId === viewerId) this.close(leaseId);
    }
  }
  retireSession(sessionId: string): void {
    this.activeLoadTokens.delete(sessionId);
    for (const observed of this.observedGenerations.keys()) if (observed.startsWith(`${sessionId}\0`)) this.observedGenerations.delete(observed);
    for (const view of this.views.values()) if (view.registration.sessionId === sessionId) this.retire(view);
  }
  retireView(sessionId: string, viewId: string, generation?: string): void {
    const view = this.views.get(key(sessionId, viewId));
    if (view && (generation === undefined || view.registration.generation === generation)) this.retire(view);
  }
  retireBrowser(registration: BrowserLiveViewRegistration): BrowserLiveViewDescriptor {
    this.assertRegistration(registration);
    const { sessionId, cdpUrl, generation, loadToken } = registration;
    if (!this.isLoadActive(sessionId, loadToken)) {
      throw new GatewayError("conflict", "Browser extension load is no longer active");
    }
    const observed = generationKey(sessionId, generation, cdpUrl);
    const known = this.observedGenerations.get(observed);
    if (!known && this.observedGenerations.size >= MAXIMUM_OBSERVED_GENERATIONS) {
      throw new GatewayError("busy", "The Gateway has reached its browser generation capacity", true);
    }
    // Keep the same bounded receipt after retirement, including close-first
    // observations. Repeated closed aliases must not invent another window.
    const descriptor = known ?? this.descriptor(registration);
    this.observedGenerations.set(observed, descriptor);
    for (const view of this.views.values()) {
      if (view.registration.sessionId === sessionId && view.registration.cdpUrl === cdpUrl
        && view.registration.generation === generation) this.retire(view);
    }
    return { ...descriptor };
  }
  dispose(): void {
    for (const view of this.views.values()) this.retire(view);
    this.activeLoadTokens.clear();
    this.observedGenerations.clear();
  }
  private expire(): void {
    const now = Date.now();
    for (const [leaseId, view] of this.leases) {
      const viewer = view.viewers.get(leaseId);
      if (viewer && now - viewer.lastSeenAt >= BROWSER_LIVE_VIEW_LEASE_IDLE_MS) this.close(leaseId);
    }
  }
  private requireView(sessionId: string, viewId: string, generation: string): View {
    const view = this.views.get(key(sessionId, viewId));
    if (!view || view.registration.generation !== generation) throw new GatewayError("not_found", "Browser view is no longer available");
    return view;
  }
  private descriptor(registration: BrowserLiveViewRegistration): BrowserLiveViewDescriptor {
    return { schema: BROWSER_LIVE_VIEW_SCHEMA, viewId: registration.viewId, generation: registration.generation,
      title: registration.title ?? "Browser view", fallbackText: registration.fallbackText ?? "The browser view is unavailable." };
  }
  private assertRegistration(registration: BrowserLiveViewRegistration): void {
    if (!bounded(registration.sessionId, 200) || !bounded(registration.viewId, 200) || !bounded(registration.generation, 200)
      || !bounded(registration.loadToken, 200)
      || (registration.title !== undefined && !bounded(registration.title, 256))
      || (registration.fallbackText !== undefined && !bounded(registration.fallbackText, 4_096))) {
      throw new GatewayError("invalid_request", "Browser view metadata is invalid");
    }
    browserCDPEndpoint(registration.cdpUrl);
  }
  private start(view: View): void {
    const epoch = ++view.epoch;
    const current = (): boolean => view.epoch === epoch && this.views.get(key(view.registration.sessionId, view.registration.viewId)) === view;
    const observer = observeBrowserCDP({
      endpoint: view.registration.cdpUrl, connect: this.connect,
      onFrame: (frame) => { if (current()) view.latest = { ...frame, sequence: ++view.sequence }; },
      onReset: () => { if (current()) view.latest = undefined; },
    });
    view.observer = observer;
    void observer.done.then(() => {
      if (!current()) return;
      // An observer failure is terminal for every attached viewer, not a
      // renewable waiting state. The descriptor may still reopen this UUID.
      for (const leaseId of view.viewers.keys()) this.close(leaseId);
    });
  }
  private stop(view: View): void {
    view.epoch++;
    view.observer?.stop();
    view.observer = undefined;
    view.latest = undefined;
  }
  private retire(view: View): void {
    for (const leaseId of view.viewers.keys()) this.close(leaseId);
    this.stop(view);
    this.views.delete(key(view.registration.sessionId, view.registration.viewId));
  }
}
