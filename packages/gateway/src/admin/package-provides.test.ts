import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DefaultPackageManager, SettingsManager, type Extension, type ResolvedPaths } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import {
  MAX_PROVIDES_NAMES_PER_KIND,
  loadPackageProvides,
  packageProvides,
  providesResourceName,
  type InstalledPackage,
} from "./package-provides.js";
import { TrustService } from "./trust-service.js";

/**
 * Written failure modes (testing policy):
 * 1. With more than one package installed, a package's skills, prompts, themes,
 *    tools or commands could be attributed to a sibling package — or to every
 *    package — making the per-package view lie about what the install brought in.
 * 2. An extension's tools and commands could be dropped or attributed to a
 *    package that does not own them when the package tag is ignored, so an
 *    install appears to provide nothing.
 * 3. pi-subagents' own builtin agents could be attributed to no package, or to a
 *    local directory that merely shares the package name, unless attribution uses
 *    the definition file's location under the installed root.
 * 4. A failed extension load or failed subagent discovery could fail the whole
 *    `packages.list` read, or silently empty the kinds that did resolve.
 * 5. An unbounded package could enlarge the response without a documented cap.
 */

interface FixturePackage {
  directory: string;
  manifest: Record<string, unknown>;
  files: Record<string, string>;
}

async function fixture(packages: FixturePackage[]): Promise<{
  root: string;
  agentDir: string;
  workspace: string;
  entries: InstalledPackage[];
  resources: ResolvedPaths;
  settings: SettingsManager;
  trust: TrustService;
}> {
  const root = await mkdtemp(join(tmpdir(), "tron-package-provides-"));
  const agentDir = join(root, "agent");
  const workspace = join(root, "workspace");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(workspace, { recursive: true })]);
  const sources: string[] = [];
  for (const pkg of packages) {
    const directory = join(root, pkg.directory);
    sources.push(directory);
    const writes: Array<Promise<unknown>> = [
      (async () => {
        await mkdir(directory, { recursive: true });
        await writeFile(join(directory, "package.json"), JSON.stringify({ name: pkg.directory, pi: pkg.manifest }));
      })(),
    ];
    for (const [path, content] of Object.entries(pkg.files)) {
      writes.push((async () => {
        await mkdir(join(directory, path, ".."), { recursive: true });
        await writeFile(join(directory, path), content);
      })());
    }
    await Promise.all(writes);
  }
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: sources }));
  const settings = SettingsManager.create(workspace, agentDir, { projectTrusted: false });
  const manager = new DefaultPackageManager({ cwd: workspace, agentDir, settingsManager: settings });
  return {
    root,
    agentDir,
    workspace,
    entries: manager.listConfiguredPackages(),
    resources: await manager.resolve(async () => "skip"),
    settings,
    trust: new TrustService(agentDir),
  };
}

const skill = (name: string): string => `---\nname: ${name}\ndescription: ${name}\n---\nBody\n`;
const prompt = (name: string): string => `${name} prompt\n`;
const extensionModule = (tool: string, command: string): string =>
  `export default function (pi) {\n  pi.registerTool({ name: "${tool}", label: "${tool}", description: "Probe", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }] }) });\n  pi.registerCommand("${command}", { description: "Probe", handler: async () => {} });\n}\n`;

/** Two installed packages that contribute the same kinds, so cross-attribution
 * is observable: alpha/beta names, each with its own tool and command. */
