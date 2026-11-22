import { execFile, spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { promisify } from "node:util";

const run = promisify(execFile);
const OSASCRIPT = "/usr/bin/osascript";
const PROBE = `ObjC.import("CoreGraphics");
const s = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary())) || {};
JSON.stringify({ console: s.kCGSSessionOnConsoleKey === true, locked: s.CGSSessionScreenIsLocked === true, asleep: $.CGDisplayIsAsleep($.CGMainDisplayID()) !== 0 })`;
const HOLDER = `function run(argv) {
  ObjC.import("CoreGraphics"); ObjC.import("IOKit"); ObjC.import("Foundation");
  if (argv[0] === "PreventUserIdleDisplaySleep" && $.CGDisplayIsAsleep($.CGMainDisplayID()) !== 0) return;
  const id = Ref();
  if ($.IOPMAssertionCreateWithName($(argv[0]), 255, $("Tron active computer turn"), id) !== 0) return;
  $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  $.IOPMAssertionRelease(id[0]);
}`;

export type ConsoleCause = "mac_locked" | "display_asleep" | "no_console_session" | "console_unavailable";
const MESSAGES: Record<ConsoleCause, string> = {
  mac_locked: "the Mac screen is locked",
  display_asleep: "the Mac display is asleep",
  no_console_session: "no user session is on the Mac console (logged out or switched user)",
  console_unavailable: "the Mac console state could not be read",
};
const DESKTOP_TASK_HOLD_MS = 2 * 60 * 60 * 1000;

export class ConsoleUnavailableError extends Error {
  constructor(code: ConsoleCause) {
    super(`${code}: ${MESSAGES[code]}. Desktop observation, capture and input are refused until a user is logged in at the Mac and it is unlocked and awake; nothing was captured or sent. Browser work over CDP is unaffected.`);
  }
}

async function consoleCause(): Promise<ConsoleCause | undefined> {
  let state: { console?: unknown; locked?: unknown; asleep?: unknown };
  try {
    const { stdout } = await run(OSASCRIPT, ["-l", "JavaScript", "-e", PROBE], { encoding: "utf8", timeout: 900, maxBuffer: 4096, env: {} });
    state = JSON.parse(stdout) as typeof state;
  } catch { return "console_unavailable"; }
  if (typeof state.console !== "boolean" || typeof state.locked !== "boolean" || typeof state.asleep !== "boolean") return "console_unavailable";
  return !state.console ? "no_console_session" : state.locked ? "mac_locked" : state.asleep ? "display_asleep" : undefined;
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
  private limit: NodeJS.Timeout | undefined;

  hold(): void {
    if (this.child) return;
    const child = spawn(OSASCRIPT, ["-l", "JavaScript", "-e", HOLDER, "PreventUserIdleDisplaySleep"], { stdio: ["pipe", "ignore", "ignore"], env: {} });
    child.on("error", () => {});
    if (!child.pid) return;
    this.child = child;
    clearTimeout(this.limit);
    this.limit = setTimeout(() => { void this.release(); }, DESKTOP_TASK_HOLD_MS).unref();
    child.once("exit", () => { if (this.child === child) this.child = undefined; });
  }

  async release(): Promise<void> {
    clearTimeout(this.limit); this.limit = undefined;
    const child = this.child; this.child = undefined;
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    const exited = once(child, "exit");
    child.kill("SIGTERM");
    await exited;
  }
}
