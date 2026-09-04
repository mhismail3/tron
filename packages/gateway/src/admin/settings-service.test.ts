import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { SettingsService } from "./settings-service.js";

describe("SettingsService", () => {
  it("merges per-model context preferences by scope and validates before canonical write", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-context-settings-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "context-test", models: [
      { id: "large", contextWindow: 1_050_000 }, { id: "other/alias", contextWindow: 128_000 },
    ] });
    runtime.registerNativeProvider(faux.provider);
    const service = new SettingsService(agentDir, runtime);
    const global = { cwd, scope: "global" as const, projectTrusted: false };
    const project = { cwd, scope: "project" as const, projectTrusted: true };
    await service.update({ modelContextWindows: { "context-test/large": 1_000_000 }, hideThinkingBlock: true }, global);
    await Promise.all([
      service.update({ modelContextWindows: { "context-test/large": 900_000 } }, global),
      service.update({ modelContextWindows: { "context-test/other/alias": 100_000 } }, global),
    ]);
    await service.update({ modelContextWindows: { "context-test/large": 500_000 } }, project);
    expect(service.get(cwd, true)).toMatchObject({ effective: { modelContextWindows: { "context-test/large": 500_000, "context-test/other/alias": 100_000 } } });
    expect(service.get(cwd, false)).toMatchObject({ effective: { modelContextWindows: { "context-test/large": 900_000 } } });
    await service.update({ modelContextWindows: { "context-test/large": null } }, project);
    expect(service.get(cwd, true)).toMatchObject({ effective: { modelContextWindows: { "context-test/large": 900_000 } } });
    const path = join(agentDir, "settings.json");
    const before = await readFile(path, "utf8");
    for (const value of [1_050_001, 1.5, -1, "1000000", 1_024]) {
      await expect(service.update({ modelContextWindows: { "context-test/large": value } }, global)).rejects.toMatchObject({ code: "invalid_request" });
      expect(await readFile(path, "utf8")).toBe(before);
    }
    await expect(service.update({ modelContextWindows: { "missing/model": 100_000 } }, global)).rejects.toMatchObject({ code: "not_found" });
    await expect(service.update({ modelContextWindows: { "context-test/large": 100_000 } }, { ...project, projectTrusted: false })).rejects.toMatchObject({ code: "trust_required" });
    await service.update({ modelContextWindows: { "context-test/large": null } }, global);
    expect(JSON.parse(await readFile(path, "utf8"))).toMatchObject({ hideThinkingBlock: true, modelContextWindows: { "context-test/other/alias": 100_000 } });
  });

  it("projects the same scoped compaction minimum used for context preference writes", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-context-compaction-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(fauxProvider({ provider: "context-test", models: [{ id: "large", contextWindow: 1_050_000 }] }).provider);
    const service = new SettingsService(agentDir, runtime);
    const global = { cwd, scope: "global" as const, projectTrusted: false };
    const project = { cwd, scope: "project" as const, projectTrusted: true };
    await service.update({ compaction: { reserveTokens: 50_000, keepRecentTokens: 30_000 }, modelContextWindows: { "context-test/large": 81_024 } }, global);
    expect(service.get(cwd, false)).toMatchObject({ effective: { contextWindowMinimum: 81_024 } });
    await expect(service.update({ modelContextWindows: { "context-test/large": 81_023 } }, global)).rejects.toMatchObject({ code: "invalid_request" });
    await service.update({ compaction: { keepRecentTokens: 60_000 } }, project);
    expect(service.get(cwd, true)).toMatchObject({ effective: { contextWindowMinimum: 111_024 } });
    await expect(service.update({ modelContextWindows: { "context-test/large": 100_000 } }, project)).rejects.toMatchObject({ code: "invalid_request" });
    await service.update({ modelContextWindows: { "context-test/large": 111_024 } }, project);
    expect(service.get(cwd, false)).toMatchObject({ effective: { contextWindowMinimum: 81_024 } });
  });

  it("validates project-only model budgets against the explicitly scoped runtime", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-project-context-model-"));
    const globalRuntime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const projectRuntime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    projectRuntime.registerNativeProvider(fauxProvider({ provider: "project-model", models: [{ id: "local", contextWindow: 200_000 }] }).provider);
    const service = new SettingsService(agentDir, globalRuntime);
    const patch = { modelContextWindows: { "project-model/local": 150_000 } };
    await expect(service.update(patch, { cwd: agentDir, scope: "global", projectTrusted: false })).rejects.toMatchObject({ code: "not_found" });
    await expect(service.update(patch, { cwd: agentDir, scope: "project", projectTrusted: true, modelRuntime: projectRuntime })).resolves.toMatchObject({ effective: { modelContextWindows: patch.modelContextWindows } });
  });
  it("persists the complete Pi-native mobile projection without replacing unrelated fields", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-settings-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
    const service = new SettingsService(agentDir, models);
    await service.update({
      compaction: { enabled: false, reserveTokens: 20_000, keepRecentTokens: 10_000 },
      branchSummary: { reserveTokens: 8_000, skipPrompt: true },
      retry: { enabled: true, maxRetries: 4, provider: { timeoutMs: 90_000, maxRetries: 2, maxRetryDelayMs: 10_000 } },
      thinkingBudgets: { minimal: 512, high: 8_192 },
      transport: "websocket",
      hideThinkingBlock: true,
      showCacheMissNotices: true,
      steeringMode: "one-at-a-time",
      followUpMode: "all",
      sessionDir: "/tmp/sessions",
      markdown: { codeBlockIndent: "  ", mermaid: "final" },
      warnings: { anthropicExtraUsage: false },
      extensions: ["/tmp/extension.ts"],
      packages: [{ source: "npm:test", autoload: false, skills: ["**"] }],
    }, { cwd, scope: "global", projectTrusted: false });

    const document = service.get(cwd, false) as { effective: Record<string, unknown> };
    expect(document.effective.compaction).toEqual({ enabled: false, reserveTokens: 20_000, keepRecentTokens: 10_000 });
    expect(document.effective.branchSummary).toEqual({ reserveTokens: 8_000, skipPrompt: true });
    expect(document.effective.transport).toBe("websocket");
    expect(document.effective.sessionDir).toBe("/tmp/sessions");
    expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"))).toMatchObject({
      extensions: ["/tmp/extension.ts"],
      packages: [{ source: "npm:test", autoload: false, skills: ["**"] }],
    });
  });

  it("rejects a runtime session-directory change until restart", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-settings-runtime-lock-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const service = new SettingsService(agentDir, models, false);

    await expect(service.update(
      { sessionDir: "/tmp/other-sessions" },
      { cwd, scope: "global", projectTrusted: false },
    )).rejects.toThrow(/restart is required/);
  });

  it("rejects settings that generic JSON projection would silently alter", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-bounded-settings-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const settingsPath = join(agentDir, "settings.json");
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const service = new SettingsService(agentDir, models);

    const oversizedMembers = Object.fromEntries(Array.from({ length: 1_001 }, (_, index) => [`unknown-${index}`, index]));
    const original = `${JSON.stringify(oversizedMembers)}\n`;
    await writeFile(settingsPath, original);
    expect(() => service.get(cwd, false)).toThrow(/collection limit/);
    await expect(service.update(
      { hideThinkingBlock: true },
      { cwd, scope: "global", projectTrusted: false },
    )).rejects.toThrow(/collection limit/);
    expect(await readFile(settingsPath, "utf8")).toBe(original);

    const exactMembers = Object.fromEntries(Array.from({ length: 999 }, (_, index) => [`unknown-${index}`, index]));
    await writeFile(settingsPath, JSON.stringify(exactMembers));
    await expect(service.update(
      { hideThinkingBlock: true },
      { cwd, scope: "global", projectTrusted: false },
    )).resolves.toBeDefined();
    const admitted = JSON.parse(await readFile(settingsPath, "utf8")) as Record<string, unknown>;
    expect(Object.keys(admitted)).toHaveLength(1_000);
    expect(admitted["unknown-998"]).toBe(998);
    expect(admitted.hideThinkingBlock).toBe(true);

    let nested: Record<string, unknown> = { value: true };
    for (let depth = 0; depth < 12; depth += 1) nested = { nested };
    await writeFile(settingsPath, JSON.stringify({ unknown: nested }));
    expect(() => service.get(cwd, false)).toThrow(/depth limit/);

    await writeFile(settingsPath, JSON.stringify({ unknown: "x".repeat(100_001) }));
    expect(() => service.get(cwd, false)).toThrow(/string limit/);
  });

  it("never returns write-only proxy credentials in settings projections", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-proxy-settings-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const service = new SettingsService(agentDir, models);

    const updated = await service.update(
      { httpProxy: "http://proxy.invalid" },
      { cwd, scope: "global", projectTrusted: false },
    ) as { effective: Record<string, unknown>; documents: { global: Record<string, unknown> } };
    await service.update(
      { httpProxy: "http://project-proxy.invalid" },
      { cwd, scope: "project", projectTrusted: true },
    );
    const fetched = service.get(cwd, true) as {
      effective: Record<string, unknown>;
      documents: { global: Record<string, unknown>; project: Record<string, unknown> };
    };

    expect(updated.documents.global).not.toHaveProperty("httpProxy");
    expect(updated.effective).not.toHaveProperty("httpProxy");
    expect(updated.effective.httpProxyConfigured).toBe(true);
    expect(fetched.documents.global).not.toHaveProperty("httpProxy");
    expect(fetched.documents.project).not.toHaveProperty("httpProxy");
    expect(fetched.effective).not.toHaveProperty("httpProxy");
    expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"))).toMatchObject({
      httpProxy: "http://proxy.invalid",
    });
  });

  it("keeps trusted project settings separate from global defaults", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-project-settings-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const service = new SettingsService(agentDir, models);
    await service.update({ steeringMode: "one-at-a-time" }, { cwd, scope: "project", projectTrusted: true });

    const trusted = service.get(cwd, true) as { effective: Record<string, unknown>; documents: { project: Record<string, unknown> } };
    const untrusted = service.get(cwd, false) as { effective: Record<string, unknown>; documents: { project: null } };
    expect(trusted.effective.steeringMode).toBe("one-at-a-time");
    expect(trusted.documents.project).toEqual({ steeringMode: "one-at-a-time" });
    expect(untrusted.documents.project).toBeNull();
    expect(untrusted.effective.steeringMode).toBe("one-at-a-time");
  });
});
