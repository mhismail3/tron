import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { TrustService } from "./trust-service.js";
import {
  PackageService,
  validatePackageInventory,
  validatePackageUpdates,
} from "./package-service.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import type { JsonValue } from "../protocol/types.js";

describe("PackageService", () => {
  it("rejects duplicate, oversized, and truncation-prone projections", () => {
    const resources = {
      extensions: [],
      skills: [],
      prompts: [],
      themes: [],
    };
    expect(() => validatePackageInventory([
      { source: "same", scope: "user", filtered: false },
      { source: "same", scope: "user", filtered: true },
    ], resources)).toThrow(/duplicate identities/);
    expect(() => validatePackageInventory([], {
      ...resources,
      prompts: Array.from({ length: 1_001 }, (_, index) => ({
        path: `/prompt/${index}`,
        enabled: true,
        metadata: { source: "package", scope: "user" as const, origin: "package" as const },
      })),
    })).toThrow(/item limit/);
    expect(() => validatePackageUpdates([
      { source: "same", displayName: "First", type: "git", scope: "user" },
      { source: "same", displayName: "Second", type: "npm", scope: "user" },
    ])).toThrow(/duplicate identities/);
    expect(() => validatePackageUpdates([
      { source: "x".repeat(8_193), displayName: "Large", type: "git", scope: "user" },
    ])).toThrow(/oversized/);
  });

  it("installs and removes a local runtime package through native package settings", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    const packageDir = join(root, "sample-package");
    await Promise.all([mkdir(agentDir), mkdir(workspace), mkdir(packageDir)]);
    await writeFile(join(packageDir, "package.json"), `${JSON.stringify({ name: "sample", pi: { prompts: [] } })}\n`);
    const events: string[] = [];
    const registry = new GatewayWorkRegistry("epoch", 8);
    const service = new PackageService(agentDir, new TrustService(agentDir), (topic) => events.push(topic), registry);

    await service.mutate("install", packageDir, workspace, false);
    const listing = service.list(workspace);
    expect(registry.size).toBe(1);
    expect(JSON.stringify(await listing)).toContain(packageDir);
    expect(registry.size).toBe(0);
    expect(events).toContain("packages.completed");

    await service.mutate("remove", packageDir, workspace, false);
    expect(JSON.stringify(await service.list(workspace))).not.toContain(packageDir);
    expect(registry.size).toBe(0);
    registry.beginDrain();
    await expect(service.mutate("install", packageDir, workspace, false)).rejects.toMatchObject({ code: "busy" });
    await expect(service.list(workspace)).rejects.toMatchObject({ code: "busy" });
    await expect(service.checkUpdates(workspace)).rejects.toMatchObject({ code: "busy" });
  });

  it.each(["tilde", "file-url"])("preserves SDK-supported %s local source resolution", async (kind) => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-path-"));
    const workspace = join(root, "workspace"), agentDir = join(root, "agent"), packageDir = join(root, "local-package");
    await Promise.all([mkdir(workspace), mkdir(agentDir), mkdir(packageDir)]);
    await writeFile(join(packageDir, "package.json"), JSON.stringify({ name: "fixture", pi: { prompts: [] } }));
    vi.stubEnv("HOME", root);
    try {
      const service = new PackageService(agentDir, new TrustService(agentDir), () => {});
      const source = kind === "tilde" ? "~/local-package" : pathToFileURL(packageDir).href;
      await expect(service.mutate("install", source, workspace, false)).resolves.toMatchObject({ operationId: expect.any(String) });
      expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8")).packages).toHaveLength(1);
    } finally {
      vi.unstubAllEnvs();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("fails closed on malformed canonical settings before package inspection", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-malformed-packages-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(workspace)]);
    await writeFile(join(agentDir, "settings.json"), "{malformed\n");
    const service = new PackageService(agentDir, new TrustService(agentDir), () => {});

    await expect(service.list(workspace)).rejects.toMatchObject({ code: "conflict" });
    await expect(service.checkUpdates(workspace)).rejects.toMatchObject({ code: "conflict" });
    await expect(service.mutate("install", join(root, "missing"), workspace, false)).rejects.toMatchObject({ code: "conflict" });
  });

  it("does not report success until package settings are durable", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-persist-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    const packageDir = join(root, "sample-package");
    await Promise.all([mkdir(agentDir), mkdir(workspace), mkdir(packageDir)]);
    await writeFile(join(packageDir, "package.json"), `${JSON.stringify({ name: "sample" })}\n`);
    await writeFile(join(agentDir, "settings.json"), "{}\n");
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const service = new PackageService(agentDir, new TrustService(agentDir), (topic, payload) => events.push({ topic, payload }));
    await chmod(agentDir, 0o555);
    try {
      await expect(service.mutate("install", packageDir, workspace, false)).rejects.toMatchObject({ code: "EACCES" });
    } finally {
      await chmod(agentDir, 0o755);
    }
    const completion = events.find((event) => event.topic === "packages.completed");
    expect(completion?.payload).toMatchObject({ success: false });
    expect(JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"))).not.toHaveProperty("packages");
  });

  it("keeps a missing local package preflight retryable", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-preflight-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(workspace)]);
    const service = new PackageService(agentDir, new TrustService(agentDir), () => {});

    await expect(service.mutate("install", join(root, "missing-package"), workspace, false)).rejects.toMatchObject({
      code: "not_found",
      details: undefined,
    });
  });

  it("fences a package mutation when an SDK install applies an effect before failing", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-partial-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    const marker = join(root, "side-effect.marker");
    const npm = join(root, "partial-npm.sh");
    await Promise.all([mkdir(agentDir), mkdir(workspace)]);
    await writeFile(npm, `#!/bin/sh\nprintf '%s\\n' side-effect >> ${JSON.stringify(marker)}\nexit 17\n`);
    await chmod(npm, 0o755);
    await writeFile(join(agentDir, "settings.json"), `${JSON.stringify({ npmCommand: [npm] })}\n`);
    const service = new PackageService(agentDir, new TrustService(agentDir), () => {});

    await expect(service.mutate("install", "npm:partial-package", workspace, false)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    expect((await readFile(marker, "utf8")).trim()).toBe("side-effect");
  });

  it("reports an unknown outcome when the package applied but its settings could not be persisted", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-uncertain-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    const packageDir = join(root, "sample-package");
    await Promise.all([mkdir(agentDir), mkdir(workspace), mkdir(packageDir)]);
    await writeFile(join(packageDir, "package.json"), `${JSON.stringify({ name: "sample" })}\n`);
    const settingsPath = join(agentDir, "settings.json");
    await writeFile(settingsPath, "{}\n");
    const service = new PackageService(agentDir, new TrustService(agentDir), () => {});
    // The local install itself succeeds; only the canonical settings write is
    // blocked, so the package change has landed without a durable record.
    await chmod(settingsPath, 0o444);
    try {
      await expect(service.mutate("install", packageDir, workspace, false)).rejects.toMatchObject({
        code: "conflict",
        details: { outcomeUnknown: true },
      });
    } finally {
      await chmod(settingsPath, 0o644);
    }
    expect(JSON.parse(await readFile(settingsPath, "utf8"))).not.toHaveProperty("packages");
  });

  it("updates only the requested package scope", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-scope-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    const logPath = join(root, "npm.log");
    await Promise.all([mkdir(agentDir), mkdir(workspace)]);
    const npm = join(root, "fake-npm.sh");
    await writeFile(npm, `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(logPath)}\n`);
    await chmod(npm, 0o755);
    await writeFile(join(agentDir, "settings.json"), `${JSON.stringify({ packages: ["npm:sample-package"] })}\n`);
    await mkdir(join(workspace, ".pi"));
    await writeFile(join(workspace, ".pi", "settings.json"), `${JSON.stringify({ packages: ["npm:sample-package"] })}\n`);
    // npmCommand is an explicit SDK setting, so the fixture performs no network
    // operation and proves the selected scope reaches the package owner.
    await writeFile(join(agentDir, "settings.json"), `${JSON.stringify({ npmCommand: [npm], packages: ["npm:sample-package"] })}\n`);
    const service = new PackageService(agentDir, new TrustService(agentDir), () => {});

    await service.mutate("update", "npm:sample-package", workspace, false);
    const calls = (await readFile(logPath, "utf8")).trim().split("\n").filter(Boolean);
    const installs = calls.filter((call) => call.includes("--prefix"));
    expect(installs).toHaveLength(1);
    expect(installs[0]).toContain(`--prefix ${join(agentDir, "npm")}`);
    expect(installs[0]).not.toContain(`${workspace}/.pi`);
  });

  it("projects canonical global packages even when the current project is untrusted", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-global-packages-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    const packageDir = join(root, "global-package");
    await Promise.all([mkdir(agentDir), mkdir(workspace), mkdir(packageDir)]);
    await writeFile(join(packageDir, "package.json"), `${JSON.stringify({ name: "global", pi: { prompts: ["prompt.md"] } })}\n`);
    await writeFile(join(packageDir, "prompt.md"), "# Prompt\n");
    await writeFile(join(agentDir, "settings.json"), `${JSON.stringify({ packages: [packageDir] })}\n`);

    const inventory = await new PackageService(agentDir, new TrustService(agentDir), () => {}).list(workspace);
    expect(inventory).toMatchObject({
      packages: [{ source: packageDir, scope: "user", filtered: false }],
    });
    expect(JSON.stringify(inventory)).toContain("prompt.md");
  });

  it("reports what each installed package provides without failing on an empty kind", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-provides-"));
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    const packageDir = join(root, "sample-package");
    await Promise.all([
      mkdir(agentDir),
      mkdir(workspace),
      mkdir(join(packageDir, "extensions"), { recursive: true }),
      mkdir(join(packageDir, "skills", "sample-skill"), { recursive: true }),
      mkdir(join(packageDir, "prompts"), { recursive: true }),
    ]);
    await writeFile(join(packageDir, "package.json"), `${JSON.stringify({
      name: "sample",
      pi: { extensions: ["./extensions/sample.js"], skills: ["./skills"], prompts: ["./prompts"] },
    })}\n`);
    await writeFile(join(packageDir, "extensions", "sample.js"), `export default function (pi) {\n  pi.registerTool({ name: "sample_tool", label: "Sample", description: "Probe", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }] }) });\n  pi.registerCommand("sample-cmd", { description: "Probe", handler: async () => {} });\n}\n`);
    await writeFile(join(packageDir, "skills", "sample-skill", "SKILL.md"), "---\nname: sample-skill\ndescription: Sample\n---\nBody\n");
    await writeFile(join(packageDir, "prompts", "sample-prompt.md"), "Sample prompt\n");
    const registry = new GatewayWorkRegistry("epoch", 8);
    const service = new PackageService(agentDir, new TrustService(agentDir), () => {}, registry);
    await service.mutate("install", packageDir, workspace, false);

    const inventory = await service.list(workspace) as {
      packages: Array<{ source: string; provides: Record<string, string[]> }>;
      providesDiagnostic?: string;
    };
    // Pi stores an installed local source relative to its settings base, so the
    // listing matches the single installed package rather than a raw path.
    expect(inventory.packages).toHaveLength(1);
    expect(inventory.packages[0]!.provides).toEqual({
      skills: ["sample-skill"],
      prompts: ["sample-prompt"],
      themes: [],
      subagents: [],
      tools: ["sample_tool"],
      commands: ["sample-cmd"],
    });
    // pi-subagents is not installed in this fixture: the read reports why the
    // subagent kind is empty instead of failing.
    expect(inventory.providesDiagnostic).toContain("pi-subagents is not installed");
    expect(registry.size).toBe(0);
  });
});
