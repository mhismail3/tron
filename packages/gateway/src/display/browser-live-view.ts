import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";
import { GatewayError } from "../errors.js";
import { observeBrowserCDP, type CapturedBrowserFrame } from "./browser-live-cdp.js";
import { NATIVE_LIVE_VIEW_SCHEMA, nativeLiveClientFactory, nativeLiveFailure, observeNativeWindow, type NativeLiveFailure, type NativeLiveClient, type NativeLiveClientFactory } from "./native-live-view.js";
import { captureRegion, type NativeCaptureRegion, type NativeCaptureSource } from "../machine/native-capture-client.js";

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
const BROWSER_LIVE_VIEW_MAXIMUM_VIEWERS = 4;
const BROWSER_LIVE_VIEW_MAXIMUM_TOTAL_VIEWERS = 16;
const BROWSER_LIVE_VIEW_MAXIMUM_REGISTRATIONS = 64;
const BROWSER_LIVE_VIEW_LEASE_IDLE_MS = 15_000;

interface BrowserLiveViewFrame extends CapturedBrowserFrame { sequence: number }
export interface BrowserLiveViewDescriptor {
  schema: typeof BROWSER_LIVE_VIEW_SCHEMA;
  viewId: string;
  generation: string;
  title: string;
  fallbackText: string;
}
interface NativeLiveViewDescriptor extends Omit<BrowserLiveViewDescriptor, "schema"> {
  schema: typeof NATIVE_LIVE_VIEW_SCHEMA;
}
export type LiveViewDescriptor = BrowserLiveViewDescriptor | NativeLiveViewDescriptor;
interface NativeCatalog {
  loadToken: string;
  client: Promise<NativeLiveClient>;
  sources: Promise<readonly NativeCaptureSource[]>;
  close: () => Promise<void>;
}
interface NativeLiveViewRegistration extends Omit<BrowserLiveViewRegistration, "cdpUrl"> {
  native: NativeCatalog;
  handle: string;
  region: NativeCaptureRegion | undefined;
}
type Registration = BrowserLiveViewRegistration | NativeLiveViewRegistration;
interface BrowserLiveViewRegistration {
  sessionId: string;
  viewId: string;
  generation: string;
  title?: string;
  fallbackText?: string;
  /** The concrete extension load, not the longer-lived RuntimeSlot identity. */
  loadToken: string;
  cdpUrl: string;
}
// Demand/diagnostic lifetimes use monotonic time; wall-clock correction must
// not extend an abandoned viewer or manufacture expiry during a live read.
interface Viewer { leaseId: string; viewerId: string; lastSeenAt: number; delivery?: { cancel: () => void } }
interface View {
  registration: Registration;
  viewers: Map<string, Viewer>;
  latest: BrowserLiveViewFrame | undefined;
  observer: ReturnType<typeof observeBrowserCDP> | undefined;
  epoch: number;
  sequence: number;
  firstFrameDeadline?: number;
}
type BrowserLiveViewFrameResult = BrowserLiveViewFrame | { status: "waiting" | "unchanged" };
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

/** Shared disposable viewer ownership. The browser provider owns automation;
 * the Native Host owns selected windows and native stream retirement. Registering
 * a view starts neither producer. Pixels are latest-only and never journaled. */
export class BrowserLiveViewRegistry {
  private readonly views = new Map<string, View>();
  // Start can fail after POST admission succeeded. Keep only a bounded reason
  // for the exact ended reference so the next frame GET can explain it.
  private readonly nativeFailures = new Map<string, { generation: string; reason: NativeLiveFailure; expiresAt: number }>();
  private readonly leases = new Map<string, View>();
  // Admission reserves a retirement receipt. Never forget a closed generation
  // merely to admit another: late producer results must not resurrect it.
  private readonly observedGenerations = new Map<string, BrowserLiveViewDescriptor>();
  private readonly activeLoadTokens = new Map<string, string>();
  private expiryTimer: NodeJS.Timeout | undefined;
  private readonly nativeCatalogs = new Map<string, NativeCatalog>();
  private readonly nativeRetirements = new Set<Promise<void>>();

  constructor(private readonly connect: (endpoint: string, maximumPayload: number) => WebSocket =
    (endpoint, maximumPayload) => new WebSocket(endpoint, { maxPayload: maximumPayload }),
    private readonly nativeFactory: NativeLiveClientFactory = nativeLiveClientFactory,
    private readonly nativeFailure: () => void = () => console.warn("Native view ended without a clean remote retirement")) {}

