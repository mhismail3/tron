import { spawn, type ChildProcess, type SpawnOptions } from "node:child_process";
import type { Duplex } from "node:stream";
import { PROCESS_OWNER_ENV, type ProcessOwnerCapability } from "./process-lease-host.js";

export interface OwnedProcess {
  child: ChildProcess;
  ready: Promise<void>;
  cleanup: Promise<"exited" | "unknown">;
  terminate(): void;
}

export function spawnOwnedProcess(command: string, args: string[], options: SpawnOptions): OwnedProcess {
  const raw = process.env[PROCESS_OWNER_ENV];
  if (!raw) throw new Error("Gateway native process ownership is not initialized");
  const cap = JSON.parse(raw) as ProcessOwnerCapability;
  if (process.platform !== "darwin" || !cap.executable || !cap.socket || !cap.nonce || !Number.isSafeInteger(cap.originPid) || !cap.guardianSocket || !cap.guardianNonce || !Number.isSafeInteger(cap.guardianPid)) {
    throw new Error("Invalid native process owner capability");
  }
  const mode = options.stdio ?? "pipe";
  const stdio = Array.isArray(mode) ? mode : [mode, mode, mode];
  const child = spawn(cap.executable, ["--guardian", cap.guardianSocket, cap.guardianNonce, String(cap.guardianPid), "--process", cap.socket, cap.nonce, String(cap.originPid), command, ...args], {
    ...options, shell: false, detached: true, env: { ...(options.env ?? process.env), [PROCESS_OWNER_ENV]: raw }, stdio: [...stdio.slice(0, 3), "pipe"],
  });
  const channel = child.stdio[3] as Duplex;
  setImmediate(() => { if (!channel.destroyed) channel.write("P"); });
  let resolveReady!: () => void;
  let rejectReady!: (error: Error) => void;
  const ready = new Promise<void>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  void ready.catch(() => {});
  let resolveCleanup!: (outcome: "exited" | "unknown") => void;
  const cleanup = new Promise<"exited" | "unknown">((resolve) => { resolveCleanup = resolve; });
  let receipt = false;
  let exited = false;
  let finished = false;
  let buffer = "";
  const finish = (outcome: "exited" | "unknown") => {
    if (finished) return;
    finished = true;
    rejectReady(new Error("Native process admission failed"));
    resolveCleanup(outcome);
  };
  channel.setEncoding("utf8");
  channel.on("data", (chunk: string) => {
    buffer += chunk;
    if (buffer.length > 128) { finish("unknown"); channel.destroy(); return; }
    for (;;) {
      const end = buffer.indexOf("\n");
      if (end < 0) break;
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (line === "R") resolveReady();
      else if (/^E\d{1,3}$/u.test(line)) { receipt = true; if (exited) finish("exited"); }
      else finish("unknown");
    }
  });
  channel.on("error", () => finish("unknown"));
  channel.on("close", () => { if (!receipt) finish("unknown"); });
  child.once("error", () => finish("unknown"));
  child.once("exit", () => { exited = true; if (receipt) finish("exited"); });
  child.once("close", () => finish(receipt && exited ? "exited" : "unknown"));
  return { child, ready, cleanup, terminate: () => { if (!finished) channel.write("T"); } };
}
