import { existsSync } from "node:fs";
import { createConnection, type Server, type Socket } from "node:net";
import { dirname } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { spawnTerminalOwner } from "./terminal-owner.js";

const fixture = vi.hoisted(() => ({
  args: [] as string[],
  server: undefined as Server | undefined,
  socket: undefined as Socket | undefined,
}));
vi.mock("node:url", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:url")>();
  return { ...original, fileURLToPath: (url: URL | string) => String(url).endsWith("/native/terminal-owner")
    ? "/usr/bin/true" : original.fileURLToPath(url) };
});
vi.mock("node-pty", () => ({ spawn: (_executable: string, args: string[]) => {
  fixture.args = args;
  return { onExit() {} };
} }));
vi.mock("node:net", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:net")>();
  return { ...original, createServer: (listener: (socket: Socket) => void) => {
    const server = original.createServer(listener);
    server.on("connection", (socket) => { fixture.socket = socket; });
    fixture.server = server;
    return server;
  } };
});
const peers: Socket[] = [];
afterEach(() => { for (const peer of peers.splice(0)) peer.destroy(); fixture.socket?.destroy(); fixture.server?.close(); });

async function openControl() {
  const owner = spawnTerminalOwner("/usr/bin/true", { cwd: "/tmp" });
  const accepted = new Promise<void>((resolve) => fixture.server!.once("connection", () => resolve()));
  const peer = createConnection(fixture.args[0]!);
  peers.push(peer);
  peer.on("error", () => {});
  peer.resume();
  await Promise.all([accepted, new Promise<void>((resolve) => peer.once("connect", resolve))]);
  return { owner, peer, directory: dirname(fixture.args[0]!) };
}
function retired(directory: string) {
  expect(existsSync(directory)).toBe(false);
  expect(fixture.server?.listening).toBe(false);
}

describe("terminal owner private handshake", () => {
  it.each(["disconnect", "socket-error", "wrong-nonce", "oversized"])("retires pre-auth %s without a successful receipt", async (failure) => {
    const { owner, peer, directory } = await openControl();
    if (failure === "disconnect") peer.end();
    else if (failure === "socket-error") fixture.socket!.emit("error", new Error("isolated handshake failure"));
    else peer.write(failure === "oversized" ? "x".repeat(129) : "not-the-nonce\n");
    await expect(owner.cleanup).resolves.toBe("unknown");
    retired(directory);
    owner.terminate();
    await expect(owner.cleanup).resolves.toBe("unknown");
  });

  it("retires a listening-server error before any helper connection", async () => {
    const owner = spawnTerminalOwner("/usr/bin/true", { cwd: "/tmp" });
    const directory = dirname(fixture.args[0]!);
    fixture.server!.emit("error", new Error("isolated listen failure"));
    await expect(owner.cleanup).resolves.toBe("unknown");
    retired(directory);
  });

  it("drains an authenticated final receipt before EOF without downgrading it", async () => {
    const { owner, peer, directory } = await openControl();
    peer.end(`${fixture.args[1]}\nE17\n`);
    await expect(owner.cleanup).resolves.toBe("exited");
    retired(directory);
    await new Promise<void>((resolve) => peer.once("close", resolve));
    await expect(owner.cleanup).resolves.toBe("exited");
  });
});
