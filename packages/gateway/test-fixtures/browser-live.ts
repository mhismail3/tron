import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";

export const jpeg = readFileSync(new URL("./browser-live.jpg", import.meta.url));
export const registration = {
  sessionId: "session-a", viewId: "view-a", generation: "runtime-a:browser-a",
  cdpUrl: "ws://127.0.0.1:1234/devtools/browser/12345678-1234-1234-1234-123456789abc",
};
type Command = { id: number; method: string; params?: Record<string, unknown>; sessionId?: string };

/** Protocol peer, not a substitute observer: replies use correlated CDP IDs and
 * real JPEG bytes. Tests control missing/error replies and visibility changes. */
export class BrowserSocket extends EventEmitter {
  readyState = 0;
  commands: Command[] = [];
  visible = new Map([["one", true], ["two", false]]);
  silent = new Set<string>();
  fail = new Set<string>();
  send(value: string, callback?: (error?: Error) => void): void {
    const command = JSON.parse(value) as Command;
    this.commands.push(command);
    this.emit("sent", command);
    callback?.();
    if (this.silent.has(command.method)) return;
    let result: Record<string, unknown> = {};
    if (command.method === "Target.getTargets") result = { targetInfos: [...this.visible.keys()].map((id) => ({ type: "page", targetId: id })) };
    if (command.method === "Target.attachToTarget") result = { sessionId: `observer:${command.params?.targetId}` };
    if (command.method === "Runtime.evaluate") result = { result: { type: "string", value: this.visible.get(command.sessionId!.slice("observer:".length)) ? "visible" : "hidden" } };
    queueMicrotask(() => {
      if (this.readyState !== 1) return;
      this.message({ id: command.id, ...(command.sessionId ? { sessionId: command.sessionId } : {}),
        ...(this.fail.has(command.method) ? { error: { code: -32000, message: "Fixture failure" } } : { result }) });
    });
  }
  open(): void { this.readyState = 1; this.emit("open"); }
  terminate(): void { if (this.readyState !== 3) { this.readyState = 3; this.emit("close"); } }
  message(value: unknown): void { this.emit("message", Buffer.from(JSON.stringify(value))); }
  frame(id: number, target = "one", data = jpeg): void {
    this.message({ method: "Page.screencastFrame", sessionId: `observer:${target}`,
      params: { sessionId: id, data: data.toString("base64"), metadata: { deviceWidth: 1280, deviceHeight: 720 } } });
  }
}
