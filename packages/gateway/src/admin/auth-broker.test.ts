import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { JsonValue } from "../protocol/types.js";
import { AuthBroker } from "./auth-broker.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

type LoginInteraction = Parameters<ModelRuntime["login"]>[2];

function runtimeWithLogin(login: (interaction: LoginInteraction) => Promise<void>): ModelRuntime {
  return {
    getProvider: () => ({ auth: { apiKey: { login: async () => "" } } }),
    login: (_providerId: string, _authType: string, interaction: LoginInteraction) => login(interaction),
  } as unknown as ModelRuntime;
}

async function flushPromises(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("auth event timed out");
}

describe("AuthBroker", () => {
  afterEach(() => vi.useRealTimers());
  it("forwards an interactive runtime prompt and stores the response without returning credentials", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-auth-broker-"));
    const runtime = await ModelRuntime.create({
      authPath: join(root, "auth.json"),
      modelsPath: null,
      refreshOnCreate: false,
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }));
    const operationId = broker.start("phone", "anthropic", "api_key").operationId;
    await waitFor(() => events.some((event) => event.topic === "auth.prompt"));
    const prompt = events.find((event) => event.topic === "auth.prompt")!.payload as Record<string, JsonValue>;

    broker.respond("phone", operationId, prompt.promptId as string, "test-key-not-a-real-credential");
    await waitFor(() => events.some((event) => event.topic === "auth.completed"));

    expect(events.find((event) => event.topic === "auth.completed")?.payload).toMatchObject({ success: true });
    expect(JSON.stringify(events)).not.toContain("test-key-not-a-real-credential");
    expect(runtime.hasConfiguredAuth("anthropic")).toBe(true);
  });

  it("treats duplicate and late prompt submissions as idempotent no-ops", async () => {
    let interaction: LoginInteraction | undefined;
    const runtime = runtimeWithLogin(async (value) => {
      interaction = value;
      await value.prompt({ type: "secret", message: "Enter API key" });
    });
    const events: Array<{ topic: string; payload: JsonValue }> = []
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }))
    const operationId = broker.start("phone", "provider", "api_key").operationId
    await waitFor(() => events.some((event) => event.topic === "auth.prompt"))
    const prompt = events.find((event) => event.topic === "auth.prompt")!.payload as Record<string, JsonValue>

    expect(broker.respond("phone", operationId, prompt.promptId as string, "first-key")).toBe(true)
    expect(broker.respond("phone", operationId, prompt.promptId as string, "duplicate-key")).toBe(false)
    await waitFor(() => events.some((event) => event.topic === "auth.completed"))

    // The completion event and the response acknowledgement can cross the
    // client presentation boundary. The bounded tombstone absorbs late UI work.
    expect(broker.respond("phone", operationId, prompt.promptId as string, "late-key")).toBe(false)
    expect(broker.cancel("phone", operationId)).toBe(false)
    expect(interaction?.signal.aborted).toBe(false)
  })

  it("bounds global and per-client operations and releases capacity on cancellation", () => {
    const runtime = runtimeWithLogin(async () => new Promise<void>(() => {}));
    const broker = new AuthBroker(runtime, () => {}, () => {}, {
      maximumOperations: 2,
      maximumOperationsPerClient: 1,
    });

    const phone = broker.start("phone", "provider", "api_key").operationId;
    expect(() => broker.start("phone", "other-provider", "api_key")).toThrow(expect.objectContaining({
      code: "busy",
      retryable: true,
    }));
    const tablet = broker.start("tablet", "provider", "api_key").operationId;
    expect(() => broker.start("desktop", "provider", "api_key")).toThrow(expect.objectContaining({ code: "busy" }));
    expect(broker.activeOperationCount).toBe(2);

    broker.cancel("phone", phone);
    expect(broker.activeOperationCount).toBe(1);
    const replacement = broker.start("phone", "provider", "api_key").operationId;
    expect(broker.activeOperationCount).toBe(2);
    broker.cancel("phone", replacement);
    broker.cancel("tablet", tablet);
    expect(broker.activeOperationCount).toBe(0);
  });

  it("waits for a cancelled global provider login to actually settle before refreshing its runtime", async () => {
    let finishLogin!: () => void;
    let loginStarted!: () => void;
    const started = new Promise<void>((resolve) => { loginStarted = resolve; });
    const runtime = runtimeWithLogin(async () => {
      loginStarted();
      await new Promise<void>((resolve) => { finishLogin = resolve; });
    });
    const broker = new AuthBroker(runtime, () => {});
    const refresh = vi.fn(async () => {});
    const operationId = broker.start("phone", "provider", "api_key", runtime, "phone", "command-1", "global").operationId;
    await started;

    broker.requestGlobalProviderRefresh(refresh);
    expect(refresh).not.toHaveBeenCalled();
    expect(broker.cancel("phone", operationId)).toBe(true);
    await flushPromises();
    expect(refresh).not.toHaveBeenCalled();

    finishLogin();
    await waitFor(() => refresh.mock.calls.length === 1);
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("times out providers that ignore abort and ignores their late completion", async () => {
    vi.useFakeTimers();
    let interaction: LoginInteraction | undefined;
    // Pi rejects a login aborted before credential mutation; a late success is
    // covered by the committed-credential projection test below.
    let completeLogin!: () => void;
    const login = new Promise<void>((_resolve, reject) => { completeLogin = () => reject(new Error("late failure")); });
    const runtime = runtimeWithLogin(async (value) => {
      interaction = value;
      return login;
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }), () => {}, {
      operationTimeoutMs: 100,
    });
    const operationId = broker.start("phone", "provider", "api_key").operationId;
    await flushPromises();

    await vi.advanceTimersByTimeAsync(100);
    expect(broker.activeOperationCount).toBe(0);
    expect(interaction?.signal.aborted).toBe(true);
    expect(events.filter((event) => event.topic === "auth.completed")).toEqual([
      expect.objectContaining({ payload: expect.objectContaining({ operationId, success: false }) }),
    ]);
    await expect(interaction?.prompt({ type: "text", message: "late" })).rejects.toMatchObject({ code: "cancelled" });
    interaction?.notify({ type: "progress", message: "late" });

    completeLogin();
    await flushPromises();
    expect(events.filter((event) => event.topic === "auth.completed")).toHaveLength(1);
    expect(events.some((event) => event.topic === "auth.event")).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects already-cancelled and oversized prompt envelopes before emission", async () => {
    let interaction: LoginInteraction | undefined;
    const runtime = runtimeWithLogin(async (value) => {
      interaction = value;
      return new Promise<void>(() => {});
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }));
    const operationId = broker.start("phone", "provider", "api_key").operationId;
    await flushPromises();

    const cancelled = new AbortController();
    cancelled.abort();
    await expect(interaction?.prompt({ type: "text", message: "cancelled", signal: cancelled.signal }))
      .rejects.toMatchObject({ code: "cancelled" });
    await expect(interaction?.prompt({ type: "text", message: "x".repeat(128 * 1_024 - 100) }))
      .rejects.toMatchObject({ code: "conflict" });
    expect(events.some((event) => event.topic === "auth.prompt")).toBe(false);
    broker.cancel("phone", operationId);
  });

  it("contains hostile and synchronous provider failures after exact retirement", async () => {
    const hostile = new Error("provider failure");
    Object.defineProperty(hostile, "message", {
      value: { toString(): string { throw new Error("hostile conversion"); } },
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const hostileBroker = new AuthBroker(
      runtimeWithLogin(() => Promise.reject(hostile)),
      (_client, topic, payload) => events.push({ topic, payload }),
    );
    hostileBroker.start("phone", "provider", "api_key");
    await flushPromises();

    expect(hostileBroker.activeOperationCount).toBe(0);
    expect(events).toEqual([
      expect.objectContaining({
        topic: "auth.completed",
        payload: expect.objectContaining({
          success: false,
          error: "Authentication failed with an unreadable provider error",
        }),
      }),
    ]);

    const throwingBroker = new AuthBroker(runtimeWithLogin(() => {
      throw new Error("synchronous provider failure");
    }), () => {});
    throwingBroker.start("phone", "provider", "api_key");
    await flushPromises();
    expect(throwingBroker.activeOperationCount).toBe(0);
  });

  it("administrative cancellation retires UI but waits for exact provider settlement", async () => {
    const signals: AbortSignal[] = [];
    let settleProvider!: () => void;
    const registry = new GatewayWorkRegistry("epoch", 8);
    const broker = new AuthBroker(runtimeWithLogin(async (interaction) => {
      signals.push(interaction.signal);
      return new Promise<void>((resolve) => { settleProvider = resolve; });
    }), () => {}, () => {}, { workRegistry: registry });
    broker.start("phone", "provider", "api_key");
    await flushPromises();
    expect(registry.size).toBe(1);

    registry.beginDrain();
    await registry.requestCancellation();
    let settled = false;
    const waiting = registry.waitUntilSettled().then(() => { settled = true; });
    await Promise.resolve();
    expect(signals[0]?.aborted).toBe(true);
    expect(broker.activeOperationCount).toBe(0);
    expect(settled).toBe(false);
    settleProvider();
    await waiting;
    expect(() => broker.start("phone", "provider", "api_key")).toThrow(/draining/u);
  });

  it("disconnect detaches delivery while the stable device owner can resume", async () => {
    const signals: AbortSignal[] = [];
    const runtime = runtimeWithLogin(async (interaction) => {
      signals.push(interaction.signal);
      return new Promise<void>(() => {});
    });
    const broker = new AuthBroker(runtime, () => {});
    const first = broker.start("socket-1", "provider", "api_key", runtime, "device").operationId;
    const second = broker.start("socket-1", "provider", "api_key", runtime, "device", undefined, "session:other").operationId;
    await flushPromises();

    broker.detachClient("socket-1");
    expect(broker.activeOperationCount).toBe(2);
    expect(signals).toHaveLength(2);
    expect(signals.every((signal) => !signal.aborted)).toBe(true);
    expect(broker.resume("device", "socket-2", first)).toMatchObject({ state: "active" });
    expect(() => broker.resume("other-device", "socket-2", first)).toThrow(expect.objectContaining({ code: "not_found" }));

    broker.cancelOwner("device");
    expect(broker.activeOperationCount).toBe(0);
    expect(signals.every((signal) => signal.aborted)).toBe(true);
    expect(broker.cancel("device", second)).toBe(false);
  });

  it("recovers the active same-key operation for a fresh command without consuming capacity", async () => {
    const runtime = runtimeWithLogin(async (interaction) => {
      await interaction.prompt({ type: "text", message: "Paste code" });
    });
    const events: Array<{ client: string; topic: string }> = [];
    const broker = new AuthBroker(runtime, (client, topic) => events.push({ client, topic }), () => {}, {
      maximumOperations: 2,
      maximumOperationsPerClient: 1,
    });
    const first = broker.start("socket-1", "provider", "api_key", runtime, "device", "command-1", "global");
    await waitFor(() => events.some((event) => event.topic === "auth.prompt"));
    broker.detachClient("socket-1");

    // A fresh coordinator lost both the operation and command IDs. Repeated
    // begins beyond the per-device limit all recover the one operation.
    for (let attempt = 2; attempt <= 4; attempt++) {
      expect(broker.start(`socket-${attempt}`, "provider", "api_key", runtime, "device", `command-${attempt}`, "global"))
        .toEqual({ operationId: first.operationId, recovered: true });
    }
    expect(broker.activeOperationCount).toBe(1);
    expect(events.filter((event) => event.client === "socket-4" && event.topic === "auth.prompt")).toHaveLength(1);
    // The recovery receipt is idempotent too.
    expect(broker.start("socket-5", "provider", "api_key", runtime, "device", "command-3", "global"))
      .toEqual({ operationId: first.operationId, recovered: true });

    // Distinct owners, targets, providers, and auth methods never recover it.
    const isolated = [
      broker.start("tablet", "provider", "api_key", runtime, "tablet", "command-t", "global"),
    ];
    expect(isolated[0]).toMatchObject({ recovered: false });
    expect(() => broker.start("socket-6", "provider", "api_key", runtime, "device", "command-6", "session:s"))
      .toThrow(expect.objectContaining({ code: "busy" }));
    broker.cancelOwner("device");
    broker.cancelOwner("tablet");
  });

  it("restarts only the exact recovered operation and starts the successor after the predecessor settles", async () => {
    const pending: Array<{ signal: AbortSignal; settle: () => void }> = [];
    const runtime = runtimeWithLogin(async (interaction) => {
      await new Promise<void>((_resolve, reject) => pending.push({
        signal: interaction.signal,
        settle: () => reject(new Error("aborted")),
      }));
    });
    const events: Array<{ client: string; topic: string; payload: JsonValue }> = [];
    const registry = new GatewayWorkRegistry("epoch", 8);
    const broker = new AuthBroker(runtime, (client, topic, payload) => events.push({ client, topic, payload }), () => {}, {
      maximumOperationsPerClient: 1,
      workRegistry: registry,
    });
    const first = broker.start("socket-1", "provider", "api_key", runtime, "device", "command-1").operationId;
    await waitFor(() => pending.length === 1);

    expect(() => broker.start("socket-2", "provider", "api_key", runtime, "other", "command-x", "global", first))
      .toThrow(expect.objectContaining({ code: "not_found" }));
    expect(() => broker.start("socket-2", "provider", "oauth", runtime, "device", "command-y", "global", first))
      .toThrow(expect.objectContaining({ code: "conflict" }));
    expect(pending[0]!.signal.aborted).toBe(false);

    const restart = broker.start("socket-2", "provider", "api_key", runtime, "device", "command-2", "global", first);
    expect(restart.recovered).toBe(false);
    expect(restart.operationId).not.toBe(first);
    expect(pending[0]!.signal.aborted).toBe(true);
    // An uncertain restart retry returns the same successor instead of
    // replacing it, and the retired predecessor still owns its drain work.
    expect(broker.start("socket-2", "provider", "api_key", runtime, "device", "command-2", "global", first)).toEqual(restart);
    expect(() => broker.start("socket-2", "provider", "api_key", runtime, "device", "command-2", "global"))
      .toThrow(expect.objectContaining({ code: "conflict" }));
    await flushPromises();
    expect(pending).toHaveLength(1);
    expect(registry.size).toBe(2);

    pending[0]!.settle();
    await waitFor(() => pending.length === 2);
    expect(registry.size).toBe(1);
    expect(broker.resume("device", "socket-2", first)).toMatchObject({ state: "cancelled" });

    // A stale replacement ID recovers the current successor rather than restarting it.
    expect(broker.start("socket-3", "provider", "api_key", runtime, "device", "command-3", "global", first))
      .toEqual({ operationId: restart.operationId, recovered: true });
    expect(pending[1]!.signal.aborted).toBe(false);
    broker.cancelOwner("device");
  });

  it("fails a successor whose predecessor never settles while keeping the predecessor accounted", async () => {
    const runtime = runtimeWithLogin(async () => new Promise<void>(() => {}));
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const registry = new GatewayWorkRegistry("epoch", 8);
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }), () => {}, {
      predecessorSettleTimeoutMs: 20,
      workRegistry: registry,
    });
    const first = broker.start("phone", "provider", "api_key").operationId;
    await flushPromises();
    const successor = broker.start("phone", "provider", "api_key", runtime, "phone", "command-2", "global", first).operationId;

    await waitFor(() => events.some((event) => event.topic === "auth.completed"));
    expect(events.find((event) => event.topic === "auth.completed")?.payload).toMatchObject({
      operationId: successor,
      success: false,
      error: expect.stringMatching(/still finishing/u),
    });
    expect(broker.activeOperationCount).toBe(0);
    expect(registry.size).toBe(1);
  });

  it("projects a credential Pi committed before cancellation as a truthful late success", async () => {
    let commit!: () => void;
    const runtime = runtimeWithLogin(async () => new Promise<void>((resolve) => { commit = resolve; }));
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broadcasts: string[] = [];
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }), (topic) => broadcasts.push(topic));
    const operationId = broker.start("phone", "provider", "api_key").operationId;
    await waitFor(() => commit !== undefined);
    expect(broker.cancel("phone", operationId)).toBe(true);
    expect(broker.resume("phone", "phone", operationId)).toMatchObject({ state: "cancelled" });

    // The fixture resolves as Pi does once its credential mutation started.
    commit();
    await flushPromises();
    expect(broadcasts).toEqual(["providers.changed"]);
    expect(events.filter((event) => event.topic === "auth.completed")).toEqual([
      expect.objectContaining({ payload: expect.objectContaining({ operationId, success: true }) }),
    ]);
    expect(broker.resume("phone", "phone", operationId)).toMatchObject({ state: "completed", success: true });
  });

  it("withholds a callback capture whose fixed port another active login owns", async () => {
    const runtime = runtimeWithLogin(async (interaction) => {
      interaction.notify({
        type: "auth_url",
        url: "https://auth.example.invalid/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A53682%2Fcallback&state=synthetic",
      });
      await new Promise<void>(() => {});
    });
    const events: Array<{ client: string; topic: string; payload: JsonValue }> = [];
    const broker = new AuthBroker(runtime, (client, topic, payload) => events.push({ client, topic, payload }));
    broker.start("phone", "provider", "api_key", runtime, "phone");
    broker.start("tablet", "provider", "api_key", runtime, "tablet");
    await waitFor(() => events.filter((event) => event.topic === "auth.event").length === 2);

    const captures = events.map((event) => (event.payload as Record<string, JsonValue>).callbackCapture);
    expect(captures[0]).toMatchObject({ port: 53682 });
    expect(captures[1]).toBeUndefined();
    broker.cancelOwner("phone");
    broker.cancelOwner("tablet");
  });

  it("shows the SDK abort race can release Gateway work before a provider login settles", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-auth-abort-race-"));
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    let finishLogin!: (credential: { refresh: string; access: string; expires: number }) => void;
    let providerSettled = false;
    let markStarted!: () => void;
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    runtime.registerProvider("slow-oauth", {
      name: "Slow OAuth fixture",
      api: "openai-completions",
      baseUrl: "https://example.invalid/v1",
      models: [],
      oauth: {
        login: async () => {
          markStarted();
          try {
            return await new Promise((resolve) => { finishLogin = resolve; });
          } finally {
            providerSettled = true;
          }
        },
        async refreshToken(credentials) { return credentials; },
        getApiKey(credentials) { return credentials.access; },
      },
    });
    const registry = new GatewayWorkRegistry("epoch", 8);
    const broker = new AuthBroker(runtime, () => {}, () => {}, { workRegistry: registry });
    const operationId = broker.start("phone", "slow-oauth", "oauth").operationId;
    await started;

    expect(broker.cancel("phone", operationId)).toBe(true);
    await waitFor(() => registry.size === 0);
    expect(providerSettled).toBe(false);

    finishLogin({ refresh: "synthetic-refresh", access: "synthetic-access", expires: Date.now() + 60_000 });
    await flushPromises();
    expect(providerSettled).toBe(true);
    expect(runtime.isUsingOAuth("slow-oauth")).toBe(false);
  });

  it("settles a signal-ignoring manual-code provider through broker prompt retirement", async () => {
    // Mirrors the selected CortexKit Anthropic login shape: legacy onAuth/onPrompt
    // callbacks through Pi's real OAuth adapter, no signal use, and a code exchange
    // only after the pasted code arrives. The broker owns that prompt, so retiring
    // an abandoned login rejects the exact provider await instead of relying on abort.
    const root = await mkdtemp(join(tmpdir(), "tron-auth-manual-code-"));
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const settlements: Array<"rejected" | "resolved"> = [];
    let finishExchange: ((value: { refresh: string; access: string; expires: number }) => void) | undefined;
    runtime.registerProvider("manual-code-oauth", {
      name: "Manual-code OAuth fixture",
      api: "openai-completions",
      baseUrl: "https://example.invalid/v1",
      models: [],
      oauth: {
        name: "Manual-code OAuth fixture",
        login: async (callbacks) => {
          try {
            callbacks.onAuth({ url: "https://example.invalid/authorize?state=synthetic" });
            await callbacks.onPrompt({ message: "Paste the synthetic code:" });
            const credential = await new Promise<{ refresh: string; access: string; expires: number }>((resolve) => {
              finishExchange = resolve;
            });
            settlements.push("resolved");
            return credential;
          } catch (error) {
            settlements.push("rejected");
            throw error;
          }
        },
        async refreshToken(credentials) { return credentials; },
        getApiKey(credentials) { return credentials.access; },
      },
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const registry = new GatewayWorkRegistry("epoch", 8);
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }), () => {}, { workRegistry: registry });

    const abandoned = broker.start("socket-1", "manual-code-oauth", "oauth", runtime, "device").operationId;
    await waitFor(() => events.some((event) => event.topic === "auth.prompt"));
    broker.detachClient("socket-1");
    expect(broker.cancel("device", abandoned)).toBe(true);
    await waitFor(() => settlements.length === 1 && registry.size === 0);
    expect(settlements).toEqual(["rejected"]);

    // After the code is accepted, the exchange is outside every Gateway-owned
    // boundary. Pi's abort race releases work first, and its credential fence
    // keeps the late result out of canonical storage.
    events.length = 0;
    const exchanging = broker.start("socket-2", "manual-code-oauth", "oauth", runtime, "device").operationId;
    await waitFor(() => events.some((event) => event.topic === "auth.prompt"));
    const prompt = events.find((event) => event.topic === "auth.prompt")!.payload as Record<string, JsonValue>;
    expect(broker.respond("device", exchanging, prompt.promptId as string, "synthetic-code")).toBe(true);
    await waitFor(() => finishExchange !== undefined);
    expect(broker.cancel("device", exchanging)).toBe(true);
    await waitFor(() => registry.size === 0);
    expect(settlements).toEqual(["rejected"]);
    finishExchange!({ refresh: "synthetic-refresh", access: "synthetic-access", expires: Date.now() + 60_000 });
    await flushPromises();
    expect(settlements).toEqual(["rejected", "resolved"]);
    expect(runtime.isUsingOAuth("manual-code-oauth")).toBe(false);
  });

  it("observes callback-listener close before a successor reuses its port", async () => {
    let port = 0;
    let listeningCount = 0;
    let listenerClosed!: () => void;
    const closed = new Promise<void>((resolve) => { listenerClosed = resolve; });
    const runtime = runtimeWithLogin(async (interaction) => {
      const server = createServer();
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(port || 0, "127.0.0.1", () => {
          const address = server.address();
          if (!address || typeof address === "string") return reject(new Error("missing listener address"));
          port = address.port;
          listeningCount += 1;
          resolve();
        });
      });
      const close = () => server.close(() => listenerClosed());
      interaction.signal.addEventListener("abort", close, { once: true });
      await new Promise<void>((resolve, reject) => {
        interaction.signal.addEventListener("abort", () => reject(new Error("cancelled")), { once: true });
      });
    });
    const broker = new AuthBroker(runtime, () => {});
    const first = broker.start("socket-1", "provider", "api_key", runtime, "device").operationId;
    await waitFor(() => port !== 0);

    expect(broker.cancel("device", first)).toBe(true);
    await closed;

    // This tests a cancellation-aware local adapter fixture, not the selected
    // third-party provider whose source is not present in this checkout.
    const second = broker.start("socket-2", "provider", "api_key", runtime, "device").operationId;
    await waitFor(() => listeningCount === 2);
    expect(broker.activeOperationCount).toBe(1);
    broker.cancel("device", second);
    await new Promise<void>((resolve) => setTimeout(resolve, 5));
  });

  it("deduplicates auth.begin by stable owner and command ID", async () => {
    const runtime = runtimeWithLogin(async () => new Promise<void>(() => {}));
    const broker = new AuthBroker(runtime, () => {});
    const first = broker.start("socket-1", "provider", "api_key", runtime, "device", "command-123", "global").operationId;
    const duplicate = broker.start("socket-2", "provider", "api_key", runtime, "device", "command-123", "global").operationId;

    expect(duplicate).toBe(first);
    expect(broker.activeOperationCount).toBe(1);
    expect(() => broker.start("socket-2", "other", "api_key", runtime, "device", "command-123", "global"))
      .toThrow(expect.objectContaining({ code: "conflict" }));
    broker.cancelOwner("device");
  });

  it("relays one exact provider callback without accepting a client-selected destination", async () => {
    let receivedTarget = "";
    let completeCallback!: () => void;
    const callbackReceived = new Promise<void>((resolve) => { completeCallback = resolve; });
    const server = createServer((request, response) => {
      receivedTarget = request.url ?? "";
      response.writeHead(200, { "content-type": "text/plain" });
      response.end("provider response is not projected");
      completeCallback();
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("missing callback port");
    const runtime = runtimeWithLogin(async (interaction) => {
      const redirect = `http://127.0.0.1:${address.port}/oauth/callback`;
      interaction.notify({
        type: "auth_url",
        url: `https://provider.invalid/authorize?redirect_uri=${encodeURIComponent(redirect)}&state=expected`,
      });
      await callbackReceived;
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }));
    const operationId = broker.start("socket", "provider", "api_key", runtime, "device").operationId;
    await waitFor(() => events.some((event) => event.topic === "auth.event"));
    const event = events.find((value) => value.topic === "auth.event")!.payload as Record<string, JsonValue>;
    const capture = event.callbackCapture as Record<string, JsonValue>;

    await expect(broker.forwardCallback("device", operationId, capture.id as string, "code=one&code=two&state=expected"))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(broker.forwardCallback("device", operationId, capture.id as string, "code=one&error=denied&state=expected"))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(broker.forwardCallback("device", operationId, capture.id as string, "code=temporary&state=wrong"))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(broker.forwardCallback("other-device", operationId, capture.id as string, "code=temporary&state=expected"))
      .rejects.toMatchObject({ code: "not_found" });
    await expect(broker.forwardCallback("device", operationId, capture.id as string, "code=temporary&state=expected"))
      .resolves.toBe(true);
    await expect(broker.forwardCallback("device", operationId, capture.id as string, "code=temporary&state=expected"))
      .resolves.toBe(false);
    expect(receivedTarget).toBe("/oauth/callback?code=temporary&state=expected");
    await waitFor(() => events.some((value) => value.topic === "auth.completed"));
    expect(JSON.stringify(events)).not.toContain("provider response is not projected");
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  it("rejects oversized provider projections and releases the operation exactly once", async () => {
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const runtime = runtimeWithLogin(async (interaction) => {
      interaction.notify({ type: "progress", message: "x".repeat(128 * 1_024) });
    });
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }));

    broker.start("phone", "provider", "api_key");
    await flushPromises();

    expect(broker.activeOperationCount).toBe(0);
    expect(events.some((event) => event.topic === "auth.event")).toBe(false);
    expect(events.filter((event) => event.topic === "auth.completed")).toEqual([
      expect.objectContaining({ payload: expect.objectContaining({ success: false }) }),
    ]);
  });

  it("bridges a runtime OAuth authorization and manual prompt without exposing tokens", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-oauth-broker-"));
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    runtime.registerProvider("test-oauth", {
      name: "Test OAuth",
      api: "openai-completions",
      baseUrl: "https://example.invalid/v1",
      models: [{
        id: "test", name: "Test", api: "openai-completions", reasoning: false, input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1_000, maxTokens: 100,
      }],
      oauth: {
        async login(callbacks) {
          callbacks.onAuth({ url: "https://example.invalid/authorize", instructions: "Authorize Tron" });
          const code = await callbacks.onPrompt({ message: "Paste the authorization code" });
          return { refresh: `refresh-${code}`, access: `access-${code}`, expires: Date.now() + 60_000 };
        },
        async refreshToken(credentials) { return credentials; },
        getApiKey(credentials) { return credentials.access; },
      },
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }));
    const operationId = broker.start("phone", "test-oauth", "oauth").operationId;
    await waitFor(() => events.some((event) => event.topic === "auth.prompt"));
    expect(events.some((event) => event.topic === "auth.event")).toBe(true);
    const prompt = events.find((event) => event.topic === "auth.prompt")!.payload as Record<string, JsonValue>;
    broker.respond("phone", operationId, prompt.promptId as string, "temporary-code");
    await waitFor(() => events.some((event) => event.topic === "auth.completed"));

    expect(runtime.isUsingOAuth("test-oauth")).toBe(true);
    expect(JSON.stringify(events)).not.toContain("access-temporary-code");
    expect(JSON.stringify(events)).not.toContain("refresh-temporary-code");
  });
});
