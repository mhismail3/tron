#!/usr/bin/env node
import { join } from "node:path";
import { assertHomeLayout } from "../foundation/tron-home-layout.js";
import { MacTerminalService } from "./mac-terminal-service.js";

async function main(): Promise<void> {
  const [command, flag, home, ...extra] = process.argv.slice(2);
  if (!command || !["status", "start", "stop", "recover"].includes(command) || flag !== "--home" || !home || extra.length) {
    throw new Error("Usage: scripts/tron terminal-ssh status|start|stop|recover --home <existing-tron-home>");
  }
  await assertHomeLayout(home);
  const service = new MacTerminalService({ root: join(home, "state/mac-terminal") });
  if (command === "start") await service.setEnabled(true);
  else if (command === "stop") await service.setEnabled(false);
  else if (command === "recover") await service.recover();
  process.stdout.write(`${JSON.stringify(await service.status(), null, 2)}\n`);
}
main().catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