  async catalogNative(sessionId: string, signal?: AbortSignal): Promise<readonly NativeCaptureSource[]> {
    signal?.throwIfAborted();
    const loadToken = this.activeLoadTokens.get(sessionId);
    if (!loadToken) throw new GatewayError("conflict", "Native capture load is unavailable");
    const previous = this.nativeCatalogs.get(sessionId);
    if (previous) { this.nativeCatalogs.delete(sessionId); this.joinNative(previous.close()); }
    if (this.nativeCatalogs.size >= 4) throw new GatewayError("busy", "Native catalog capacity reached", true);
    // Repeated catalog reads replace only unused handles. Wait for their local
    // connection retirement before opening another of the four native clients.
    const client = Promise.resolve(previous?.close()).then(() => {
      if (this.nativeCatalogs.get(sessionId) !== entry || !this.isLoadActive(sessionId, loadToken)) {
        throw new GatewayError("conflict", "Native catalog load ended before opening");
      }
      return this.nativeFactory({ canonicalSessionID: sessionId, runtimeLoadID: loadToken });
    });
    let closing: Promise<void> | undefined;
    const entry: NativeCatalog = { loadToken, client, sources: client.then((value) => value.catalog()),
      close: () => closing ??= client.then(async (value) => {
        const result = await value.close();
        if (result.diagnostic) throw new Error("Native capture joined with a retirement diagnostic");
      }, () => { /* Failed open already joined its local transport cleanup. */ }) };
    this.nativeCatalogs.set(sessionId, entry);
    const cancel = (): void => {
      if (this.nativeCatalogs.get(sessionId) === entry) this.nativeCatalogs.delete(sessionId);
      this.joinNative(entry.close());
    };
    signal?.addEventListener("abort", cancel, { once: true });
    try {
      const sources = await entry.sources;
      if (this.nativeCatalogs.get(sessionId) !== entry || !this.isLoadActive(sessionId, loadToken)) {
        throw new GatewayError("conflict", "Native catalog load ended");
      }
      return sources;
    } catch (error) {
      if (this.nativeCatalogs.get(sessionId) === entry) this.nativeCatalogs.delete(sessionId);
      this.joinNative(entry.close());
      throw error;
    } finally { signal?.removeEventListener("abort", cancel); }
  }
  async registerNative(sessionId: string, handle: string, region?: NativeCaptureRegion): Promise<NativeLiveViewDescriptor> {
    region = region === undefined ? undefined : captureRegion(region);
    const entry = this.nativeCatalogs.get(sessionId);
    if (!entry) throw new GatewayError("not_found", "List native windows before selecting one");
    const source = (await entry.sources).find((value) => value.handle === handle);
    const current = (): boolean => this.nativeCatalogs.get(sessionId) === entry && this.isLoadActive(sessionId, entry.loadToken);
    if (!source || !current()) throw new GatewayError("not_found", "Native source handle is unavailable");
    if (region && (source.kind !== "display" || region.x > source.width || region.y > source.height
      || region.width > source.width - region.x || region.height > source.height - region.y)) throw new GatewayError("invalid_request", "Region must stay inside its selected display");
    // Selecting a new source replaces only this session's native view, never
    // another session's stream or a browser provider's execution.
    const prior: Promise<void>[] = [];
    for (const view of this.views.values()) if (view.registration.sessionId === sessionId && "native" in view.registration) {
      prior.push(view.registration.native.close());
      if (view.observer) prior.push(view.observer.done);
      this.retire(view);
    }
    await Promise.all(prior);
    if (!current()) throw new GatewayError("conflict", "Native capture load ended");
    if (this.views.size >= BROWSER_LIVE_VIEW_MAXIMUM_REGISTRATIONS) throw new GatewayError("busy", "Live view capacity reached", true);
    const registration: NativeLiveViewRegistration = { sessionId, loadToken: entry.loadToken,
      viewId: randomUUID(), generation: randomUUID(), title: `${(source.title || source.applicationName).replace(/[\u0000-\u001f\u007f]/g, " ").trim() || "Mac view"}${region ? " (area)" : ""}`.slice(0, 256),
      handle, region, native: entry };
    this.nativeCatalogs.delete(sessionId); // The view now owns the exact retained target.
    this.views.set(key(sessionId, registration.viewId), { registration, viewers: new Map(), latest: undefined,
      observer: undefined, epoch: 0, sequence: 0 });
    return this.descriptor(registration);
  }
  async stopNative(sessionId: string): Promise<void> {
    for (const id of this.nativeFailures.keys()) if (id.startsWith(key(sessionId, ""))) this.nativeFailures.delete(id);
    const closing: Promise<void>[] = [];
    const catalog = this.nativeCatalogs.get(sessionId);
    if (catalog) { this.nativeCatalogs.delete(sessionId); closing.push(catalog.close()); this.joinNative(catalog.close()); }
    for (const view of this.views.values()) if (view.registration.sessionId === sessionId && "native" in view.registration) {
      closing.push(view.registration.native.close());
      if (view.observer) closing.push(view.observer.done);
      this.retire(view);
    }
    await Promise.all(closing);
  }
  private joinNative(work: Promise<void>): void {
    if (this.nativeRetirements.has(work)) return;
    this.nativeRetirements.add(work);
    void work.then(() => this.nativeRetirements.delete(work), () => {
      this.nativeRetirements.delete(work); this.nativeFailure();
    });
  }
  /** Local requests remain owned until they settle. A failed remote Stop is
   * reported, not turned into proof that the Host released its resources. */
  async joinRetirements(): Promise<void> { await Promise.allSettled([...this.nativeRetirements]); }

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
      if ("cdpUrl" in old && old.sessionId === registration.sessionId && old.generation === registration.generation
        && old.cdpUrl === registration.cdpUrl) return this.descriptor(old);
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
    if (existing && "native" in existing.registration) throw new GatewayError("conflict", "A native view reference cannot become a browser reference");
    if (existing) this.retire(existing);
    const descriptor = this.descriptor(registration);
    this.observedGenerations.set(observed, descriptor);
    const view: View = { registration: { ...registration }, viewers: new Map(), latest: undefined, observer: undefined, epoch: 0, sequence: 0 };
    this.views.set(identity, view);
    return { ...descriptor };
  }
  describe(sessionId: string, viewId: string, generation: string): LiveViewDescriptor {
    return this.descriptor(this.requireView(sessionId, viewId, generation).registration);
  }
  /** Synchronous admission lets the transport couple auth/branch fences and
   * lease creation without a revocation window across an await. */
  open(sessionId: string, viewId: string, generation: string, viewerId: string): { leaseId: string; descriptor: LiveViewDescriptor } {
    if (!bounded(viewerId, 256)) throw new GatewayError("invalid_request", "Live view viewer identity is invalid");
    this.expire();
    const view = this.requireView(sessionId, viewId, generation);
    if (view.viewers.size >= BROWSER_LIVE_VIEW_MAXIMUM_VIEWERS || this.leases.size >= BROWSER_LIVE_VIEW_MAXIMUM_TOTAL_VIEWERS) {
      throw new GatewayError("busy", "This browser view has reached its viewer capacity", true);
    }
    const leaseId = randomUUID();
    view.viewers.set(leaseId, { leaseId, viewerId, lastSeenAt: performance.now() });
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
    if (performance.now() - viewer.lastSeenAt >= BROWSER_LIVE_VIEW_LEASE_IDLE_MS) {
      this.close(leaseId);
      throw new GatewayError("not_found", "Browser viewing has ended");
    }
    if (viewer.delivery) throw new GatewayError("busy", "This viewer already has an outstanding frame response", true);
    if (view.firstFrameDeadline !== undefined && performance.now() >= view.firstFrameDeadline && !view.latest) {
      this.failNativeView(view, "first_frame_timeout");
      throw new GatewayError("not_found", "Native capture produced no frame", false, { liveViewFailure: "first_frame_timeout" });
    }
    viewer.lastSeenAt = performance.now();
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
    for (const id of this.nativeFailures.keys()) if (id.startsWith(key(sessionId, ""))) this.nativeFailures.delete(id);
    const catalog = this.nativeCatalogs.get(sessionId);
    if (catalog) { this.nativeCatalogs.delete(sessionId); this.joinNative(catalog.close()); }
    for (const observed of this.observedGenerations.keys()) if (observed.startsWith(`${sessionId}\0`)) this.observedGenerations.delete(observed);
    for (const view of this.views.values()) if (view.registration.sessionId === sessionId) this.retire(view);
  }
  retireView(sessionId: string, viewId: string, generation?: string): void {
    const failure = this.nativeFailures.get(key(sessionId, viewId));
    if (failure && (generation === undefined || failure.generation === generation)) this.nativeFailures.delete(key(sessionId, viewId));
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
      if ("cdpUrl" in view.registration && view.registration.sessionId === sessionId && view.registration.cdpUrl === cdpUrl
        && view.registration.generation === generation) this.retire(view);
    }
    return { ...descriptor };
  }
  dispose(): void {
    for (const catalog of this.nativeCatalogs.values()) this.joinNative(catalog.close());
    this.nativeCatalogs.clear();
    for (const view of this.views.values()) this.retire(view);
    this.activeLoadTokens.clear();
    this.observedGenerations.clear();
    this.nativeFailures.clear();
  }
  private expire(): void {
    const now = performance.now();
    for (const [id, failure] of this.nativeFailures) if (failure.expiresAt <= now) this.nativeFailures.delete(id);
    for (const [leaseId, view] of this.leases) {
      const viewer = view.viewers.get(leaseId);
      if (viewer && now - viewer.lastSeenAt >= BROWSER_LIVE_VIEW_LEASE_IDLE_MS) this.close(leaseId);
    }
  }
  private requireView(sessionId: string, viewId: string, generation: string): View {
    const view = this.views.get(key(sessionId, viewId));
    if (!view || view.registration.generation !== generation) {
      const failure = this.nativeFailures.get(key(sessionId, viewId));
      if (failure?.generation === generation && failure.expiresAt > performance.now()) {
        throw new GatewayError("not_found", "Native live capture ended", false, { liveViewFailure: failure.reason });
      }
      throw new GatewayError("not_found", "Live view is no longer available");
    }
    return view;
  }
  private descriptor(registration: BrowserLiveViewRegistration): BrowserLiveViewDescriptor;
  private descriptor(registration: NativeLiveViewRegistration): NativeLiveViewDescriptor;
  private descriptor(registration: Registration): LiveViewDescriptor;
  private descriptor(registration: Registration): LiveViewDescriptor {
    const native = "native" in registration;
    return { schema: native ? NATIVE_LIVE_VIEW_SCHEMA : BROWSER_LIVE_VIEW_SCHEMA,
      viewId: registration.viewId, generation: registration.generation,
      title: registration.title ?? (native ? "Mac view" : "Browser view"),
      fallbackText: registration.fallbackText ?? (native ? "This Mac view has ended. Select the source again to view it." : "The browser view is unavailable.") };
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
    if ("native" in view.registration) {
      view.firstFrameDeadline = performance.now() + 10_000;
      const registration = view.registration;
      let nativeObserver: ReturnType<typeof observeNativeWindow> | undefined;
      const done = registration.native.client.then(async (client) => {
        if (!current()) return;
        nativeObserver = observeNativeWindow(client, registration.handle,
          (frame) => { if (current()) { view.latest = { ...frame, sequence: ++view.sequence }; delete view.firstFrameDeadline; } }, registration.region);
        await nativeObserver.done;
      });
      view.observer = { done, stop: () => nativeObserver?.stop() };
      void done.then(() => { if (current()) this.retire(view); }, (error: unknown) => {
        this.nativeFailure();
        if (current()) this.failNativeView(view, nativeLiveFailure(error));
      });
      return;
    }
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
  private failNativeView(view: View, reason: NativeLiveFailure): void {
    const registration = view.registration;
    while (this.nativeFailures.size >= BROWSER_LIVE_VIEW_MAXIMUM_REGISTRATIONS) this.nativeFailures.delete(this.nativeFailures.keys().next().value!);
    this.nativeFailures.set(key(registration.sessionId, registration.viewId), {
      generation: registration.generation, reason, expiresAt: performance.now() + 60_000,
    });
    // This requests Stop; neither the deadline nor the diagnostic proves join.
    this.retire(view);
  }
  private stop(view: View): void {
    view.epoch++;
    delete view.firstFrameDeadline;
    view.observer?.stop();
    if ("native" in view.registration && view.observer) {
      this.joinNative(view.observer.done);
      void view.observer.done.catch(() => {
        // An uncertain suspend cannot leave a resumable target, even if a new
        // viewer has already arrived while the old stream was joining.
        if (this.views.get(key(view.registration.sessionId, view.registration.viewId)) === view) this.retire(view);
      });
    }
    view.observer = undefined;
    view.latest = undefined;
  }
  private retire(view: View): void {
    for (const leaseId of view.viewers.keys()) this.close(leaseId);
    this.stop(view);
    this.views.delete(key(view.registration.sessionId, view.registration.viewId));
    if ("native" in view.registration) this.joinNative(view.registration.native.close());
  }
}
