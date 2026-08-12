import { mkdtemp, mkdir, readFile } from "node:fs/promises";
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
