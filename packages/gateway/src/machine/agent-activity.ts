import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";

export class AgentActivity {
  private child: ChildProcess | undefined;
  private ready: Promise<void> | undefined;
  private closing: Promise<void> | undefined;

  start(): Promise<void> {
    if (this.closing) return Promise.reject(new Error("Agent activity is retiring"));
    if (this.ready) return this.ready;
    const child = this.child = spawn("/usr/bin/caffeinate", ["-i", "-w", String(process.pid)], { stdio: "ignore" });
    this.ready = once(child, "spawn").then(() => {});
    return this.ready;
  }

  close(): Promise<void> {
    if (this.closing) return this.closing;
    const child = this.child, ready = this.ready;
    const work = (async () => {
      await ready?.catch(() => {});
      if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
      const joined = once(child, "exit");
      child.kill("SIGTERM");
      await joined;
    })();
    this.closing = work;
    void work.finally(() => {
      this.child = undefined;
      this.ready = undefined;
      this.closing = undefined;
    }).catch(() => {});
    return work;
  }
}