function twinPackages(): FixturePackage[] {
  return [
    {
      directory: "package-alpha",
      manifest: {
        extensions: ["./extensions/alpha.js"],
        skills: ["./skills"],
        prompts: ["./prompts"],
        themes: ["./themes"],
      },
      files: {
        "extensions/alpha.js": extensionModule("alpha_tool", "alpha-cmd"),
        "skills/alpha-skill/SKILL.md": skill("alpha-skill"),
        "prompts/alpha-prompt.md": prompt("alpha-prompt"),
        "themes/alpha-theme.json": '{"name":"alpha-theme"}',
      },
    },
    {
      directory: "package-beta",
      manifest: {
        extensions: ["./extensions/beta.js"],
        skills: ["./skills"],
        prompts: ["./prompts"],
        themes: ["./themes"],
      },
      files: {
        "extensions/beta.js": extensionModule("beta_tool", "beta-cmd"),
        "skills/beta-skill/SKILL.md": skill("beta-skill"),
        "prompts/beta-prompt.md": prompt("beta-prompt"),
        "themes/beta-theme.json": '{"name":"beta-theme"}',
      },
    },
  ];
}

function providesFor(entries: Array<{ source: string; provides: unknown }>, directory: string) {
  const entry = entries.find((candidate) => candidate.source.endsWith(`/${directory}`));
  expect(entry, `no provides for ${directory}`).toBeDefined();
  return entry!.provides as ReturnType<typeof packageProvides>;
}

