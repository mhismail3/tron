import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { ModuleHost } from "../../kernel/host/module-host.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { createArtifactsModule } from "./module.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

async function gateway(host: string | undefined) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-artifacts-")));
  roots.push(root);
  const modules = await ModuleHost.start([workspaceModule, createArtifactsModule(async () => host)], { tronHome: join(root, "tron"), log: { log: () => {} } }, []);
  const list = () => modules.rpc("artifacts.list")!.handle({}, { identity: "test", isLocal: true });
  return { modules, list, workspace: async () => (await modules.contract(workspaceModule).describe()).root };
}

async function page(root: string, name: string): Promise<void> {
  await mkdir(join(root, name), { recursive: true });
  await writeFile(join(root, name, "index.html"), `<title>${name}</title>`);
}

it("lists dated artifact pages newest first with their tailnet share-host URLs", async () => {
  const { modules, list, workspace } = await gateway("mac.example.ts.net");
  try {
    expect(await list(), "no artifacts folder yet").toEqual({ artifacts: [] });
    const root = join(await workspace(), "artifacts");
    for (const name of ["2026-11-02_status-dashboard", "2026-11-20_release-guide", "2026-11-20_a", "shared", "notes"]) await page(root, name);
    await mkdir(join(root, "2026-11-21_no-entry-page"));
    await writeFile(join(root, "2026-11-22_loose-file.html"), "loose");
    await page(join(await workspace(), "elsewhere"), "outside");
    await symlink(join(await workspace(), "elsewhere", "outside"), join(root, "2026-11-23_linked"));
    expect(await list()).toEqual({ artifacts: [
      { name: "2026-11-20_release-guide", url: "https://mac.example.ts.net:8443/artifacts/2026-11-20_release-guide/" },
      { name: "2026-11-20_a", url: "https://mac.example.ts.net:8443/artifacts/2026-11-20_a/" },
      { name: "2026-11-02_status-dashboard", url: "https://mac.example.ts.net:8443/artifacts/2026-11-02_status-dashboard/" },
    ] });
    await expect(modules.rpc("artifacts.list")!.handle({ filter: "x" }, { identity: "test", isLocal: true })).rejects.toThrow("unknown fields");
  } finally { await modules.stop(); }
});

it("refuses to invent a URL when this Mac has no tailnet name", async () => {
  const { modules, list, workspace } = await gateway(undefined);
  try {
    expect(await list()).toEqual({ artifacts: [] });
    await page(join(await workspace(), "artifacts"), "2026-11-23_report");
    await expect(list()).rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("Tailscale is not connected") });
  } finally { await modules.stop(); }
});
