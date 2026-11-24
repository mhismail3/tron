import { mkdir, mkdtemp, realpath, rm, symlink, utimes, writeFile } from "node:fs/promises";
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

async function page(root: string, name: string, html: string, at?: string): Promise<void> {
  await mkdir(join(root, name), { recursive: true });
  await writeFile(join(root, name, "index.html"), html);
  if (at) for (const path of [join(root, name, "index.html"), join(root, name)]) await utimes(path, new Date(at), new Date(at));
}

it("lists tools by last update and dated reports newest first, titled from their pages, with tailnet URLs", async () => {
  const { modules, list, workspace } = await gateway("mac.example.ts.net");
  try {
    expect(await list(), "no folders yet").toEqual({ tools: [], reports: [] });
    const artifacts = join(await workspace(), "artifacts"), reports = join(await workspace(), "reports");
    await page(artifacts, "ios-dev-builds", "<html><head><title>\n  Tron iOS &amp; builds&#x21; </title>", "2026-11-20T10:00:00Z");
    await page(artifacts, "status", "<p>no title</p>", "2026-11-22T08:00:00Z");
    await page(artifacts, "shared", "<title>styles</title>");
    await mkdir(join(artifacts, "no-entry-page"));
    await writeFile(join(artifacts, "loose.html"), "loose");
    await page(join(await workspace(), "elsewhere"), "outside", "<title>outside</title>");
    await symlink(join(await workspace(), "elsewhere", "outside"), join(artifacts, "linked"));
    await page(reports, "2026-11-21_release-notes", "<title>Release notes</title>", "2026-11-21T09:00:00Z");
    await page(reports, "2026-11-23_morning", "<title>Morning</title>", "2026-11-23T08:00:00Z");
    await page(reports, "2026-11-23_evening", "<title>Evening</title>", "2026-11-23T20:00:00Z");
    await page(reports, "undated", "<title>Undated</title>");
    await mkdir(join(reports, "2026-11-22_no-entry-page"));
    await symlink(join(await workspace(), "elsewhere", "outside"), join(reports, "2026-11-24_linked"));
    const base = "https://mac.example.ts.net:8443";
    expect(await list()).toEqual({
      tools: [
        { name: "status", title: "status", updatedAt: "2026-11-22T08:00:00.000Z", url: `${base}/artifacts/status/` },
        { name: "ios-dev-builds", title: "Tron iOS & builds!", updatedAt: "2026-11-20T10:00:00.000Z", url: `${base}/artifacts/ios-dev-builds/` },
      ],
      reports: [
        { name: "2026-11-23_evening", day: "2026-11-23", title: "Evening", updatedAt: "2026-11-23T20:00:00.000Z", url: `${base}/reports/2026-11-23_evening/` },
        { name: "2026-11-23_morning", day: "2026-11-23", title: "Morning", updatedAt: "2026-11-23T08:00:00.000Z", url: `${base}/reports/2026-11-23_morning/` },
        { name: "2026-11-21_release-notes", day: "2026-11-21", title: "Release notes", updatedAt: "2026-11-21T09:00:00.000Z", url: `${base}/reports/2026-11-21_release-notes/` },
      ],
    });
    await expect(modules.rpc("artifacts.list")!.handle({ filter: "x" }, { identity: "test", isLocal: true })).rejects.toThrow("unknown fields");
  } finally { await modules.stop(); }
});

it("refuses to invent a URL when this Mac has no tailnet name", async () => {
  const { modules, list, workspace } = await gateway(undefined);
  try {
    expect(await list()).toEqual({ tools: [], reports: [] });
    await page(join(await workspace(), "reports"), "2026-11-23_report", "<title>Report</title>");
    await expect(list()).rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("Tailscale is not connected") });
  } finally { await modules.stop(); }
});