describe("package provides attribution", () => {
  it("attributes each package's own skills, prompts and themes and no sibling's", async () => {
    const value = await fixture(twinPackages());
    try {
      const { entries } = await loadPackageProvides({
        agentDir: value.agentDir,
        trust: value.trust,
        cwd: value.workspace,
        settingsManager: value.settings,
        packages: value.entries,
        resources: value.resources,
      });
      const alpha = providesFor(entries, "package-alpha");
      const beta = providesFor(entries, "package-beta");
      expect(alpha.skills).toEqual(["alpha-skill"]);
      expect(alpha.prompts).toEqual(["alpha-prompt"]);
      expect(alpha.themes).toEqual(["alpha-theme"]);
      expect(beta.skills).toEqual(["beta-skill"]);
      expect(beta.prompts).toEqual(["beta-prompt"]);
      expect(beta.themes).toEqual(["beta-theme"]);
    } finally {
      await rm(value.root, { recursive: true, force: true });
    }
  });

  it("attributes each package extension's tools and commands to that package only", async () => {
    const value = await fixture(twinPackages());
    try {
      // A top-level extension in the agent home is nobody's package resource, so
      // its registrations must not be attributed to an installed package either.
      await mkdir(join(value.agentDir, "extensions"), { recursive: true });
      await writeFile(
        join(value.agentDir, "extensions", "local.js"),
        extensionModule("local_tool", "local-cmd"),
      );
      const { entries } = await loadPackageProvides({
        agentDir: value.agentDir,
        trust: value.trust,
        cwd: value.workspace,
        settingsManager: value.settings,
        packages: value.entries,
        resources: value.resources,
      });
      const alpha = providesFor(entries, "package-alpha");
      const beta = providesFor(entries, "package-beta");
      expect(alpha.tools).toEqual(["alpha_tool"]);
      expect(alpha.commands).toEqual(["alpha-cmd"]);
      expect(beta.tools).toEqual(["beta_tool"]);
      expect(beta.commands).toEqual(["beta-cmd"]);
    } finally {
      await rm(value.root, { recursive: true, force: true });
    }
  });

  it("attributes pi-subagents' own agents to the pi-subagents package by definition file location", async () => {
    const value = await fixture([
      {
        directory: "pi-subagents",
        manifest: { extensions: ["./extensions/subagents.js"] },
        files: {
          "extensions/subagents.js": extensionModule("subagent", "subagent-cmd"),
          "agents/explorer.md": "---\nname: explorer\n---\nBody\n",
        },
      },
      {
        directory: "package-beta",
        manifest: { prompts: ["./prompts"] },
        files: { "prompts/beta-prompt.md": prompt("beta-prompt") },
      },
    ]);
    try {
      const subagentsRoot = join(value.root, "pi-subagents");
      const { entries, diagnostic } = await loadPackageProvides({
        agentDir: value.agentDir,
        trust: value.trust,
        cwd: value.workspace,
        settingsManager: value.settings,
        packages: value.entries,
        resources: value.resources,
        // pi-subagents' real discovery attaches the definition file; a user agent
        // outside the package root is Local and belongs to no installed package.
        loadDiscovery: async () => ({
          discoverAgentsAll: () => ({
            builtin: [{ name: "explorer", source: "builtin", filePath: join(subagentsRoot, "agents", "explorer.md") }],
            user: [{ name: "worker", source: "user", filePath: join(value.agentDir, "agents", "worker.md") }],
          }),
        }),
      });
      expect(providesFor(entries, "pi-subagents").subagents).toEqual(["explorer"]);
      expect(providesFor(entries, "package-beta").subagents).toEqual([]);
      expect(diagnostic).toBeUndefined();
    } finally {
      await rm(value.root, { recursive: true, force: true });
    }
  });

  it("keeps the kinds that resolved when the extension load fails, plus one bounded diagnostic", async () => {
    const value = await fixture(twinPackages());
    try {
      const failure = "x".repeat(4_000);
      const { entries, diagnostic } = await loadPackageProvides({
        agentDir: value.agentDir,
        trust: value.trust,
        cwd: value.workspace,
        settingsManager: value.settings,
        packages: value.entries,
        resources: value.resources,
        loadExtensions: async () => { throw new Error(failure); },
      });
      const alpha = providesFor(entries, "package-alpha");
      expect(alpha.skills).toEqual(["alpha-skill"]);
      expect(alpha.prompts).toEqual(["alpha-prompt"]);
      expect(alpha.themes).toEqual(["alpha-theme"]);
      expect(alpha.tools).toEqual([]);
      expect(alpha.commands).toEqual([]);
      expect(diagnostic).toContain("tools and commands are unavailable");
      expect(diagnostic!.length).toBeLessThanOrEqual(513);
      expect(diagnostic!.endsWith("…")).toBe(true);
    } finally {
      await rm(value.root, { recursive: true, force: true });
    }
  });

  it("records a failed extension module without dropping the tools that did load", async () => {
    const value = await fixture([
      {
        directory: "package-alpha",
        manifest: { extensions: ["./extensions/alpha.js", "./extensions/broken.js"], prompts: ["./prompts"] },
        files: {
          "extensions/alpha.js": extensionModule("alpha_tool", "alpha-cmd"),
          "extensions/broken.js": "throw new Error(\"boom at module scope\");\n",
          "prompts/alpha-prompt.md": prompt("alpha-prompt"),
        },
      },
    ]);
    try {
      const { entries, diagnostic } = await loadPackageProvides({
        agentDir: value.agentDir,
        trust: value.trust,
        cwd: value.workspace,
        settingsManager: value.settings,
        packages: value.entries,
        resources: value.resources,
      });
      const alpha = providesFor(entries, "package-alpha");
      expect(alpha.tools).toEqual(["alpha_tool"]);
      expect(alpha.prompts).toEqual(["alpha-prompt"]);
      expect(diagnostic).toContain("1 extension(s) failed to load");
      expect(diagnostic).toContain("boom at module scope");
    } finally {
      await rm(value.root, { recursive: true, force: true });
    }
  });

  it("keeps the other kinds when subagent discovery fails, plus a diagnostic", async () => {
    const value = await fixture([
      { directory: "pi-subagents", manifest: {}, files: {} },
      {
        directory: "package-alpha",
        manifest: { skills: ["./skills"] },
        files: { "skills/alpha-skill/SKILL.md": skill("alpha-skill") },
      },
    ]);
    try {
      const { entries, diagnostic } = await loadPackageProvides({
        agentDir: value.agentDir,
        trust: value.trust,
        cwd: value.workspace,
        settingsManager: value.settings,
        packages: value.entries,
        resources: value.resources,
        loadDiscovery: async () => { throw new Error("jiti could not load pi-subagents"); },
      });
      const alpha = providesFor(entries, "package-alpha");
      expect(alpha.skills).toEqual(["alpha-skill"]);
      expect(alpha.subagents).toEqual([]);
      expect(diagnostic).toContain("jiti could not load pi-subagents");
    } finally {
      await rm(value.root, { recursive: true, force: true });
    }
  });
});

