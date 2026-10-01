import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

export const nativeProcessOwner = fileURLToPath(new URL("../../native/terminal-owner", import.meta.url));
export const PROCESS_OWNER_ENV = "PI_SUBAGENT_PROCESS_OWNER";
import type { ProcessGuardianCapability } from "./restart-watchdog.js";
export interface ProcessOwnerCapability extends ProcessGuardianCapability { executable: string; socket: string; nonce: string; originPid: number; bashExtension: string }

/** Physical connections only. Admission and retirement belong to the existing
 * work registry; no run/session state or recoverable PID authority lives here. */
export async function createProcessLeaseHost(registry: GatewayWorkRegistry, guardian: ProcessGuardianCapability, executable = nativeProcessOwner) {
  const directory = mkdtempSync("/tmp/tron-process-");
  const capability: ProcessOwnerCapability = { ...guardian, executable, socket: join(directory, "lease"), nonce: randomUUID(), originPid: process.pid, bashExtension: fileURLToPath(new URL("./owned-bash-extension.js", import.meta.url)) };
  const connections = new Set<Socket>();
  const server = createServer((socket) => {
    connections.add(socket);
    socket.setEncoding("utf8");
    let buffer = "";
    let work: GatewayWorkHandle | undefined;
    const startup = setTimeout(() => socket.destroy(), 2000);
    startup.unref();
    socket.on("error", () => socket.destroy());
    socket.on("close", () => {
      clearTimeout(startup);
      connections.delete(socket);
      // EOF alone is not quiescence; retain unknown work until process exit.
    });
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      if (buffer.length > 128) { socket.destroy(); return; }
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!work) {
          if (line !== capability.nonce) { socket.destroy(); return; }
          try {
            work = registry.begin({ kind: "native-process-lease", hostEpoch: registry.runtimeEpoch,
              cancellation: () => { socket.write("T"); } });
          } catch { socket.destroy(); return; }
          clearTimeout(startup);
          // No await between the admission cut and permission to execute.
          socket.write("S");
        } else if (/^E\d{1,3}$/u.test(line)) {
          work.settle();
          socket.end();
        } else { socket.destroy(); return; }
      }
    });
    socket.unref();
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(capability.socket, () => { server.removeListener("error", reject); resolve(); });
  }).catch((error) => { rmSync(directory, { recursive: true, force: true }); throw error; });
  server.unref();
  return {
    environment: { [PROCESS_OWNER_ENV]: JSON.stringify(capability) },
    terminate() { for (const socket of connections) socket.write("T"); },
    close() {
      server.close();
      for (const socket of connections) socket.destroy();
      rmSync(directory, { recursive: true, force: true });
    },
  };
}
