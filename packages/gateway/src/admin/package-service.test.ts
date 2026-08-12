import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TrustService } from "./trust-service.js";
import { PackageService } from "./package-service.js";

describe("PackageService", () => {
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
