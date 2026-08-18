import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { JsonValue } from "../protocol/types.js";
import { AuthBroker } from "./auth-broker.js";

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
    const operationId = broker.start("phone", "anthropic", "api_key");
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
    const operationId = broker.start("phone", "provider", "api_key")
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

    const phone = broker.start("phone", "provider", "api_key");
    expect(() => broker.start("phone", "provider", "api_key")).toThrow(expect.objectContaining({
      code: "busy",
      retryable: true,
    }));
    const tablet = broker.start("tablet", "provider", "api_key");
    expect(() => broker.start("desktop", "provider", "api_key")).toThrow(expect.objectContaining({ code: "busy" }));
    expect(broker.activeOperationCount).toBe(2);

    broker.cancel("phone", phone);
    expect(broker.activeOperationCount).toBe(1);
    const replacement = broker.start("phone", "provider", "api_key");
    expect(broker.activeOperationCount).toBe(2);
    broker.cancel("phone", replacement);
    broker.cancel("tablet", tablet);
    expect(broker.activeOperationCount).toBe(0);
  });

  it("times out providers that ignore abort and ignores their late completion", async () => {
    vi.useFakeTimers();
    let interaction: LoginInteraction | undefined;
    let completeLogin!: () => void;
    const login = new Promise<void>((resolve) => { completeLogin = resolve; });
    const runtime = runtimeWithLogin(async (value) => {
      interaction = value;
      return login;
    });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broker = new AuthBroker(runtime, (_client, topic, payload) => events.push({ topic, payload }), () => {}, {
      operationTimeoutMs: 100,
    });
    const operationId = broker.start("phone", "provider", "api_key");
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
    const operationId = broker.start("phone", "provider", "api_key");
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

  it("disconnect cancellation releases all client capacity even when providers ignore abort", async () => {
    const signals: AbortSignal[] = [];
    const runtime = runtimeWithLogin(async (interaction) => {
      signals.push(interaction.signal);
      return new Promise<void>(() => {});
    });
    const broker = new AuthBroker(runtime, () => {});
    broker.start("phone", "provider", "api_key");
    broker.start("phone", "provider", "api_key");
    await flushPromises();

    broker.cancelClient("phone");
    expect(broker.activeOperationCount).toBe(0);
    expect(signals).toHaveLength(2);
    expect(signals.every((signal) => signal.aborted)).toBe(true);
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
    const operationId = broker.start("phone", "test-oauth", "oauth");
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
