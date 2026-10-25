import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryCredentialStore, fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { admitToolDisplayProjection } from "../display/display-contract.js";
import { projectMessage, projectTranscriptPage } from "../kernel/projection/projection.js";
import { BlobStore } from "../sessions/blob-store.js";

it("projects friendly redacted errors identically through live and persisted real Pi session history", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-error-presentation-"));
  const faux = fauxProvider({ provider: "anthropic", tokensPerSecond: 100_000 });
  const runtime = await ModelRuntime.create({ modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  const settings = SettingsManager.inMemory();
  const loader = new DefaultResourceLoader({ cwd: root, agentDir: root, settingsManager: settings,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true });
  await loader.reload();
  const manager = SessionManager.create(root, root);
  const { session } = await createAgentSession({ cwd: root, agentDir: root, sessionManager: manager,
    modelRuntime: runtime, settingsManager: settings, resourceLoader: loader, model: faux.getModel(), tools: [] });
  const artifacts: unknown[] = [];
  try {
    const cases = [
      ["anthropic", '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_fixture"}', "Anthropic is overloaded", "overloaded"],
      ["openai", '{"error":{"type":"rate_limit_error","message":"Too many requests"}}', "Rate limited by OpenAI", "rate-limit"],
      ["opencode-go", '{"error":{"type":"GoUsageLimitError","message":"Go usage limit exceeded"}}', "Usage limit reached for OpenCode Go", "usage-limit"],
      ["opencode-go", '403 {"error":{"type":"EntitlementError","message":"subscription required"}}', "OpenCode Go requires an active subscription", "entitlement"],
      ["opencode-go", '403 {"error":{"type":"AuthError"}}', "Authentication failed for OpenCode Go", "authentication"],
      ["other", "401 Unauthorized", "Authentication failed for other", "authentication"],
      ["other", "403 Forbidden", "Access denied by other", "forbidden"],
      ["other", "429 Too Many Requests", "Rate limited by other", "rate-limit"],
      ["other", "502 Bad Gateway", "other is temporarily unavailable", "unavailable"],
      ["other", "Connection reset: ECONNRESET", "Could not connect to other", "network"],
      ["other", "Request timed out", "The connection to other timed out", "timeout"],
      ["other", "Request aborted", "Request cancelled", "aborted"],
      ["other", '{"error":{"type":"custom_error","message":"Please try another region"}}', "Please try another region", "unknown"],
      ["other", '{"error":{"message":"Upstream refused","headers":{"x-api-key":"fixturecredential12345","client_secret":"fixturecredential12345","private_key":"fixturecredential12345","secret_key":"fixturecredential12345"}}}', "Upstream refused", "unknown"],
      ["other", "A plain upstream failure", "A plain upstream failure", "unknown"],
      ["other", "Not Found", "The selected model was not found by other", "not-found"],
      ["other", '{"error":{"message":"Failed with Bearer fixturecredential12345","api_key":"fixturecredential12345"}}', "Failed with Bearer [REDACTED]", "unknown"],
    ] as const;
    for (const [provider, errorMessage, message, category] of cases) {
      const raw = { ...fauxAssistantMessage("", { stopReason: "error", errorMessage }), provider, model: "fixture-model" };
      const id = manager.appendMessage(raw);
      const live = projectMessage(admitToolDisplayProjection, id, null, new Date(raw.timestamp).toISOString(), raw, new BlobStore());
      expect(live).toMatchObject({ errorInfo: { message, category } });
      if (provider === "anthropic") expect(live).toMatchObject({ errorInfo: { type: "overloaded_error", requestId: "req_fixture" } });
      artifacts.push(live);
    }
    const reopened = SessionManager.open(manager.getSessionFile()!);
    const history = projectTranscriptPage(admitToolDisplayProjection, reopened, new BlobStore()).items;
    for (const live of artifacts as Array<{ id: string; errorInfo: unknown; errorMessage: string }>) {
      expect(history.find(item => item.id === live.id)).toMatchObject({ errorInfo: live.errorInfo, errorMessage: live.errorMessage });
    }
    expect(JSON.stringify(artifacts)).not.toContain("fixturecredential12345");
    await mkdir("test-results", { recursive: true });
    await writeFile("test-results/provider-error-presentation.json", JSON.stringify({ live: artifacts, history }, null, 2));
  } finally {
    await session.dispose();
    await rm(root, { recursive: true, force: true });
  }
});