describe("package provides projection", () => {
  const installed: InstalledPackage = { source: "npm:alpha", scope: "user", filtered: false, installedPath: "/packages/alpha" };

  function resources(kind: "skills" | "prompts" | "themes", paths: string[], source = "npm:alpha"): ResolvedPaths {
    const row = (path: string) => ({
      path,
      enabled: true,
      metadata: { source, scope: "user" as const, origin: "package" as const },
    });
    return { extensions: [], skills: [], prompts: [], themes: [], [kind]: paths.map(row) } as ResolvedPaths;
  }

  function extension(source: string, tools: string[], commands: string[]) {
    const path = `${source}/extensions/index.ts`;
    return {
      path,
      resolvedPath: path,
      sourceInfo: { path, source, scope: "user", origin: "package" },
      handlers: new Map(),
      tools: new Map(tools.map((name) => [name, { definition: { name, execute: async () => ({}) }, sourceInfo: {} }])),
      commands: new Map(commands.map((name) => [name, { name, handler: async () => {} }])),
      shortcuts: new Map(),
      messageRenderers: new Map(),
      entryRenderers: new Map(),
    } as unknown as Extension;
  }

  it("derives a skill name from its directory and strips prompt and theme extensions", () => {
    expect(providesResourceName("skills", "/packages/alpha/skills/alpha-skill/SKILL.md")).toBe("alpha-skill");
    expect(providesResourceName("skills", "/packages/alpha/skills/root-skill.md")).toBe("root-skill");
    expect(providesResourceName("prompts", "/packages/alpha/prompts/alpha-prompt.md")).toBe("alpha-prompt");
    expect(providesResourceName("themes", "/packages/alpha/themes/alpha-theme.json")).toBe("alpha-theme");
  });

  it("attributes only the resources whose metadata names that package and scope", () => {
    expect(packageProvides({
      pkg: installed,
      resources: resources("skills", ["/packages/alpha/skills/mine/SKILL.md"], "npm:beta"),
      extensions: [],
      subagents: [],
    }).skills).toEqual([]);
    expect(packageProvides({
      pkg: installed,
      resources: resources("prompts", ["/packages/alpha/prompts/mine.md"]),
      extensions: [extension("npm:beta", ["theirs"], ["theirs-cmd"])],
      subagents: [],
    })).toMatchObject({ prompts: ["mine"], tools: [], commands: [] });
  });

  it("omits resources a package filter disabled and caps every kind", () => {
    const disabled = resources("prompts", ["/packages/alpha/prompts/off.md"]);
    disabled.prompts[0]!.enabled = false;
    const many = resources("prompts", Array.from({ length: MAX_PROVIDES_NAMES_PER_KIND + 5 }, (_, index) => `/packages/alpha/prompts/p-${index}.md`));
    const tools = Array.from({ length: MAX_PROVIDES_NAMES_PER_KIND + 5 }, (_, index) => `tool_${index}`);
    const provides = packageProvides({
      pkg: installed,
      resources: { ...many, prompts: [...disabled.prompts, ...many.prompts] },
      extensions: [extension("npm:alpha", tools, [])],
      subagents: [],
    });
    expect(provides.prompts).not.toContain("off");
    expect(provides.prompts).toHaveLength(MAX_PROVIDES_NAMES_PER_KIND);
    expect(provides.tools).toHaveLength(MAX_PROVIDES_NAMES_PER_KIND);
  });

  it("attributes no subagent to a package that is not installed on disk", () => {
    expect(packageProvides({
      // The package is configured but absent from disk, so it has no installed root.
      pkg: { source: installed.source, scope: installed.scope, filtered: installed.filtered },
      resources: resources("skills", []),
      extensions: [],
      subagents: [{ name: "explorer", source: "builtin", distribution: "external", filePath: "/packages/alpha/agents/explorer.md" }],
    }).subagents).toEqual([]);
  });
});
