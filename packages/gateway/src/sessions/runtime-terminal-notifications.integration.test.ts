import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { once } from "node:events";
import WebSocket from "ws";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type FauxResponseStep } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { NotificationGrantStore } from "../notifications/grant-store.js";
import { NotificationService, type NotificationInboxItem } from "../notifications/notification-service.js";
import { PushRelayClient, relaySignature } from "../notifications/relay-client.js";
import { GatewayLogger } from "../transport/logger.js";
import { GatewayService } from "../transport/gateway-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayServer } from "../transport/server.js";
import { DeviceStore } from "../security/device-store.js";
import { ManagedSubagents } from "./managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, ensureDelegatedArtifactRoot, DELEGATED_PROVIDER_ROOT_ENV } from "./delegated-provider.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { HOME_SOFT_BYTES } from "../home/home-chapter-state.js";
import type { RuntimeSlot } from "./runtime-slot.js";
import { INVOCATION_RECEIPT_TYPE } from "./invocation-receipts.js";
import { waitFor } from "../../test-support/wait-for.js";

function barrier() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

describe("automatic terminal notifications with the pinned runtime", { concurrent: false }, () => {
  const cleanup: Array<() => Promise<void>> = [];
  const originalEnvironment = Object.fromEntries([
    "PI_CODING_AGENT_DIR", DELEGATED_PROVIDER_ROOT_ENV, "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "PI_SUBAGENT_CHILD",
  ].map((name) => [name, process.env[name]]));
  afterEach(async () => {
    for (const release of cleanup.splice(0).reverse()) await release();
    for (const [name, value] of Object.entries(originalEnvironment)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });

  async function fixture(responses: FauxResponseStep[], options: {
    retry?: { enabled: boolean; maxRetries: number; baseDelayMs: number };
    extension?: string;
    observed?: boolean;
    notifications?: NotificationService;
    managedSubagents?: (tronHome: string) => ManagedSubagents;
    model?: { provider: string; id: string };
    useAgentModels?: boolean;
    setup?: (input: { agentDir: string; cwd: string; trust: TrustService }) => Promise<void>;
  } = {}) {
    const root = await mkdtemp(join(tmpdir(), "tron-terminal-notification-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const tronHome = join(root, "tron");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    await ensureDelegatedArtifactRoot(delegatedArtifactRoot(tronHome));
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({
      retry: options.retry ?? { enabled: false },
      compaction: { enabled: false },
    }));
    const trust = new TrustService(agentDir);
    if (options.setup) await options.setup({ agentDir, cwd, trust });
    if (options.extension) {
      const dir = join(cwd, ".pi", "extensions");
      await mkdir(dir, { recursive: true });
      await writeFile(join(dir, "terminal-test.ts"), options.extension.replaceAll("__TRON_HOME__", JSON.stringify(tronHome)));
      await trust.set(cwd, true);
    }
    const managedSubagents = options.managedSubagents?.(tronHome);
    const runtime = await ModelRuntime.create({
      modelsPath: options.useAgentModels ? join(agentDir, "models.json") : null,
      refreshOnCreate: false,
    });
    const faux = fauxProvider({ provider: "tron-terminal-test", tokensPerSecond: 10_000 });
    faux.setResponses(responses);
    runtime.registerNativeProvider(faux.provider);
    let slot!: RuntimeSlot;
    const canonicalAtAdmission: any[][] = [];
    const persistedAtAdmission: Array<any[] | undefined> = [];
    const enqueue = vi.fn(async (_input: any) => {
      // Take the branch cut synchronously: an asynchronous file read alone could
      // see a receipt appended AFTER premature notification admission.
      canonicalAtAdmission.push([...(slot as unknown as { sessionManager: { getBranch(): any[] } }).sessionManager.getBranch()]);
      try {
        persistedAtAdmission.push((await readFile(slot.sessionFile!, "utf8")).trim().split("\n").map((line) => JSON.parse(line)));
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        // Pi buffers a new session until its first assistant. Keep this explicit
        // rather than claiming a no-model first invocation reached disk.
        persistedAtAdmission.push(undefined);
      }
      return "queued" as const;
    });
    const suppressAutomatic = vi.fn(async () => "suppressed" as const);
    const registry = new RuntimeRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000,
      delegatedArtifactRoot: delegatedArtifactRoot(tronHome),
      modelRuntimeFactory: async () => runtime, trust,
      ...(managedSubagents ? { managedSubagents } : {}),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      machineId: "machine-terminal-test",
      notifications: options.notifications ?? { enqueue, suppressAutomatic, markSessionInboxRead: vi.fn(async () => {}) } as unknown as NotificationService,
    });
    cleanup.push(() => registry.dispose());
    await registry.initialize();
    slot = await registry.create(cwd);
    const model = options.model ?? faux.getModel();
    await slot.setModel(model.provider, model.id);
    const sdkEvents: string[] = [];
    const onEvent = (slot as unknown as { onEvent: (event: { type: string }) => void }).onEvent.bind(slot);
    vi.spyOn(slot as unknown as { onEvent: (event: { type: string }) => void }, "onEvent").mockImplementation((event) => {
      if (event.type === "agent_start" || event.type === "agent_end" || event.type === "agent_settled") sdkEvents.push(event.type);
      onEvent(event);
    });
    if (options.observed) {
      registry.subscribe("phone", slot.id);
      registry.setPresentationVisibility({
        clientId: "phone", sessionId: slot.id, subscriptionToken: "subscription", revision: 1, visible: true,
      });
    }
    const settle = async () => {
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      await waitFor(() => enqueue.mock.calls.length + suppressAutomatic.mock.calls.length > 0, "the title refresh");
      // A mock call is visible before its async admission recorder settles.
      await Promise.allSettled(enqueue.mock.results.map((result) => result.value));
    };
    return { root, slot, registry, faux, enqueue, suppressAutomatic, settle, canonicalAtAdmission, persistedAtAdmission, sdkEvents };
  }

  it("lets an authenticated local Gateway client quiet its own presentation without disturbing mobile state", async () => {
    const value = await fixture([fauxAssistantMessage("private response")]);
    const sessionId = value.slot.id;
    const devices = new DeviceStore(value.root, "machine-terminal-test");
    await devices.initialize();
    const localToken = JSON.parse(await readFile(join(value.root, "gateway", "local-auth.json"), "utf8")).bearerToken as string;
    const enrollment = await devices.ensureEnrollment();
    const paired = await devices.pair(enrollment.code, "phone");
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const address = probe.address();
    if (!address || typeof address === "string") throw new Error("probe did not bind");
    const port = address.port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 64 * 1_024, devices,
      uploads: {} as any, sessions: value.registry,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: {
        info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 8, minProtocolVersion: 8, machineId: "machine-terminal-test", machineName: "test", capabilities: [] }),
        terminalBelongsToSession: () => false,
        releaseClient: vi.fn(),
        invoke: async (context: any, method: string, params: any) => {
          if (method === "session.open") {
            const syncToken = context.beginSynchronization(params.sessionId);
            const snapshot = value.slot.snapshot();
            context.establishSynchronization(params.sessionId, snapshot);
            return { session: snapshot, syncToken, subscriptionToken: syncToken };
          }
          if (method === "session.sync") {
            context.completeSynchronization(params.sessionId, params.syncToken);
            return { synchronized: true };
          }
          if (method === "session.presentation.set") {
            return context.setPresentationVisibility(params.sessionId, params.subscriptionToken, params.revision, params.visible);
          }
          throw new Error(`unexpected method ${method}`);
        },
      } as any,
      logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanup.push(async () => gateway.close());

    const connect = async (prefix: string, token: string, mobile: boolean) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
      const frames: any[] = [];
      socket.on("message", raw => frames.push(JSON.parse(raw.toString())));
      await once(socket, "open");
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 8, ...(mobile ? { clientRole: "mobile" } : {}) }));
      await waitFor(() => frames.some(frame => frame.type === "hello"), `${prefix} hello`);
      const request = async (id: string, method: string, params: Record<string, unknown>) => {
        socket.send(JSON.stringify({ type: "request", id, method, params }));
        await waitFor(() => frames.some(frame => frame.id === id), `${prefix} ${id}`);
        return frames.find(frame => frame.id === id);
      };
      const opened = await request(`${prefix}-open`, "session.open", { sessionId });
      expect(opened.error).toBeUndefined();
      await request(`${prefix}-sync`, "session.sync", { sessionId, syncToken: opened.result.syncToken });
      return { socket, request, subscriptionToken: opened.result.subscriptionToken };
    };
    const local = await connect("local", localToken, false);
    const phone = await connect("phone", paired.token, true);
    const technical = await connect("technical", paired.token, false);
    const localVisible = await local.request("local-visible", "session.presentation.set", {
      sessionId, subscriptionToken: local.subscriptionToken, revision: 1, visible: true,
    });
    expect(localVisible.result).toEqual({ revision: 1, visible: true });
    const denied = await technical.request("technical-visible", "session.presentation.set", {
      sessionId, subscriptionToken: technical.subscriptionToken, revision: 1, visible: true,
    });
    expect(denied.error.code).toBe("invalid_request");

    // A mobile connection exists but is not presenting: the local lease alone
    // owns this turn's observed disposition.
    await value.slot.prompt("terminal request");
    await value.settle();
    expect(value.enqueue).not.toHaveBeenCalled();
    expect(value.suppressAutomatic).toHaveBeenCalledExactlyOnceWith({
      sessionId, sourceId: expect.any(String), kind: "agent_finished",
    });
    expect(value.registry.attentionProjection(sessionId).isUnread).toBe(false);

    const phoneVisible = await phone.request("phone-visible", "session.presentation.set", {
      sessionId, subscriptionToken: phone.subscriptionToken, revision: 1, visible: true,
    });
    expect(phoneVisible.result).toEqual({ revision: 1, visible: true });
    const localClosed = once(local.socket, "close");
    local.socket.close();
    await localClosed;
    expect(value.registry.isSessionPresented(sessionId)).toBe(true);
    phone.socket.close();
    technical.socket.close();
    await waitFor(() => !value.registry.isSessionPresented(sessionId), "all presentation leases to be removed after disconnect");
  });

  it.each([
    ["stop", "The agent finished responding.", "completed"],
    ["length", "The agent reached its response limit.", "completed"],
    ["error", "The agent stopped because of an error.", "failed"],
    ["aborted", "The agent was stopped.", "interrupted"],
    ["toolUse", "The agent stopped without a final response.", "outcomeUnknown"],
  ] as const)("notifies exactly once for final %s, after its canonical terminal receipt", async (stopReason, message, lifecycle) => {
    const value = await fixture([fauxAssistantMessage("private response", { stopReason, errorMessage: "private provider detail" })]);
    await value.slot.prompt("terminal request");
    await value.settle();
    const entries = value.canonicalAtAdmission[0]!;
    const assistant = entries.findLast((entry) => entry.type === "message" && entry.message.role === "assistant");
    expect(value.enqueue).toHaveBeenCalledExactlyOnceWith({
      sessionId: value.slot.id, sourceId: assistant.id, kind: "agent_finished",
      title: "terminal request", message, route: { sessionId: value.slot.id, machineId: "machine-terminal-test" },
    });
    const ownsTerminal = (entry: any) => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data.receiptKind === "terminal" && entry.data.lifecycle === lifecycle;
    expect(entries.some(ownsTerminal)).toBe(true);
    expect(value.persistedAtAdmission[0]?.some(ownsTerminal)).toBe(true);
    expect(value.suppressAutomatic).not.toHaveBeenCalled();
    (value.slot as unknown as { onEvent(event: { type: "agent_settled" }): void }).onEvent({ type: "agent_settled" });
    expect(value.enqueue).toHaveBeenCalledTimes(1);
  });

  it.each([true, false])("presents Home by its role in snapshots and relay payloads without renaming ordinary sessions (previews: %s)", async (previewsEnabled) => {
    const root = await mkdtemp(join(tmpdir(), "tron-home-title-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const payloads: Array<Record<string, unknown>> = [];
    const server = createServer(async (request, response) => {
      const chunks: Buffer[] = [];
      for await (const chunk of request) chunks.push(Buffer.from(chunk));
      payloads.push(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ status: "accepted_by_apns", apnsId: "fixture-apns" }));
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    cleanup.push(async () => { server.close(); await once(server, "close"); });
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("relay not bound");
    const relay = new PushRelayClient("https://push.example.test", async (_url, init) =>
      await fetch(`http://127.0.0.1:${address.port}/v3/notifications`, init) as never);
    const store = new NotificationGrantStore(root);
    let registry: RuntimeRegistry | undefined;
    const notifications = new NotificationService(store, relay, Date.now, undefined, undefined, undefined,
      (sessionId) => registry?.homeOwner().chapterStateFor(sessionId).homeId !== undefined);
    cleanup.push(async () => notifications.dispose());
    await notifications.initialize();
    await notifications.upsertGrant({ deviceId: "device_abcdefgh", installationId: "install_abcdefgh",
      grantId: "grant_abcdefgh", secret: Buffer.alloc(32, 9).toString("base64url"), previewsEnabled,
      relayOrigin: "https://push.example.test", notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true });
    const value = await fixture([
      fauxAssistantMessage([fauxToolCall("notify", { message: "Ordinary update" }, { id: "ordinary-title-explicit" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("The update was queued."),
    ], { notifications });
    registry = value.registry;
    const model = value.faux.getModel();
    const designation = await registry.homeOwner().designate({ model: { provider: model.provider, id: model.id } }, () => model);
    const home = await registry.acquire(designation.sessionId);
    await home.rename("Generated Home conversation title");
    await value.slot.rename("Ordinary project title");
    expect(home.snapshot().name).toBe("Home");
    expect(value.slot.snapshot().name).toBe("Ordinary project title");
    // All producers, including input-needed and settings notifications, pass
    // through this real admission/store/HTTP boundary. No APNs connection occurs.
    await notifications.enqueue({ sessionId: home.id, sourceId: "home-title-explicit", kind: "explicit",
      title: "Generated Home conversation title", message: "Home update",
      route: { sessionId: home.id, machineId: "machine-terminal-test" } });
    await notifications.userInputRequired({ sessionId: home.id, interactionId: "home-title-input", observed: false,
      machineId: "machine-terminal-test" });
    for (const kind of ["waiting", "agent_finished"] as const) {
      await notifications.enqueue({ sessionId: home.id, sourceId: `home-title-${kind}`, kind,
        title: "Generated Home conversation title", message: "Home outcome",
        route: { sessionId: home.id, machineId: "machine-terminal-test" } });
    }
    await value.slot.prompt("Send the ordinary update.");
    await waitFor(() => payloads.length === 6, "explicit and terminal payloads at the local relay");
    expect(payloads.filter(item => item.sessionId === home.id).map(item => item.title)).toEqual(["Home", "Home", "Home", "Home"]);
    expect(payloads.find(item => item.sessionId === value.slot.id)?.title).toBe(previewsEnabled ? "Ordinary project title" : "Tron");
    expect(payloads.find(item => item.sessionId === home.id && item.notificationKind === "explicit")?.message)
      .toBe(previewsEnabled ? "Home update" : "Tron has an update. Open Tron to view it.");
    expect((await notifications.inbox()).notifications.filter(item => item.sessionId === home.id).map(item => item.title))
      .toEqual(["Home", "Home", "Home", "Home"]);
    // A previously admitted row keeps its durable receipt but not an obsolete
    // user-visible Home title. Reading never rewrites that historical evidence.
    await store.update(document => {
      for (const entry of document.inbox) if (entry.sessionId === home.id) entry.title = "Historical generated Home title";
      return document;
    });
    expect((await notifications.inbox()).notifications.filter(item => item.sessionId === home.id).map(item => item.title))
      .toEqual(["Home", "Home", "Home", "Home"]);
    expect((await store.snapshot()).inbox.filter(item => item.sessionId === home.id).every(item => item.title === "Historical generated Home title")).toBe(true);
    // Exercise the same mobile open/sync/visible journey as the app, not just
    // the presence owner: redaction must never remove the canonical chat route.
    const devices = new DeviceStore(value.root, "machine-terminal-test");
    await devices.initialize();
    const enrollment = await devices.ensureEnrollment();
    const paired = await devices.pair(enrollment.code, "Fixture phone");
    const receipts = new CommandReceiptStore(value.root);
    cleanup.push(() => receipts.dispose());
    const service = new GatewayService({
      config: { tronHome: value.root, machineId: "machine-terminal-test", machineName: "Fixture Mac" },
      devices, sessions: registry, notifications, receipts,
      uploads: {}, terminals: { belongsToSession: () => false }, logger: { log() {} },
    } as never);
    const gateway = new GatewayServer({
      host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576,
      devices, sessions: registry, service, uploads: {} as never,
      auth: { detachClient() {}, cancelOwner() {} } as never, logger: { log() {} } as never,
    });
    await gateway.listen();
    cleanup.push(() => gateway.close());
    const port = (gateway as unknown as { server: { address(): { port: number } } }).server.address().port;
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    cleanup.push(async () => { socket.terminate(); });
    const frames: any[] = [];
    socket.on("message", raw => frames.push(JSON.parse(raw.toString())));
    await once(socket, "open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 8, clientRole: "mobile" }));
    await waitFor(() => frames.some(frame => frame.type === "hello"), "the mobile hello");
    let requestSequence = 0;
    const request = async (method: string, params: object) => {
      const id = `notification-read-${++requestSequence}`;
      socket.send(JSON.stringify({ type: "request", id, method, params }));
      await waitFor(() => frames.some(frame => frame.id === id), method);
      const response = frames.find(frame => frame.id === id);
      expect(response.error).toBeUndefined();
      return response.result;
    };
    const readCuts = vi.spyOn(notifications, "markSessionInboxRead");
    const present = async (sessionId: string) => {
      const opened = await request("session.open", { sessionId });
      await request("session.sync", { sessionId, syncToken: opened.syncToken });
      const cutIndex = readCuts.mock.calls.length;
      await request("session.presentation.set", { sessionId, subscriptionToken: opened.subscriptionToken, revision: 1, visible: true });
      expect(readCuts.mock.calls[cutIndex]).toEqual([sessionId]);
      await readCuts.mock.results[cutIndex]!.value;
      return opened.subscriptionToken;
    };
    const unreadBefore = await request("notification.inbox.list", { filter: "unread" });
    expect(unreadBefore.unreadCount).toBe(6);
    await present(value.slot.id);
    await waitFor(async () => (await notifications.inbox()).unreadCount === 4, "the ordinary chat read cut");
    const afterChat = await request("notification.inbox.list", { filter: "unread" });
    expect(afterChat.unreadCount).toBe(4);
    expect(afterChat.notifications.every((row: { sessionId: string }) => row.sessionId === home.id)).toBe(true);
    const homeToken = await present(home.id);
    await waitFor(async () => (await notifications.inbox()).unreadCount === 0, "the Home read cut across all kinds");
    const afterHome = await request("notification.inbox.list", { filter: "unread" });
    expect(afterHome.notifications).toEqual([]);
    expect(afterHome.unreadCount).toBe(0);
    // Home is one chat across physical chapters. A completion in its successor
    // must not strand an explicit update in the sealed predecessor (#1303).
    await request("session.presentation.set", { sessionId: home.id, subscriptionToken: homeToken, revision: 2, visible: false });
    value.faux.setResponses([fauxAssistantMessage("Predecessor Home conversation")]);
    await home.prompt("Start the Home chapter.");
    await waitFor(() => !home.isBusy, "the predecessor to settle");
    await notifications.markSessionInboxRead(home.id);
    await notifications.enqueue({ sessionId: home.id, sourceId: "sibling-home-update", kind: "explicit", message: "Home update",
      route: { sessionId: home.id, machineId: "machine-terminal-test" } });
    // Real canonical growth crosses the actual rollover limit; no mocked Home
    // record, chapter metrics or alternate notification admission path.
    (home as unknown as { sessionManager: { appendCustomEntry(type: string, data: unknown): void } }).sessionManager
      .appendCustomEntry("fixture-chapter-growth", { padding: "x".repeat(HOME_SOFT_BYTES) });
    await registry.homeOwner().chapterQuiescent(home.id);
    const successorId = (await registry.homeOwner().status()).sessionId!;
    expect(successorId).not.toBe(home.id);
    const successor = await registry.materializeReservedHome(successorId);
    value.faux.setResponses([fauxAssistantMessage("Successor Home completion")]);
    await successor.prompt("Continue Home.");
    await waitFor(() => !successor.isBusy, "the successor completion");
    await notifications.enqueue({ sessionId: value.slot.id, sourceId: "unrelated-chat-update", kind: "explicit", message: "Other chat update",
      route: { sessionId: value.slot.id, machineId: "machine-terminal-test" } });
    const siblingInbox = await request("notification.inbox.list", { filter: "unread" });
    const completion = siblingInbox.notifications.find((row: NotificationInboxItem) => row.sessionId === successorId && row.kind === "agent_finished");
    expect(completion).toBeDefined();
    expect(siblingInbox.notifications.some((row: NotificationInboxItem) => row.sessionId === home.id && row.kind === "explicit")).toBe(true);
    // Opening the completion detail reads only that row; Open Chat then travels
    // its exact payload route through the shared synchronized presentation path.
    await request("notification.inbox.read", { commandId: "open-home-completion", id: completion.id });
    await present(completion.sessionId);
    const afterSiblingOpen = await request("notification.inbox.list", { filter: "unread" });
    const report = join(process.cwd(), `test-results/home-title-payloads-${previewsEnabled ? "preview" : "redacted"}.json`);
    await mkdir(dirname(report), { recursive: true });
    await writeFile(report, JSON.stringify({ passed: afterSiblingOpen.unreadCount === 1, physicalAPNsDelivery: false, payloads,
      unreadCounts: [unreadBefore.unreadCount, afterChat.unreadCount, afterHome.unreadCount],
      homeSiblingOpen: { predecessor: home.id, successor: successorId, unreadBefore: siblingInbox.unreadCount,
        unreadAfter: afterSiblingOpen.unreadCount, unreadSessions: afterSiblingOpen.notifications.map((row: NotificationInboxItem) => row.sessionId) } }, null, 2));
    expect(afterSiblingOpen.notifications.map((row: NotificationInboxItem) => row.sessionId)).toEqual([value.slot.id]);
    expect(afterSiblingOpen.unreadCount).toBe(1);
  });

  it("sends terminal and input notifications through the Gateway store to a local fake relay", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-notification-e2e-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const logger = new GatewayLogger();
    const received: Array<{ envelope: Record<string, unknown>; requestId: string; signatureValid: boolean }> = [];
    let routineCount = 1_000;
    const relayServer = createServer(async (request, response) => {
      const chunks: Buffer[] = [];
      for await (const chunk of request) chunks.push(Buffer.from(chunk));
      const body = Buffer.concat(chunks).toString("utf8");
      const envelope = JSON.parse(body) as Record<string, unknown>;
      const requestId = request.headers["x-tron-request-id"] as string;
      expect(envelope.requestId).toBe(requestId);
      expect(received.some((entry) => entry.requestId === requestId)).toBe(false);
      const signatureValid = request.headers["x-tron-signature"] === relaySignature(
        Buffer.alloc(32, 9).toString("base64url"), "POST", "/v3/notifications",
        request.headers["x-tron-timestamp"] as string, requestId, body,
      );
      received.push({ envelope, requestId, signatureValid });
      if (envelope.notificationKind !== "ask" && envelope.notificationKind !== "explicit") routineCount += 1;
      const rateLimited = envelope.notificationKind !== "ask" && envelope.notificationKind !== "explicit" && routineCount > 1_000;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(rateLimited
        ? { status: "rate_limited", reason: "daily_limit" }
        : { status: "accepted_by_apns", apnsId: `apns-${requestId}` }));
    });
    relayServer.listen(0, "127.0.0.1");
    await once(relayServer, "listening");
    cleanup.push(async () => { relayServer.close(); await once(relayServer, "close"); });
    const address = relayServer.address();
    if (!address || typeof address === "string") throw new Error("fake relay did not bind a TCP port");
    const relay = new PushRelayClient("https://push.example.test", async (_url, init) =>
      await fetch(`http://127.0.0.1:${address.port}/v3/notifications`, init) as never);
    const signals: Array<{ kind: string; outcome: string; relayReason: string }> = [];
    const notifications = new NotificationService(
      store, relay, Date.now, () => {}, () => {}, (signal) => {
        signals.push(signal);
        logger.log(signal.outcome === "failed" || signal.outcome === "refused" ? "warning" : "info", "Push notification delivery", {
          event: `notification.push.${signal.outcome.replaceAll("_", "-")}`,
          source: "notifications", kind: signal.kind, outcome: signal.outcome, reason: signal.relayReason,
        });
      },
    );
    cleanup.push(async () => notifications.dispose());
    await notifications.initialize();
    await notifications.upsertGrant({
      deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
      secret: Buffer.alloc(32, 9).toString("base64url"), previewsEnabled: true,
      relayOrigin: "https://push.example.test", notifyWhenAskPresented: true,
      notifyWhenFinished: true, notifyWhenWaiting: true,
    });
    const childStarted = barrier();
    const releaseChild = barrier();
    const modelServer = createServer(async (request, response) => {
      let body = "";
      for await (const chunk of request) body += Buffer.from(chunk).toString("utf8");
      const last = (JSON.parse(body) as { messages: Array<{ role: string; content: unknown }> }).messages.at(-1);
      const input = typeof last?.content === "string" ? last.content : JSON.stringify(last?.content);
      if (!request.url?.endsWith("chat/completions") || !input?.includes("CHILD_OFFLINE_COMPLETE")) {
        response.writeHead(500).end("Unexpected notification subagent model request");
        return;
      }
      childStarted.release();
      await releaseChild.promise;
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const [delta, finish] of [[{ role: "assistant", content: "CHILD_OFFLINE_COMPLETE" }, null], [{}, "stop"]] as const) {
        response.write(`data: ${JSON.stringify({ id: "notification-child", object: "chat.completion.chunk", created: 1,
          model: "notification-child", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
      }
      response.end("data: [DONE]\n\n");
    });
    modelServer.requestTimeout = 60_000;
    modelServer.listen(0, "127.0.0.1");
    await once(modelServer, "listening");
    cleanup.push(async () => { modelServer.close(); await once(modelServer, "close"); });
    const modelAddress = modelServer.address();
    if (!modelAddress || typeof modelAddress === "string") throw new Error("fake child model did not bind a TCP port");
    const value = await fixture([
      fauxAssistantMessage([fauxToolCall("subagent", {
        agent: "offline-worker", task: "Return CHILD_OFFLINE_COMPLETE", async: true,
        acceptance: { level: "none", reason: "Bounded notification regression" },
      }, { id: "notification-subagent-launch" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("The background task is still running."),
      fauxAssistantMessage("The background task remains active."),
      fauxAssistantMessage("The background task is complete."),
      fauxAssistantMessage("The ordinary request is complete."),
    ], {
      notifications,
      useAgentModels: true,
      managedSubagents: (tronHome) => {
        delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
        return ManagedSubagents.activateForStartup(tronHome, logger);
      },
      setup: async ({ agentDir, cwd, trust }) => {
        await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: {
          "notification-child": {
            baseUrl: `http://127.0.0.1:${modelAddress.port}/v1`, api: "openai-completions", apiKey: "test-only",
            models: [{ id: "notification-child", name: "Notification child", reasoning: false, input: ["text"],
              contextWindow: 128_000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
          },
        } }));
        await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
        await writeFile(join(cwd, ".pi", "agents", "offline-worker.md"),
          `---\nname: offline-worker\ndescription: Offline notification regression\nmodel: notification-child/notification-child\ntools: read\n---\nReturn the requested completion marker.\n`);
        await trust.set(cwd, true);
      },
    });
    let runId: string | undefined;
    let runDirectory: string | undefined;
    try {
      const resources = await value.slot.resources() as unknown as { tools: Array<{ name: string }> };
      expect(resources.tools.some(({ name }) => name === "subagent")).toBe(true);
      await notifications.userInputRequired({ sessionId: value.slot.id, interactionId: "ask-e2e", observed: false, machineId: "machine-terminal-test" });
      await waitFor(() => received.some(({ envelope }) => envelope.notificationKind === "ask"), "the input-needed relay delivery");
      expect(received.find(({ envelope }) => envelope.notificationKind === "ask")?.envelope).toMatchObject({
        title: "Input needed", message: "Tron needs your input. Open Tron to respond.", interruptionLevel: "time-sensitive",
      });

      await value.slot.prompt("background task");
      await childStarted.promise;
      const launchResult = (value.slot as unknown as { sessionManager: { getBranch(): any[] } }).sessionManager.getBranch()
        .findLast((entry) => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "notification-subagent-launch");
      expect(launchResult?.message.isError).toBe(false);
      expect(launchResult?.message.details).toMatchObject({ asyncDir: expect.any(String), mission: { status: "active" } });
      runId = launchResult?.message.details?.runId;
      runDirectory = launchResult?.message.details?.asyncDir;
      const launchActivity = value.slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === "notification-subagent-launch");
      expect(launchActivity).toMatchObject({ mode: "asynchronous", status: "running", lifecycle: { state: "running" } });
      await waitFor(() => received.some(({ envelope }) => envelope.notificationKind === "waiting"), "the waiting notification");
      expect(received.find(({ envelope }) => envelope.notificationKind === "waiting")?.envelope).toMatchObject({
        title: "background task", message: "The agent is waiting on 1 background task.",
      });

      const intermediate = value.slot.prompt("background task still pending");
      await intermediate;
      await waitFor(() => value.sdkEvents.filter((event) => event === "agent_settled").length >= 2, "the intermediate wake-up response to settle");
      expect(received.filter(({ envelope }) => envelope.notificationKind === "waiting")).toHaveLength(1);
      expect(received.filter(({ envelope }) => envelope.notificationKind === "agent_finished")).toHaveLength(0);

      releaseChild.release();
      await waitFor(async () => {
        try {
          const status = JSON.parse(await readFile(join(runDirectory!, "status.json"), "utf8")) as { state?: string };
          return status.state === "complete";
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
          throw error;
        }
      }, "the real managed subagent provider status to complete");
      // #616 tracks the tron.4 terminal-artifact identity mismatch: the provider is complete,
      // but the session-owned activity remains live until that projection is fixed.
      // The parent's completion wake is the one turn that clears that activity, so its
      // agent_finished is the completion event: wait for its delivery and turn settlement
      // before snapshotting, because the wake's latency depends on host load.
      await waitFor(() => received.some(({ envelope }) => envelope.notificationKind === "agent_finished" && envelope.title === "background task"),
        "the completion wake's agent_finished delivery");
      await waitFor(() => !value.slot.isBusy, "the completion wake turn to settle");
      expect(received.filter(({ envelope }) => envelope.notificationKind === "waiting")).toHaveLength(1);
      expect(received.filter(({ envelope }) => envelope.notificationKind === "agent_finished")).toHaveLength(1);
      expect(received.every(({ signatureValid }) => signatureValid)).toBe(true);
      expect(received.map(({ envelope }) => envelope.notificationKind)).toEqual(["ask", "waiting", "agent_finished"]);

      // The relay is already at its device daily backstop. A routine refusal is terminal,
      // observable, retained in the inbox, and does not prevent the ask exemption.
      await notifications.enqueue({ sessionId: value.slot.id, sourceId: "routine-over-cap", kind: "agent_finished", title: "Routine", message: "Finished." });
      await waitFor(() => signals.some(({ relayReason }) => relayReason === "daily_limit"), "the cap refusal signal");
      await notifications.userInputRequired({ sessionId: value.slot.id, interactionId: "ask-after-cap", observed: false, machineId: "machine-terminal-test" });
      await waitFor(async () => received.filter(({ envelope }) => envelope.notificationKind === "ask").length === 2
        && (await store.snapshot()).pending.length === 0, "the ask after routine cap");
      expect((await store.snapshot()).pending).toEqual([]);
      expect(signals).toContainEqual({ kind: "agent_finished", outcome: "rate_limited", relayReason: "daily_limit" });
      expect(logger.recent(100).some((row) => row.event === "notification.push.rate-limited" && row.reason === "daily_limit")).toBe(true);
      expect((await notifications.inbox()).notifications).toContainEqual(expect.objectContaining({ kind: "agent_finished", title: "Routine", outcome: "failed" }));
      expect(received.filter(({ envelope }) => envelope.title === "Routine")).toHaveLength(1);
      expect(received.map(({ envelope }) => envelope.notificationKind)).toEqual(["ask", "waiting", "agent_finished", "agent_finished", "ask"]);
      const inbox = (await notifications.inbox()).notifications;
      expect(inbox.map(({ kind, title, message }) => ({ kind, title, message }))).toEqual([
        { kind: "ask", title: "Input needed", message: "Tron needs your input. Open Tron to respond." },
        { kind: "agent_finished", title: "Routine", message: "Finished." },
        { kind: "agent_finished", title: "background task", message: "The agent finished responding." },
        { kind: "waiting", title: "background task", message: "The agent is waiting on 1 background task." },
        { kind: "ask", title: "Input needed", message: "Tron needs your input. Open Tron to respond." },
      ]);
      const reportPath = process.env.TRON_NOTIFICATION_E2E_REPORT
        ?? join(process.cwd(), "test-results", "runtime-terminal-notifications.integration.json");
      await mkdir(dirname(reportPath), { recursive: true });
      await writeFile(reportPath, `${JSON.stringify({
        passed: true,
        provider: "faux-parent+local-managed-subagent",
        relay: "local-http",
        completedManagedRunId: runId,
        deliveredKinds: received.map(({ envelope }) => envelope.notificationKind),
        inbox: inbox.map(({ kind, title, message, outcome }) => ({ kind, title, message, outcome })),
        capSignal: signals.find(({ kind, relayReason }) => kind === "agent_finished" && relayReason === "daily_limit"),
        capLog: logger.recent(100).find((row) => row.event === "notification.push.rate-limited" && row.kind === "agent_finished" && row.reason === "daily_limit"),
      }, null, 2)}\n`);
    } finally {
      releaseChild.release();
      if (runId) {
        const subagentTool = (value.slot as unknown as {
          runtime: { session: { extensionRunner: { getToolDefinition(name: string): {
            execute(toolCallId: string, args: unknown, signal: AbortSignal): Promise<unknown>;
          } | undefined } } };
        }).runtime.session.extensionRunner.getToolDefinition("subagent");
        if (subagentTool) {
          await subagentTool.execute(`notification-cleanup-${runId}`, { action: "stop", id: runId }, new AbortController().signal).catch(() => {});
        }
        if (runDirectory) {
          await waitFor(async () => {
            try {
              const status = JSON.parse(await readFile(join(runDirectory!, "status.json"), "utf8")) as { state?: string };
              return ["complete", "failed", "stopped", "rejected"].includes(status.state ?? "");
            } catch (error) {
              if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
              throw error;
            }
          }, "the detached run to become terminal before cleanup", { boundMs: 10_000 }).catch(() => {});
        }
      }
      notifications.dispose();
    }
  });

  it("waits through retries and announces only the exhausted final error", async () => {
    const resumed = barrier();
    const release = barrier();
    const error = () => fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" });
    const value = await fixture([error(), async () => { resumed.release(); await release.promise; return error(); }, error()], {
      retry: { enabled: true, maxRetries: 2, baseDelayMs: 1 },
    });
    try {
      await value.slot.prompt("retry request");
      await resumed.promise;
      expect(value.enqueue).not.toHaveBeenCalled();
    } finally { release.release(); }
    await value.settle();
    expect(value.faux.state.callCount).toBe(3);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
  });

  it("does not mislabel a cancelled retry as exhaustion or reuse earlier success", async () => {
    const value = await fixture([
      fauxAssistantMessage("previous success"),
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" }),
    ], { retry: { enabled: true, maxRetries: 2, baseDelayMs: 60_000 } });
    await value.slot.prompt("earlier request");
    await value.settle();
    const previousSource = value.enqueue.mock.calls[0]![0].sourceId;
    value.enqueue.mockClear();
    await value.slot.prompt("cancel retry request");
    await waitFor(() => value.slot.snapshot().phase === "retrying", "the retrying phase");
    expect(value.enqueue).not.toHaveBeenCalled();
    await value.slot.abort();
    await value.settle();
    expect(value.faux.state.callCount).toBe(2);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0]).toMatchObject({ message: "The agent was stopped." });
    expect(value.enqueue.mock.calls[0]![0].sourceId).not.toBe(previousSource);
  });

  it("announces only the final extension continuation, even when it fails", async () => {
    const value = await fixture([
      fauxAssistantMessage("intermediate success"),
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "terminal failure" }),
    ], { extension: `export default function(pi) {
      let continued = false;
      pi.on("agent_before_settle", (event) => {
        pi.appendEntry("test-settlement-order", { stage: "agent_before_settle", outcome: event.outcome });
        if (continued) return;
        continued = true;
        return { entries: [{ type: "custom_message", customType: "test-continuation", content: "continue", display: false }], continue: true };
      });
      pi.on("agent_settled", () => pi.appendEntry("test-settlement-order", { stage: "agent_settled" }));
    }` });
    await value.slot.prompt("continuation request");
    await value.settle();
    expect(value.faux.state.callCount).toBe(2);
    expect(value.sdkEvents).toEqual(["agent_start", "agent_end", "agent_start", "agent_end", "agent_settled"]);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
    const entries = value.canonicalAtAdmission[0]!;
    const assistants = entries.filter((entry: any) => entry.type === "message" && entry.message.role === "assistant");
    const terminals = entries.filter((entry: any) => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    const callbacks = entries.filter((entry: any) => entry.type === "custom" && entry.customType === "test-settlement-order")
      .map((entry: any) => entry.data.stage);
    expect(callbacks).toEqual(["agent_before_settle", "agent_before_settle", "agent_settled"]);
    expect(assistants).toHaveLength(2);
    expect(assistants[1].message.stopReason).toBe("error");
    expect(value.enqueue.mock.calls[0]![0].sourceId).toBe(assistants[1].id);
    // The user invocation owns its first completed assistant. Pi's queued
    // continuation is a distinct SDK run whose failure notifies separately; it
    // must not rewrite the already durable invocation receipt.
    expect(terminals).toHaveLength(1);
    expect(terminals[0].data.lifecycle).toBe("completed");
  });

  it("lets recoverable tool errors continue but announces a terminating tool block", async () => {
    const value = await fixture([
      fauxAssistantMessage([fauxToolCall("read", { path: "absent-file" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("recovered"),
      fauxAssistantMessage([fauxToolCall("read", { path: "blocked-file" })], { stopReason: "toolUse" }),
    ], { extension: `export default function(pi) {
      pi.on("tool_call", (event) => event.input.path === "blocked-file"
        ? { block: true, reason: "test block", terminate: true } : undefined);
    }` });
    await value.slot.prompt("recoverable tool request");
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent finished responding.");
    value.enqueue.mockClear();
    await value.slot.prompt("blocked tool request");
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped without a final response.");
    expect(value.faux.state.callCount).toBe(3);
  });

  it("announces a genuine provider exception as failure, not an earlier completion", async () => {
    const value = await fixture([() => { throw new Error("private provider exception"); }]);
    await value.slot.prompt("provider exception request");
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
  });

  it("waits for queued follow-up work before announcing its final failure", async () => {
    const started = barrier();
    const release = barrier();
    let queuedOperationId!: string;
    const value = await fixture([
      async () => { started.release(); await release.promise; return fauxAssistantMessage("intermediate response"); },
      fauxAssistantMessage("", { stopReason: "error" }),
    ]);
    try {
      await value.slot.prompt("initial request");
      await started.promise;
      queuedOperationId = (await value.slot.prompt("queued request", [], "followUp")).operationId;
      expect(value.enqueue).not.toHaveBeenCalled();
    } finally { release.release(); }
    await value.settle();
    expect(value.faux.state.callCount).toBe(2);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
    const terminal = value.canonicalAtAdmission[0]!.find((entry) => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data.receiptKind === "terminal" && entry.data.operationId === queuedOperationId);
    expect(terminal?.data.lifecycle).toBe("failed");
    await waitFor(() => !value.slot.isDrainBusy, "the slot to stop draining");
  });

  it("announces drain-cutoff interruption without overwriting the preceding completion receipt", async () => {
    const started = barrier();
    const release = barrier();
    const value = await fixture([
      async () => { started.release(); await release.promise; return fauxAssistantMessage("preceding response"); },
      fauxAssistantMessage("rejected continuation"),
    ], { extension: `export default function(pi) {
      let continued = false;
      pi.on("agent_before_settle", (event) => {
        pi.appendEntry("test-settlement-order", { stage: "agent_before_settle", outcome: event.outcome });
        if (continued) return;
        continued = true;
        return { entries: [{ type: "custom_message", customType: "test-continuation", content: "continue", display: false }], continue: true };
      });
      pi.on("agent_settled", () => pi.appendEntry("test-settlement-order", { stage: "agent_settled" }));
    }` });
    try {
      await value.slot.prompt("draining request");
      await started.promise;
      value.slot.beginAdministrativeDrainCutoff();
    } finally { release.release(); }
    await value.settle();
    await waitFor(() => !value.slot.isDrainBusy, "the slot to stop draining");
    expect(value.sdkEvents).toEqual(["agent_start", "agent_end", "agent_start", "agent_end", "agent_settled"]);
    expect(value.enqueue.mock.calls, JSON.stringify(value.enqueue.mock.calls)).toHaveLength(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent was stopped.");
    const entries = value.canonicalAtAdmission[0]!;
    const assistants = entries.filter((entry: any) => entry.type === "message" && entry.message.role === "assistant");
    expect(assistants).toHaveLength(2);
    expect(assistants[0].message.stopReason).toBe("stop");
    expect(assistants[1].message.stopReason).toBe("aborted");
    // Drain rejects the SDK continuation; notification remains bound to the
    // preceding successful assistant without rewriting its completion receipt.
    expect(value.enqueue.mock.calls[0]![0].sourceId).toBe(assistants[0].id);
    expect(entries.filter((entry: any) => entry.type === "custom" && entry.customType === "test-settlement-order")
      .map((entry: any) => entry.data.stage)).toEqual(["agent_before_settle", "agent_settled"]);
    const terminals = entries.filter((entry: any) => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    expect(terminals).toHaveLength(1);
    expect(terminals[0].data.lifecycle).toBe("completed");
  });

  it("suppresses a terminal error when its chat is already observed", async () => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error" })], { observed: true });
    await value.slot.prompt("visible failure");
    await value.settle();
    expect(value.enqueue).not.toHaveBeenCalled();
    expect(value.suppressAutomatic).toHaveBeenCalledTimes(1);
  });

  it.each([false, true])("latches error observation (%s) before terminal receipt I/O", async (observed) => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error" })], { observed });
    if (!observed) value.registry.subscribe("phone", value.slot.id);
    const writing = barrier();
    const release = barrier();
    const owner = value.slot as unknown as { persistInvocationReceipt(...args: any[]): Promise<void> };
    const persist = owner.persistInvocationReceipt.bind(owner);
    vi.spyOn(owner, "persistInvocationReceipt").mockImplementation(async (...args) => {
      if (args[0].receiptKind === "terminal") { writing.release(); await release.promise; }
      await persist(...args);
    });
    try {
      await value.slot.prompt("observation race request");
      await writing.promise;
      value.registry.setPresentationVisibility({
        clientId: "phone", sessionId: value.slot.id, subscriptionToken: "subscription", revision: 2, visible: !observed,
      });
    } finally { release.release(); }
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(observed ? 0 : 1);
    expect(value.suppressAutomatic).toHaveBeenCalledTimes(observed ? 1 : 0);
  });

  it("notifies admitted preflight failure but not malformed unadmitted requests or handled commands", async () => {
    const value = await fixture([], { extension: `export default function(pi) {
      pi.registerCommand("handled", { handler: async () => {} });
    }` });
    await expect(value.slot.prompt("invalid", [], undefined, {
      text: "invalid", attachmentEnvelope: "", attachmentCount: 2, attachments: [],
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(value.enqueue).not.toHaveBeenCalled();
    await value.slot.prompt("/handled");
    expect(value.enqueue).not.toHaveBeenCalled();
    // Exercise Pi's real missing-model preflight without reaching a network
    // provider or mocking prompt/settlement events.
    (value.slot as unknown as { runtime: { session: { agent: { state: { model: undefined } } } } })
      .runtime.session.agent.state.model = undefined;
    await expect(value.slot.prompt("setup request")).rejects.toBeDefined();
    await value.settle();
    expect(value.faux.state.callCount).toBe(0);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.persistedAtAdmission).toEqual([undefined]);
    const entries = value.canonicalAtAdmission[0]!;
    const terminal = entries.findLast((entry) => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    expect(terminal.data.lifecycle).toBe("failed");
    expect(value.enqueue.mock.calls[0]![0]).toMatchObject({
      sourceId: terminal.data.receiptId, message: "The agent stopped because of an error.",
    });
  });

  it("records ownership loss and notifies once when shutdown interrupts a live retry", async () => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" })], {
      retry: { enabled: true, maxRetries: 2, baseDelayMs: 60_000 },
    });
    await value.slot.prompt("interrupted request");
    await waitFor(() => value.slot.snapshot().phase === "retrying", "the retrying phase");
    await value.slot.shutdown();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent was interrupted before its outcome could be confirmed.");
    const terminal = value.canonicalAtAdmission[0]!.findLast((entry) => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    expect(terminal.data.lifecycle).toBe("outcomeUnknown");
  });

  it("keeps settlement healthy when notification admission fails", async () => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error" })]);
    value.enqueue.mockRejectedValueOnce(new Error("notification store unavailable"));
    await value.slot.prompt("notification failure request");
    await value.settle();
    expect(value.slot.snapshot().phase).toBe("idle");
  });
});
