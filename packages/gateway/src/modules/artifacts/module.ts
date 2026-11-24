import { constants } from "node:fs";
import { lstat, open, readdir } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import { readTailscaleStatus, runBoundedCommand } from "../../platform/tailscale-status.js";
import { rejectUnknownFields } from "../../util/validation.js";
import { workspaceModule } from "../../workspace/workspace-module.js";

const SLUG = "[A-Za-z0-9][A-Za-z0-9._-]{0,120}";
const TOOL_NAME = new RegExp(`^${SLUG}$`, "u");
const REPORT_NAME = new RegExp(`^\\d{4}-\\d{2}-\\d{2}_${SLUG}$`, "u");
const SHARE_HOST_PORT = 8443;
const MAXIMUM_LISTED = 500;
const TITLE_BYTES = 16_384;
const BATCH = 32;
const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };

interface Page { name: string; title: string; updated: number }

async function tailnetName(): Promise<string | undefined> {
  const read = await readTailscaleStatus(runBoundedCommand, 5_000);
  return read.ok ? read.status.selfDNSName?.replace(/\.$/u, "") : undefined;
}

function decode(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/giu, (entity, body: string) => {
    if (body[0] !== "#") return ENTITIES[body.toLowerCase()] ?? entity;
    const code = Number.parseInt(body.slice(body[1] === "x" || body[1] === "X" ? 2 : 1), body[1] === "x" || body[1] === "X" ? 16 : 10);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
  });
}

async function title(path: string): Promise<string | undefined> {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW).catch(() => undefined);
  if (!handle) return undefined;
  try {
    const buffer = Buffer.alloc(TITLE_BYTES);
    const { bytesRead } = await handle.read(buffer, 0, TITLE_BYTES, 0);
    const match = /<title[^>]*>([^<]*)<\/title>/iu.exec(buffer.toString("utf8", 0, bytesRead));
    return match ? decode(match[1]!).replace(/\s+/gu, " ").trim().slice(0, 200) || undefined : undefined;
  } finally { await handle.close(); }
}

async function batched<T, R>(items: T[], read: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = [];
  for (let start = 0; start < items.length; start += BATCH) results.push(...await Promise.all(items.slice(start, start + BATCH).map(read)));
  return results;
}

async function pages(root: string, pattern: RegExp, order: (a: Page, b: Page) => number): Promise<Page[]> {
  const info = await lstat(root).catch(() => undefined);
  if (!info?.isDirectory()) return [];
  const names = (await readdir(root)).filter(name => name !== "shared" && pattern.test(name));
  const found = (await batched(names, async (name): Promise<Page | undefined> => {
    const [folder, index] = await Promise.all([lstat(join(root, name)), lstat(join(root, name, "index.html"))].map(entry => entry.catch(() => undefined)));
    if (!folder?.isDirectory() || !index?.isFile()) return undefined;
    return { name, title: name, updated: Math.max(folder.mtimeMs, index.mtimeMs) };
  })).filter((page): page is Page => !!page).sort(order).slice(0, MAXIMUM_LISTED);
  return batched(found, async page => ({ ...page, title: await title(join(root, page.name, "index.html")) ?? page.name }));
}

export function createArtifactsModule(host: () => Promise<string | undefined> = tailnetName): ModuleDescriptor {
  return {
    name: "tron-artifacts",
    purpose: "Lists the internal workspace's tools by last update and dated reports newest first, with their tailnet URLs.",
    tools: [],
    commands: [],
    dependsOn: [workspaceModule],
    start: (gateway) => {
      const workspace = gateway.contract(workspaceModule);
      return { rpc: { "artifacts.list": { kind: "read", handle: async (params) => {
        rejectUnknownFields(params, [], "artifacts.list");
        const described = await workspace.describe();
        if (!described.available) throw new GatewayError("conflict", "Tron internal workspace is unavailable");
        const [tools, reports] = await Promise.all([
          pages(join(described.root, "artifacts"), TOOL_NAME, (a, b) => b.updated - a.updated || a.name.localeCompare(b.name)),
          pages(join(described.root, "reports"), REPORT_NAME,
            (a, b) => b.name.slice(0, 10).localeCompare(a.name.slice(0, 10)) || b.updated - a.updated || a.name.localeCompare(b.name)),
        ]);
        const name = tools.length || reports.length ? await host() : undefined;
        if ((tools.length || reports.length) && !name) throw new GatewayError("conflict", "Artifacts are served on the tailnet; Tailscale is not connected on this Mac");
        const entry = (folder: string, page: Page) => ({
          name: page.name, title: page.title, updatedAt: new Date(page.updated).toISOString(),
          url: `https://${name}:${SHARE_HOST_PORT}/${folder}/${page.name}/`,
        });
        return {
          tools: tools.map(page => entry("artifacts", page)),
          reports: reports.map(page => ({ ...entry("reports", page), day: page.name.slice(0, 10) })),
        };
      } } } };
    },
  };
}
