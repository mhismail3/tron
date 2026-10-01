import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { nativeProcessOwner } from "./process-lease-host.js";

export const RESTART_DEADLINE_MS = 15_000;
export const RESTART_OWNER_ENV = "TRON_RESTART_OWNER";
interface RestartCapability { socket: string; nonce: string; originPid: number }
export interface ProcessGuardianCapability { guardianSocket: string; guardianNonce: string; guardianPid: number }

/** Once bytes may have reached native authority, failure is not rejection. */
export class RestartArmUncertainError extends Error {}

/** The native guardian captures its actual parent at Gateway startup. Only the
 * updater receives its capability; agent processes receive process leases only. */
export async function startRestartWatchdog(executable = nativeProcessOwner) {
  const directory = mkdtempSync("/tmp/tron-restart-");
  const capability: RestartCapability = { socket: join(directory, "control"), nonce: randomUUID(), originPid: process.pid };
  const leaseNonce = randomUUID();
  const child = spawn(executable, ["--watchdog", capability.socket, capability.nonce, leaseNonce], {
    detached: true, stdio: ["ignore", "ignore", "ignore", "pipe"],
  });
  const channel = child.stdio[3] as Duplex;
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => fail(new Error("Native restart guardian did not acknowledge startup")), 2000);
    const fail = (error: Error) => { clearTimeout(timer); channel.destroy(); reject(error); };
    child.once("error", fail);
    child.once("exit", () => fail(new Error("Native restart guardian exited before readiness")));
    channel.once("data", (chunk: Buffer) => {
      if (chunk.toString() !== "R") { fail(new Error("Invalid native restart guardian acknowledgement")); return; }
      clearTimeout(timer);
      channel.end("P");
      resolve();
    });
    channel.once("error", fail);
  }).catch((error) => { rmSync(directory, { recursive: true, force: true }); throw error; });
  child.unref();
  return {
    environment: { [RESTART_OWNER_ENV]: JSON.stringify(capability) },
    leaseCapability: { guardianSocket: capability.socket, guardianNonce: leaseNonce, guardianPid: child.pid! } satisfies ProcessGuardianCapability,
    arm: (deadline = Date.now() + RESTART_DEADLINE_MS) => armRestartWatchdog(capability, deadline),
  };
}

export function armRestartWatchdog(capability: RestartCapability, deadline: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(capability.socket);
    const timer = setTimeout(() => finish(new Error("Native restart guardian acknowledgement timed out")), 1000);
    let settled = false, submitted = false, buffer = "";
    const finish = (error?: Error, accepted?: number) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(submitted ? new RestartArmUncertainError(error.message) : error); else resolve(accepted!);
    };
    socket.on("connect", () => { submitted = true; socket.write(`${capability.nonce} ${deadline}\n`); });
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      if (buffer.length > 64) { finish(new Error("Invalid native restart acknowledgement")); return; }
      if (!buffer.endsWith("\n")) return;
      const match = /^R(\d+)\n$/u.exec(buffer);
      const accepted = Number(match?.[1]);
      if (!Number.isSafeInteger(accepted) || accepted > deadline || accepted <= Date.now()) finish(new Error("Invalid native restart deadline"));
      else finish(undefined, accepted);
    });
    socket.on("error", (error) => finish(error));
    socket.on("close", () => finish(new Error("Native restart guardian closed without acknowledgement")));
  });
}
