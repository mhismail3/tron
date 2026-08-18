import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsService } from "./settings-service.js";

describe("SettingsService", () => {
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
