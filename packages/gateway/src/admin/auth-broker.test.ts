import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import type { JsonValue } from "../protocol/types.js";
import { AuthBroker } from "./auth-broker.js";

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("auth event timed out");
}

describe("AuthBroker", () => {
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
