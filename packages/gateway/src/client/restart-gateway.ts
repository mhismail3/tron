import { randomUUID } from "node:crypto";
import { resolveBindHost, resolveTronHome } from "../config.js";
import { GatewayProtocolClient } from "./gateway-client.js";
import { readLocalCredential } from "./local-credential.js";

function argument(name: string): string | undefined {
  const equals = process.argv.find((value) => value.startsWith(`${name}=`));
  if (equals) return equals.slice(name.length + 1);
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const commandId = argument("--command-id") ?? randomUUID();
if (commandId.length < 8 || commandId.length > 160 || /[\u0000-\u001f\u007f]/u.test(commandId)) {
  throw new Error("Restart command ID must be 8–160 printable characters");
}

const rawHost = argument("--host") ?? process.env.TRON_GATEWAY_HOST ?? "127.0.0.1";
const host = resolveBindHost(rawHost);
const port = Number(argument("--port") ?? process.env.TRON_GATEWAY_PORT ?? "9848");
if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error("Invalid Gateway port");
const tronHome = resolveTronHome();
const authority = host.includes(":") ? `[${host}]` : host;
const client = new GatewayProtocolClient(
  `ws://${authority}:${port}/v1/socket`,
  await readLocalCredential(tronHome),
);
try {
  await client.connect();
  const result = await client.request("gateway.restart", { commandId }) as {
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
