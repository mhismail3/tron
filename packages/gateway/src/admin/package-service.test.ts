import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TrustService } from "./trust-service.js";
import {
  PackageService,
  validatePackageInventory,
  validatePackageUpdates,
} from "./package-service.js";

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
    const service = new PackageService(agentDir, new TrustService(agentDir), (topic) => events.push(topic));

    await service.mutate("install", packageDir, workspace, false);
    expect(JSON.stringify(await service.list(workspace))).toContain(packageDir);
    expect(events).toContain("packages.completed");

    await service.mutate("remove", packageDir, workspace, false);
    expect(JSON.stringify(await service.list(workspace))).not.toContain(packageDir);
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
});
