import { describe, expect, it } from "vitest";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  MAX_SUBAGENTS,
  collectSubagents,
  loadSubagentCatalog,
  subagentDistribution,
  type AvailableSubagent,
} from "./subagent-catalog.js";

/**
 * Written failure modes (testing policy): a builtin or package agent must be
 * tagged External; a user or project agent must be tagged Local; an unexpected
 * discovery shape must fail soft to an empty list with one bounded diagnostic
 * instead of throwing; a large catalog must stay capped.
 */

async function fixture(configuredPackage = true): Promise<{ agentDir: string; cwd: string; settings: SettingsManager }> {
  const root = await mkdtemp(join(tmpdir(), "tron-subagents-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
  if (configuredPackage) {
    await mkdir(join(agentDir, "npm", "node_modules", "pi-subagents"), { recursive: true });
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: ["npm:pi-subagents"] }));
  }
  const settings = SettingsManager.create(cwd, agentDir, { projectTrusted: true });
  return { agentDir, cwd, settings };
}

describe("subagent distribution", () => {
  it("tags builtin and package agents External and user and project agents Local", () => {
    expect(subagentDistribution("builtin")).toBe("external");
    expect(subagentDistribution("package")).toBe("external");
    expect(subagentDistribution("user")).toBe("local");
    expect(subagentDistribution("project")).toBe("local");
  });

  it("projects every discovery source with its own distribution", () => {
    const discovered = {
      builtin: [{ name: "builtin-agent", description: "shipped", model: "provider/model", thinking: "high" }],
      package: [{ name: "package-agent", source: "package" }],
      user: [{ name: "user-agent", source: "user" }],
      project: [{ name: "project-agent", source: "project" }],
    };
    expect(collectSubagents(discovered)).toEqual<AvailableSubagent[]>([
      { name: "builtin-agent", description: "shipped", model: "provider/model", thinking: "high", source: "builtin", distribution: "external" },
      { name: "package-agent", source: "package", distribution: "external" },
      { name: "user-agent", source: "user", distribution: "local" },
      { name: "project-agent", source: "project", distribution: "local" },
    ]);
  });

  it("lets the more specific scope win a duplicate name", () => {
    const discovered = {
      builtin: [{ name: "worker", source: "builtin" }],
      project: [{ name: "worker", source: "project" }],
    };
    expect(collectSubagents(discovered)).toEqual<AvailableSubagent[]>([
      { name: "worker", source: "project", distribution: "local" },
    ]);
  });

  it("drops disabled agents that discovery still returns", () => {
    const discovered = {
      user: [{ name: "enabled", source: "user" }, { name: "disabled", source: "user", disabled: true }],
    };
    expect(collectSubagents(discovered)).toEqual<AvailableSubagent[]>([
      { name: "enabled", source: "user", distribution: "local" },
    ]);
  });

  it("skips malformed records and unknown sources", () => {
    const discovered = [{ name: "" }, { name: "no-source" }, { source: "user" }, { name: "runtime-only", source: "runtime" }, null, 7];
    expect(collectSubagents(discovered)).toEqual<AvailableSubagent[]>([]);
  });

  it("caps the catalog at the documented maximum", () => {
    const agents = Array.from({ length: MAX_SUBAGENTS + 5 }, (_, index) => ({ name: `agent-${index}`, source: "user" }));
    expect(collectSubagents({ user: agents })).toHaveLength(MAX_SUBAGENTS);
  });
});

describe("subagent discovery", () => {
  it("fails soft when the package is not installed", async () => {
    const { agentDir, cwd, settings } = await fixture(false);
    const catalog = await loadSubagentCatalog({ agentDir, cwd, settingsManager: settings });
    expect(catalog.subagents).toEqual([]);
    expect(catalog.diagnostic).toBeTruthy();
  });

  it("fails soft when loading the package's discovery module throws", async () => {
    const { agentDir, cwd, settings } = await fixture();
    const catalog = await loadSubagentCatalog({
      agentDir,
      cwd,
      settingsManager: settings,
      loadDiscovery: async () => { throw new Error("jiti could not load pi-subagents"); },
    });
    expect(catalog.subagents).toEqual([]);
    expect(catalog.diagnostic).toContain("jiti could not load pi-subagents");
  });

  it("fails soft when the version exposes no discovery export", async () => {
    const { agentDir, cwd, settings } = await fixture();
    const catalog = await loadSubagentCatalog({
      agentDir,
      cwd,
      settingsManager: settings,
      loadDiscovery: async () => ({ registerRuntimeAgent: () => {} }),
    });
    expect(catalog.subagents).toEqual([]);
    expect(catalog.diagnostic).toBeTruthy();
  });

  it("fails soft when discovery itself throws", async () => {
    const { agentDir, cwd, settings } = await fixture();
    const catalog = await loadSubagentCatalog({
      agentDir,
      cwd,
      settingsManager: settings,
      loadDiscovery: async () => ({ discoverAgentsAll: () => { throw new Error("discovery exploded"); } }),
    });
    expect(catalog.subagents).toEqual([]);
    expect(catalog.diagnostic).toContain("discovery exploded");
  });

  it("projects the discovered agents from the package's own discovery", async () => {
    const { agentDir, cwd, settings } = await fixture();
    const catalog = await loadSubagentCatalog({
      agentDir,
      cwd,
      settingsManager: settings,
      loadDiscovery: async () => ({
        discoverAgentsAll: (discoveryCwd: string) => {
          expect(discoveryCwd).toBe(cwd);
          return {
            builtin: [{ name: "explorer", description: "Explore", source: "builtin" }],
            user: [{ name: "worker", description: "Work", model: "provider/model", thinking: "medium", source: "user" }],
          };
        },
      }),
    });
    expect(catalog.diagnostic).toBeUndefined();
    expect(catalog.subagents).toEqual<AvailableSubagent[]>([
      { name: "explorer", description: "Explore", source: "builtin", distribution: "external" },
      { name: "worker", description: "Work", model: "provider/model", thinking: "medium", source: "user", distribution: "local" },
    ]);
  });
});
