import { lstat, readdir } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import { readTailscaleStatus, runBoundedCommand } from "../../platform/tailscale-status.js";
import { rejectUnknownFields } from "../../util/validation.js";
import { workspaceModule } from "../../workspace/workspace-module.js";

export const ARTIFACT_NAME = /^\d{4}-\d{2}-\d{2}_[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/u;
const SHARE_HOST_PORT = 8443;
const MAXIMUM_LISTED = 500;

async function tailnetName(): Promise<string | undefined> {
  const read = await readTailscaleStatus(runBoundedCommand, 5_000);
  return read.ok ? read.status.selfDNSName?.replace(/\.$/u, "") : undefined;
}

async function page(root: string, name: string): Promise<boolean> {
  const [folder, index] = await Promise.all([lstat(join(root, name)), lstat(join(root, name, "index.html"))].map(read => read.catch(() => undefined)));
  return !!folder?.isDirectory() && !!index?.isFile();
}

export function createArtifactsModule(host: () => Promise<string | undefined> = tailnetName): ModuleDescriptor {
  return {
    name: "tron-artifacts",
    purpose: "Lists the internal workspace's dated artifacts newest first with their tailnet URLs.",
    tools: [],
    commands: [],
    dependsOn: [workspaceModule],
    start: (gateway) => {
      const workspace = gateway.contract(workspaceModule);
      return { rpc: { "artifacts.list": { kind: "read", handle: async (params) => {
        rejectUnknownFields(params, [], "artifacts.list");
        const described = await workspace.describe();
        if (!described.available) throw new GatewayError("conflict", "Tron internal workspace is unavailable");
        const root = join(described.root, "artifacts");
        const info = await lstat(root).catch(() => undefined);
        const names = info?.isDirectory() ? (await readdir(root)).filter(name => ARTIFACT_NAME.test(name)).sort().reverse() : [];
        const listed: string[] = [];
        for (const name of names) {
          if (listed.length === MAXIMUM_LISTED) break;
          if (await page(root, name)) listed.push(name);
        }
        const name = listed.length ? await host() : undefined;
        if (listed.length && !name) throw new GatewayError("conflict", "Artifacts are served on the tailnet; Tailscale is not connected on this Mac");
        return { artifacts: listed.map(entry => ({ name: entry, url: `https://${name}:${SHARE_HOST_PORT}/artifacts/${entry}/` })) };
      } } } };
    },
  };
}
