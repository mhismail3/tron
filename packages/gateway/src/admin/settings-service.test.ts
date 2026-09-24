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
    await service.update({ modelContextWindows: { "context-test/large": 1_000_000 }, steeringMode: "all" }, global);
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
    expect(JSON.parse(await readFile(path, "utf8"))).toMatchObject({ steeringMode: "all", modelContextWindows: { "context-test/other/alias": 100_000 } });
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
      branchSummary: { reserveTokens: 8_000 },
      retry: { enabled: true, maxRetries: 4, provider: { timeoutMs: 90_000, maxRetries: 2, maxRetryDelayMs: 10_000 } },
      thinkingBudgets: { minimal: 512, high: 8_192 },
      transport: "websocket",
      steeringMode: "one-at-a-time",
      followUpMode: "all",
      sessionDir: "/tmp/sessions",
      extensions: ["/tmp/extension.ts"],
      packages: [{ source: "npm:test", autoload: false, skills: ["**"] }],
    }, { cwd, scope: "global", projectTrusted: false });

    const document = service.get(cwd, false) as { effective: Record<string, unknown> };
    expect(document.effective.compaction).toEqual({
      enabled: false,
      reserveTokens: 20_000,
      keepRecentTokens: 10_000,
      thinkingLevel: "inherit",
      instructions: "",
      source: { enabled: "global", reserveTokens: "global", keepRecentTokens: "global", thinkingLevel: "default", instructions: "default" },
    });
    expect(document.effective.branchSummary).toEqual({ reserveTokens: 8_000 });
    expect(document.effective.transport).toBe("websocket");
    expect(document.effective.sessionDir).toBe("/tmp/sessions");
    expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"))).toMatchObject({
      extensions: ["/tmp/extension.ts"],
      packages: [{ source: "npm:test", autoload: false, skills: ["**"] }],
    });
  });

  it("neither writes nor projects terminal-only settings that no Tron surface consumes", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-terminal-settings-"));
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const service = new SettingsService(agentDir, models);
    const retired = {
      hideThinkingBlock: true,
      showCacheMissNotices: true,
      enableSkillCommands: false,
      markdown: { codeBlockIndent: "\t", mermaid: "off" },
      warnings: { anthropicExtraUsage: false },
      enableAnalytics: true,
    };
    const document = await service.update({ ...retired, steeringMode: "all" }, { cwd: agentDir, scope: "global", projectTrusted: false }) as { effective: Record<string, unknown> };
    expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"))).toEqual({ steeringMode: "all" });
    for (const key of ["hideThinkingBlock", "showCacheMissNotices", "enableSkillCommands", "markdown", "warnings"]) {
      expect(document.effective).not.toHaveProperty(key);
    }
    expect(document.effective.branchSummary).toEqual({ reserveTokens: 16_384 });
    expect(document.effective.telemetry).toEqual({ install: true });
  });

  it("resolves compaction policy by scope and validates bounded focus instructions", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-settings-policy-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const service = new SettingsService(agentDir, models);
    await service.update({ compaction: { thinkingLevel: "low", instructions: "global focus" } }, { cwd, scope: "global", projectTrusted: false });
    const inherited = service.get(cwd, false) as any;
    expect(inherited.effective.compaction).toMatchObject({ thinkingLevel: "low", instructions: "global focus", source: { thinkingLevel: "global" } });
    await service.update({ compaction: { thinkingLevel: "inherit", instructions: "" } }, { cwd, scope: "project", projectTrusted: true });
    const reset = service.get(cwd, true) as any;
    expect(reset.effective.compaction).toMatchObject({ thinkingLevel: "inherit", instructions: "", source: { thinkingLevel: "project", instructions: "project" } });
    await service.update({ compaction: { thinkingLevel: null, instructions: null } }, { cwd, scope: "project", projectTrusted: true });
    expect((service.get(cwd, true) as any).effective.compaction).toMatchObject({ thinkingLevel: "low", instructions: "global focus", source: { thinkingLevel: "global" } });
    await service.update({ compaction: { thinkingLevel: "high", instructions: "changed global focus" } }, { cwd, scope: "global", projectTrusted: false });
    expect((service.get(cwd, true) as any).effective.compaction).toMatchObject({ thinkingLevel: "high", instructions: "changed global focus", source: { thinkingLevel: "global", instructions: "global" } });
    await expect(service.update({ compaction: { instructions: "x".repeat(4_001) } }, { cwd, scope: "global", projectTrusted: false })).rejects.toThrow(/4000/);
    await expect(service.update({ compaction: { thinkingLevel: "low" } }, { cwd, scope: "project", projectTrusted: false })).rejects.toMatchObject({ code: "trust_required" });
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

  it("rejects unrelated writes before committing malformed compaction settings", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "tron-invalid-compaction-write-"));
    const cwd = join(agentDir, "project");
    await mkdir(cwd);
    const models = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const service = new SettingsService(agentDir, models);
    const settingsPath = join(agentDir, "settings.json");
    const original = JSON.stringify({ compaction: { thinkingLevel: "not-a-level" }, marker: "preserve" });
    await writeFile(settingsPath, original);

    await expect(service.update(
      { steeringMode: "all" },
      { cwd, scope: "global", projectTrusted: false },
    )).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(settingsPath, "utf8")).toBe(original);

    const projectPath = join(cwd, ".pi");
    await mkdir(projectPath);
    const projectOriginal = JSON.stringify({ marker: "project" });
    await writeFile(join(projectPath, "settings.json"), projectOriginal);
    await expect(service.update(
      { steeringMode: "all" },
      { cwd, scope: "project", projectTrusted: true },
    )).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(projectPath, "settings.json"), "utf8")).toBe(projectOriginal);

    await service.update({ compaction: { thinkingLevel: "inherit" } }, { cwd, scope: "global", projectTrusted: false });
    const invalidProject = JSON.stringify({ compaction: { keepRecentTokens: -1 }, marker: "project" });
    await writeFile(join(projectPath, "settings.json"), invalidProject);
    await expect(service.update({ steeringMode: "all" }, { cwd, scope: "project", projectTrusted: true }))
      .rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(projectPath, "settings.json"), "utf8")).toBe(invalidProject);

    await writeFile(settingsPath, '{"compaction":');
    await writeFile(join(projectPath, "settings.json"), projectOriginal);
    await expect(service.update({ steeringMode: "all" }, { cwd, scope: "project", projectTrusted: true }))
      .rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(projectPath, "settings.json"), "utf8")).toBe(projectOriginal);
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
      { steeringMode: "all" },
      { cwd, scope: "global", projectTrusted: false },
    )).rejects.toThrow(/collection limit/);
    expect(await readFile(settingsPath, "utf8")).toBe(original);

    const exactMembers = Object.fromEntries(Array.from({ length: 999 }, (_, index) => [`unknown-${index}`, index]));
    await writeFile(settingsPath, JSON.stringify(exactMembers));
    await expect(service.update(
      { steeringMode: "all" },
      { cwd, scope: "global", projectTrusted: false },
    )).resolves.toBeDefined();
    const admitted = JSON.parse(await readFile(settingsPath, "utf8")) as Record<string, unknown>;
    expect(Object.keys(admitted)).toHaveLength(1_000);
    expect(admitted["unknown-998"]).toBe(998);
    expect(admitted.steeringMode).toBe("all");

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
