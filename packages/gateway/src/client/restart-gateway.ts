import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { resolveBindHost, resolveTronHome } from "../config.js";
import { GatewayProtocolClient } from "./gateway-client.js";

function argument(name: string): string | undefined {
  const equals = process.argv.find((value) => value.startsWith(`${name}=`));
  if (equals) return equals.slice(name.length + 1);
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const rawHost = argument("--host") ?? process.env.TRON_GATEWAY_HOST ?? "127.0.0.1";
const host = resolveBindHost(rawHost);
const port = Number(argument("--port") ?? process.env.TRON_GATEWAY_PORT ?? "9848");
if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error("Invalid Gateway port");
const tokenPath = join(resolveTronHome(), "gateway", "local-auth.json");
const document = JSON.parse(await readFile(tokenPath, "utf8")) as { bearerToken?: string };
if (!document.bearerToken) throw new Error(`Missing local Gateway credential at ${tokenPath.replace(homedir(), "~")}`);
const authority = host.includes(":") ? `[${host}]` : host;
const client = new GatewayProtocolClient(`ws://${authority}:${port}/v1/socket`, document.bearerToken);
try {
  await client.connect();
  const result = await client.request("gateway.restart", { commandId: randomUUID() }) as {
    restarting: boolean;
    scheduled: boolean;
    activeSessionIds: string[];
  };
  if (result.scheduled) {
    console.log(`Tron Gateway restart scheduled after ${result.activeSessionIds.length} active agent run${result.activeSessionIds.length === 1 ? "" : "s"} settles.`);
  } else {
    console.log("Tron Gateway is restarting.");
  }
} finally {
  client.close();
}
