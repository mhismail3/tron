import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { runBoundedCommand } from "../platform/tailscale-status.js";

export const SHARE_HOST_LABEL = "com.tron.ios-builds";

type Loaded = "absent" | "owned" | "foreign";

export class ShareHostJob {
  readonly plistPath: string;
  private readonly domain = `gui/${process.getuid!()}`;
  private readonly home: string;

  constructor(tronHome: string, readonly label = SHARE_HOST_LABEL, launchAgentDirectory = join(homedir(), "Library/LaunchAgents")) {
    this.home = resolve(tronHome);
    this.plistPath = join(resolve(launchAgentDirectory), `${label}.plist`);
  }

  async suspend(): Promise<boolean> {
    if (!await this.enabled() || await this.loaded() !== "owned") return false;
    await this.launchctl(["bootout", `${this.domain}/${this.label}`]);
    if (await this.loaded() !== "absent") throw new Error(`${this.label} did not stop`);
    return true;
  }

  async restore(): Promise<boolean> {
    if (!await this.enabled() || await this.loaded() !== "absent") return false;
    await this.launchctl(["bootstrap", this.domain, this.plistPath]);
    return true;
  }

  private async enabled(): Promise<boolean> {
    const result = await runBoundedCommand("/usr/bin/plutil", ["-convert", "json", "-o", "-", this.plistPath], 5_000);
    if (result.code !== 0) return false;
    const plist = JSON.parse(result.output) as { Label?: unknown; ProgramArguments?: unknown };
    const directory = Array.isArray(plist.ProgramArguments) ? plist.ProgramArguments[3] : undefined;
    return plist.Label === this.label && typeof directory === "string" && resolve(directory).startsWith(`${this.home}/`);
  }

  private async loaded(): Promise<Loaded> {
    const result = await runBoundedCommand("/bin/launchctl", ["print", `${this.domain}/${this.label}`], 5_000);
    if (result.code === 113) return "absent";
    if (result.code !== 0) throw new Error(`cannot inspect ${this.label}`);
    const path = result.output.match(/^\s*path = (.+)$/mu)?.[1]?.trim();
    const real = (file: string) => realpath(file).catch(() => file);
    return path !== undefined && await real(path) === await real(this.plistPath) ? "owned" : "foreign";
  }

  private async launchctl(args: string[]): Promise<void> {
    const result = await runBoundedCommand("/bin/launchctl", args, 10_000);
    if (result.code !== 0) throw new Error(`launchctl ${args[0]} ${this.label} failed (${result.code ?? "timeout"})`);
  }
}
