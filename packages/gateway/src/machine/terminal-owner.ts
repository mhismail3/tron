import { randomUUID } from "node:crypto";
import { accessSync, constants, mkdtempSync, rmSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, type IPty, type IPtyForkOptions } from "node-pty";
import { GatewayError } from "../errors.js";
import { PROCESS_OWNER_ENV, type ProcessOwnerCapability } from "../lifecycle/process-lease-host.js";

const executable = fileURLToPath(new URL("../../native/terminal-owner", import.meta.url));
export interface TerminalOwner {
  pty: IPty;
  cleanup: Promise<"exited" | "unknown">;
  terminate(): void;
}

/** The private channel is both a parent-lifetime lease and a cleanup receipt.
 * PTY output/exit cannot attest job-control cleanup, and is never parsed as one. */
export function spawnTerminalOwner(shell: string, options: IPtyForkOptions): TerminalOwner {
  try { accessSync(executable, constants.X_OK); } catch {
    throw new GatewayError("internal", "Native terminal owner is missing; build packages/gateway/native/terminal-owner before opening terminals.");
  }
  // Darwin socket paths are short. Do not use the potentially long user TMPDIR.
  const directory = mkdtempSync("/tmp/tron-terminal-");
  const path = join(directory, "control");
  const nonce = randomUUID();
  let connection: Socket | undefined;
  let terminating = false;
  let settled = false;
  let resolveCleanup!: (outcome: "exited" | "unknown") => void;
  const cleanup = new Promise<"exited" | "unknown">((resolve) => { resolveCleanup = resolve; });
  const finish = (outcome: "exited" | "unknown") => {
    if (settled) return;
    settled = true;
    clearTimeout(startup);
    clearTimeout(termination);
    resolveCleanup(outcome);
    if (outcome === "unknown") {
      connection?.destroy();
      removeEndpoint();
    }
  };
  const removeEndpoint = () => {
    server.close();
    rmSync(directory, { recursive: true, force: true });
  };
  let termination: ReturnType<typeof setTimeout> | undefined;
  const startup = setTimeout(() => { finish("unknown"); }, 3000);
  startup.unref();
  const server = createServer((socket) => {
    if (connection || settled) { socket.destroy(); return; }
    connection = socket;
    socket.setEncoding("utf8");
    let buffer = "";
    let authenticated = false;
    socket.on("data", (data: string) => {
      buffer += data;
      if (buffer.length > 128) { finish("unknown"); return; }
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) break;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!authenticated) {
          if (line !== nonce) { finish("unknown"); return; }
          authenticated = true;
          clearTimeout(startup);
          // Only this helper knows the nonce, and it checks the socket peer PID
          // before forking. Descendants receive neither endpoint nor descriptor.
          removeEndpoint();
          socket.write(terminating ? "T" : "S");
        } else if (/^E\d{1,3}$/u.test(line)) {
          finish("exited");
        } else {
          finish("unknown");
        }
      }
    });
    socket.on("error", () => { finish("unknown"); });
    socket.on("close", () => { finish("unknown"); });
    socket.unref();
  });
  server.on("error", () => { finish("unknown"); });
  server.listen(path);
  server.unref();
  let pty: IPty;
  try {
    const raw = process.env[PROCESS_OWNER_ENV];
    const cap = raw ? JSON.parse(raw) as ProcessOwnerCapability : undefined;
    if (cap && (!cap.guardianSocket || !cap.guardianNonce || !Number.isSafeInteger(cap.guardianPid))) throw new Error("Invalid terminal guardian capability");
    const guardian = cap ? ["--guardian", cap.guardianSocket, cap.guardianNonce, String(cap.guardianPid)] : [];
    pty = spawn(executable, [...guardian, path, nonce, shell, "-l"], options);
  } catch (error) {
    finish("unknown");
    throw error;
  }
  pty.onExit(() => {
    removeEndpoint();
    // An accepted socket drains its final bytes before close. If there was no
    // connection, helper exit is startup failure, not evidence of cleanup.
    if (!connection) finish("unknown");
  });
  return {
    pty,
    cleanup,
    terminate() {
      if (terminating || settled) return;
      terminating = true;
      connection?.write("T");
      termination = setTimeout(() => { finish("unknown"); }, 3500);
      termination.unref();
    },
  };
}
