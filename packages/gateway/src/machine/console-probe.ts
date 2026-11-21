import { execFile, spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { promisify } from "node:util";

const run = promisify(execFile);
const OSASCRIPT = "/usr/bin/osascript";
const PROBE = `ObjC.import("CoreGraphics");
const s = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary())) || {};
JSON.stringify({ locked: s.CGSSessionScreenIsLocked === true, asleep: $.CGDisplayIsAsleep($.CGMainDisplayID()) !== 0 })`;
const HOLDER = `function run(argv) {
  ObjC.import("CoreGraphics"); ObjC.import("IOKit"); ObjC.import("Foundation");
  if (argv[0] === "PreventUserIdleDisplaySleep" && $.CGDisplayIsAsleep($.CGMainDisplayID()) !== 0) return;
  const id = Ref();
  if ($.IOPMAssertionCreateWithName($(argv[0]), 255, $("Tron active computer turn"), id) !== 0) return;
  $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  $.IOPMAssertionRelease(id[0]);
}`;

export type ConsoleCause = "mac_locked" | "display_asleep";
const MESSAGES: Record<ConsoleCause, string> = {
  mac_locked: "the Mac screen is locked",
  display_asleep: "the Mac display is asleep",
};

export class ConsoleUnavailableError extends Error {
  readonly code: ConsoleCause;
  constructor(code: ConsoleCause) {
    super(`${code}: ${MESSAGES[code]}. Desktop observation, capture and input are refused until the user unlocks or wakes it; nothing was captured or sent. Browser work over CDP is unaffected.`);
    this.code = code;
  }
}

async function consoleCause(): Promise<ConsoleCause | undefined> {
  const { stdout } = await run(OSASCRIPT, ["-l", "JavaScript", "-e", PROBE], { encoding: "utf8", timeout: 900, maxBuffer: 4096, env: {} });
  const state = JSON.parse(stdout) as { locked?: unknown; asleep?: unknown };
  if (typeof state.locked !== "boolean" || typeof state.asleep !== "boolean") throw new Error("Console state is unavailable");
  return state.locked ? "mac_locked" : state.asleep ? "display_asleep" : undefined;
}

export class ConsoleGate {
  private episode = false;
  private readonly notify: (sessionId: string, cause: ConsoleCause) => Promise<unknown>;

  constructor(notify: (sessionId: string, cause: ConsoleCause) => Promise<unknown>) { this.notify = notify; }

  async admit(sessionId: string): Promise<void> {
    const cause = await consoleCause();
    if (!cause) { this.episode = false; return; }
    if (!this.episode) {
      this.episode = true;
      void this.notify(sessionId, cause).catch(() => {});
    }
    throw new ConsoleUnavailableError(cause);
  }
}

export class DisplayActivity {
  private child: ChildProcess | undefined;

  hold(): void {
    if (this.child) return;
    const child = spawn(OSASCRIPT, ["-l", "JavaScript", "-e", HOLDER, "PreventUserIdleDisplaySleep"], { stdio: ["pipe", "ignore", "ignore"], env: {} });
    child.on("error", () => {});
    if (!child.pid) return;
    this.child = child;
    child.once("exit", () => { if (this.child === child) this.child = undefined; });
  }

  async release(): Promise<void> {
    const child = this.child; this.child = undefined;
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    const exited = once(child, "exit");
    child.kill("SIGTERM");
    await exited;
  }
}
