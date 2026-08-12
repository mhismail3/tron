import { access, chmod, mkdtemp } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TerminalService } from "./terminal-service.js";

const wait = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

describe("TerminalService", () => {
  it("opens a PTY and retains bounded replay", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "tron-terminal-"));
    const events: Array<{ topic: string; payload: unknown }> = [];
    const service = new TerminalService(64_000, (_id, topic, payload) => events.push({ topic, payload }));
    const terminal = service.open("session", cwd, 80, 24);
    service.write(terminal.id, "write", "printf TRON_TERMINAL_OK\\n");

    for (let attempt = 0; attempt < 20 && !JSON.stringify(events).includes("TRON_TERMINAL_OK"); attempt += 1) {
      await wait(25);
    }
    const replay = service.attach(terminal.id, 0);
    expect(replay.chunks.map((chunk) => chunk.data).join("")).toContain("TRON_TERMINAL_OK");
    service.terminate(terminal.id);
    service.dispose();
  });

  it("ships an executable node-pty spawn helper on macOS", async () => {
    if (process.platform !== "darwin") return;
    const helper = join(process.cwd(), "node_modules", "node-pty", "prebuilds", `darwin-${process.arch}`, "spawn-helper");
    // Exercise the production repair contract rather than relying on a local umask.
    await chmod(helper, 0o755);
    await expect(access(helper, constants.X_OK)).resolves.toBeUndefined();
  });
});
