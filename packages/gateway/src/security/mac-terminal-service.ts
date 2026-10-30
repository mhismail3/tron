import { createHash, randomBytes } from "node:crypto";
import { realpathSync } from "node:fs";
import { chmod, lstat, mkdir, readFile, rm } from "node:fs/promises";
import { isIP } from "node:net";
import { homedir, userInfo } from "node:os";
import { join, resolve } from "node:path";
import lockfile from "proper-lockfile";
import { GatewayError } from "../errors.js";
import { durableAtomicWriteText, durableRemove } from "../foundation/durable-json.js";
import { readTailscaleStatus, runBoundedCommand } from "../platform/tailscale-status.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { MacTerminalKeys } from "./mac-terminal.js";

export const MAC_TERMINAL_PORT = 44222;
export interface MacTerminalStatus {
  username: string;
  port: number;
  hosts: string[];
  hostKeys: string[];
  hostFingerprint?: string;
  serviceState: "unconfigured" | "stopped" | "running" | "stale" | "unavailable" | "failed";
  detail?: string;
  enrolled: boolean;
  enrolledKey?: string;
}
interface Job { pid?: number; running: boolean }

export function isMacTerminalIPv4(address: string): boolean {
  const octets = address.split(".").map(Number);
  return isIP(address) === 4 && octets[0] === 100 && octets[1]! >= 64 && octets[1]! <= 127;
}
function xml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}
const missing = (error: unknown) => (error as NodeJS.ErrnoException).code === "ENOENT";

/** One owner for private SSH identity, authorization, configuration and user
 * launchd lifecycle. Neither CLI nor Gateway owns an sshd child. Stock SSH is
 * never read, changed or used as a fallback. */
export class MacTerminalService {
  readonly root: string;
  readonly configPath: string;
  readonly hostKeyPath: string;
  readonly label: string;
  readonly plistPath: string;
  readonly port: number;
  private readonly domain: string;
  private readonly keys: MacTerminalKeys;
  private readonly mutex = new AsyncMutex();
  private readonly run = runBoundedCommand;
  private readonly username = userInfo().username;

  constructor(tronHome: string, options: { port?: number; launchAgentDirectory?: string } = {}) {
    this.root = join(realpathSync(tronHome), "mac-terminal");
    if (/[\x00-\x1f]/u.test(this.root) || this.root.trim() !== this.root) throw new GatewayError("invalid_request", "Invalid SSH home path");
    this.port = options.port ?? MAC_TERMINAL_PORT;
    if (!Number.isInteger(this.port) || this.port < 1024 || this.port > 65535) throw new GatewayError("invalid_request", "Mac Terminal requires a high port");
    this.configPath = join(this.root, "sshd_config");
    this.hostKeyPath = join(this.root, "ssh_host_ed25519_key");
    this.label = `com.tron.mac-terminal.${createHash("sha256").update(this.root).digest("hex").slice(0, 16)}`;
    this.plistPath = join(resolve(options.launchAgentDirectory ?? join(homedir(), "Library/LaunchAgents")), `${this.label}.plist`);
    this.domain = `gui/${process.getuid!()}`;
    this.keys = new MacTerminalKeys(this.root);
  }

  async read(): Promise<Record<string, string>> {
    await this.secureDirectory();
    return await this.secureFile(this.keys.path) ? this.keys.read() : {};
  }

  /** The owned login plist is enabled intent; health is a separate kernel read. */
  async enabled(): Promise<boolean> {
    await this.secureDirectory();
    const text = await this.text(this.plistPath);
    if (text === undefined) return false;
    if (text !== this.plist()) throw new GatewayError("conflict", "The SSH LaunchAgent is not owned by this configuration");
    return true;
  }

  async setEnabled(enabled: boolean): Promise<void> {
    await this.mutate(async fence => {
      if (enabled) await this.start(fence);
      else await this.stop(fence);
    });
  }

  async recover(): Promise<void> {
    await this.mutate(async fence => {
      const ip = await this.currentIPv4();
      if (!await this.identity(false)) throw new GatewayError("conflict", "Enable the private host identity before recovery");
      const config = this.config(ip);
      await this.validate(config);
      fence();
      await this.stop(fence);
      await durableAtomicWriteText(this.configPath, config);
      await this.start(fence);
    });
  }

  async set(device: string, key: string | null): Promise<void> {
    await this.mutate(async fence => {
      if (key !== null) {
        const status = await this.status(device);
        if (status.serviceState !== "running") throw new GatewayError("conflict", status.detail ?? "Explicitly enable and trust the private SSH service first");
      }
      fence();
      await this.secureFile(this.keys.path);
      await this.keys.set(device, key);
      // Authorization is removed before stopping; a failed stop never restores it.
      if (key === null && Object.keys(await this.keys.read()).length === 0) await this.stop(fence);
    });
  }

  async status(device = ""): Promise<MacTerminalStatus> {
    const keys = await this.read();
    const enrolledKey = keys[device];
    const base: MacTerminalStatus = { username: this.username, port: this.port, hosts: [], hostKeys: [],
      serviceState: "unconfigured", enrolled: enrolledKey !== undefined, ...(enrolledKey ? { enrolledKey } : {}) };
    try {
      const publicKey = await this.identity(false);
      if (publicKey) {
        base.hostKeys = [publicKey];
        base.hostFingerprint = `SHA256:${createHash("sha256").update(Buffer.from(publicKey.split(" ")[1]!, "base64")).digest("base64").replace(/=+$/u, "")}`;
      }
      let ip: string;
      try { ip = await this.currentIPv4(); base.hosts = [ip]; }
      catch (error) { return { ...base, serviceState: "unavailable", detail: (error as Error).message }; }
      const configured = await this.text(this.configPath);
      const enabled = await this.enabled();
      const job = await this.job();
      if (!configured && !publicKey && !enabled && !job) return base;
      if (configured && configured !== this.config(ip)) return { ...base, serviceState: "stale", detail: "SSH configuration is stale. Recover the owned service on the Mac, then explicitly refresh this iPhone's enrollment." };
      if (!enabled && !job) return { ...base, serviceState: "stopped" };
      if (!publicKey || !configured || !enabled || !job?.running || !job.pid) return { ...base, serviceState: "failed", detail: "The owned SSH job is not running. Start or recover it on the Mac." };
      if (!await this.listening(ip, job.pid)) return { ...base, serviceState: "failed", detail: "The owned SSH listener or host identity does not match its private configuration." };
      return { ...base, serviceState: "running" };
    } catch (error) { return { ...base, serviceState: "failed", detail: (error as Error).message }; }
  }

  private async currentIPv4(): Promise<string> {
    const status = await readTailscaleStatus(this.run, 2_000);
    if (!status.ok || !status.status.running) throw new GatewayError("conflict", "Tailscale is not running and online; SSH was not reconfigured");
    const addresses = status.status.self.filter(isMacTerminalIPv4);
    if (addresses.length !== 1) throw new GatewayError("conflict", "Tailscale must report exactly one 100.x IPv4 address");
    const ip = addresses[0]!;
    const interfaces = await this.command("/sbin/ifconfig", ["-a"]);
    let activeTailnet = false;
    let assigned = 0;
    for (const line of interfaces.split("\n")) {
      if (/^\S/u.test(line)) activeTailnet = /^utun\d+:/u.test(line) && /[<,]UP[,>]/u.test(line);
      if (activeTailnet && line.trim().split(/\s+/u).slice(0, 2).join(" ") === `inet ${ip}`) assigned += 1;
    }
    if (assigned !== 1) throw new GatewayError("conflict", "Tailscale's IPv4 address is not uniquely assigned to an active utun interface");
    return ip;
  }

  private config(ip: string): string {
    return [`AddressFamily inet`, `Port ${this.port}`, `ListenAddress ${ip}`, `HostKey "${this.hostKeyPath}"`,
      `AuthorizedKeysFile "${this.keys.path}"`, `PidFile "${join(this.root, "sshd.pid")}"`, `AllowUsers ${this.username}`,
      "AuthenticationMethods publickey", "PubkeyAuthentication yes", "PubkeyAcceptedAlgorithms ecdsa-sha2-nistp256",
      "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "StrictModes yes", "PermitRootLogin no",
      "DisableForwarding yes", "PermitUserEnvironment no", "PermitUserRC no", "PermitTTY yes", ""].join("\n");
  }

  private plist(): string {
    const args = ["/usr/sbin/sshd", "-D", "-e", "-f", this.configPath].map(value => `<string>${xml(value)}</string>`).join("");
    return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>${this.label}</string><key>Program</key><string>/usr/sbin/sshd</string><key>ProgramArguments</key><array>${args}</array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer><key>AbandonProcessGroup</key><true/></dict></plist>\n`;
  }

  private async identity(create: boolean, fence: () => void = () => {}): Promise<string | undefined> {
    const privateExists = await this.secureFile(this.hostKeyPath);
    const publicText = await this.text(`${this.hostKeyPath}.pub`);
    if (!privateExists) {
      if (publicText || await this.text(this.configPath) || await this.text(this.plistPath)) throw new GatewayError("conflict", "Private SSH host key is missing; automatic rotation is forbidden");
      if (!create) return undefined;
      const temporary = `${this.hostKeyPath}.${randomBytes(6).toString("hex")}`;
      try {
        await this.command("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "TronMacTerminal", "-f", temporary]);
        await chmod(`${temporary}.pub`, 0o600);
        fence();
        await durableAtomicWriteText(this.hostKeyPath, await readFile(temporary, "utf8"));
        fence();
        await durableAtomicWriteText(`${this.hostKeyPath}.pub`, await readFile(`${temporary}.pub`, "utf8"));
      } finally {
        await rm(temporary, { force: true });
        await rm(`${temporary}.pub`, { force: true });
      }
    }
    const derived = (await this.command("/usr/bin/ssh-keygen", ["-y", "-f", this.hostKeyPath])).trim().split(/\s+/u).slice(0, 2).join(" ");
    if (!derived.startsWith("ssh-ed25519 ")) throw new GatewayError("conflict", "Invalid private SSH host identity");
    const stored = await this.text(`${this.hostKeyPath}.pub`);
    if (stored === undefined) {
      if (!create) throw new GatewayError("conflict", "Private SSH public identity is incomplete; restore its saved public identity on the Mac");
      await durableAtomicWriteText(`${this.hostKeyPath}.pub`, `${derived}\n`);
    } else if (stored.trim().split(/\s+/u).slice(0, 2).join(" ") !== derived) {
      throw new GatewayError("conflict", "Private SSH host identity is corrupt; automatic rotation is forbidden");
    }
    return derived;
  }

  private async validate(config: string): Promise<void> {
    const candidate = join(this.root, `candidate-${randomBytes(6).toString("hex")}`);
    try {
      await durableAtomicWriteText(candidate, config);
      await this.command("/usr/sbin/sshd", ["-t", "-f", candidate]);
    } finally { await rm(candidate, { force: true }); }
  }

  private async start(fence: () => void): Promise<void> {
    await this.enabled();
    const ip = await this.currentIPv4();
    await this.command("/bin/launchctl", ["print", this.domain]);
    await this.identity(true, fence);
    const config = this.config(ip);
    await this.validate(config);
    const existing = await this.job();
    if (existing) {
      if ((await this.status()).serviceState === "running") return;
      throw new GatewayError("conflict", "An owned SSH job already exists but is not healthy; explicit recovery is required");
    }
    const prior = await this.text(this.configPath);
    if (prior && prior !== config) throw new GatewayError("conflict", "SSH bind address changed; explicit recovery is required");
    if ((await this.listeners()).length) throw new GatewayError("conflict", "SSH port is occupied; no process was stopped and no alternate port was selected");
    fence();
    await durableAtomicWriteText(this.configPath, config);
    await durableAtomicWriteText(this.plistPath, this.plist());
    try {
      fence();
      await this.command("/bin/launchctl", ["bootstrap", this.domain, this.plistPath]);
      for (let attempt = 0; attempt < 30; attempt += 1) {
        const job = await this.job();
        if (job?.running && job.pid && await this.listening(ip, job.pid)) {
          if (await this.currentIPv4() !== ip) throw new GatewayError("conflict", "Tailscale changed during SSH startup");
          return;
        }
        await new Promise(resolve => setTimeout(resolve, 100));
        fence();
      }
      throw new GatewayError("conflict", "The owned SSH job did not establish its exact IPv4 listener");
    } catch (error) {
      fence();
      await this.stop(fence);
      throw error;
    }
  }

  private async stop(fence: () => void): Promise<void> {
    await this.enabled(); // Refuse an unowned on-disk plist before any mutation.
    if (await this.job()) {
      fence();
      await this.command("/bin/launchctl", ["bootout", `${this.domain}/${this.label}`]);
      if (await this.job()) throw new GatewayError("conflict", "The owned SSH job did not stop");
    }
    fence();
    if (await this.text(this.plistPath) !== undefined) await durableRemove(this.plistPath);
  }

  private async job(): Promise<Job | undefined> {
    const result = await this.run("/bin/launchctl", ["print", `${this.domain}/${this.label}`], 2_000);
    if (result.code !== 0 || result.timedOut) {
      if (!result.timedOut && (result.code === 113 || /Could not find service/u.test(result.error ?? ""))) return undefined;
      throw new GatewayError("conflict", "Cannot inspect the owned user-domain SSH job");
    }
    const field = (name: string) => result.output.match(new RegExp(`^\\s*${name} = (.+)$`, "mu"))?.[1]?.trim();
    const args = result.output.match(/arguments = \{\n([\s\S]*?)\n\s*\}/u)?.[1]?.split("\n").map(line => line.trim()).filter(Boolean);
    if (field("path") !== this.plistPath || field("program") !== "/usr/sbin/sshd"
      || args?.join("\0") !== ["/usr/sbin/sshd", "-D", "-e", "-f", this.configPath].join("\0")) {
      throw new GatewayError("conflict", "SSH label belongs to another configuration; nothing was stopped");
    }
    const pid = Number(field("pid"));
    return { running: field("state") === "running", ...(Number.isSafeInteger(pid) && pid > 0 ? { pid } : {}) };
  }

  private async listeners(): Promise<string[]> {
    const output = await this.command("/usr/sbin/netstat", ["-anl", "-p", "tcp"]);
    return output.split("\n").map(line => line.trim().split(/\s+/u)).filter(fields => fields[5] === "LISTEN"
      && fields[3]?.split(".").at(-1) === String(this.port)).map(fields => `${fields[0]} ${fields[3]}`);
  }

  private async listening(ip: string, pid: number): Promise<boolean> {
    if ((await this.listeners()).join("\n") !== `tcp4 ${ip}.${this.port}`) return false;
    const files = await this.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), `-iTCP:${this.port}`, "-sTCP:LISTEN", "-Fn"], 2_000);
    if (files.code !== 0 || !files.output.split("\n").includes(`p${pid}`) || !files.output.split("\n").includes(`n${ip}:${this.port}`)) return false;
    // Passive kernel ownership checks do not consume OpenSSH no-auth penalties.
    // The real client verifies the presented host key before authentication.
    return true;
  }

  private async secureDirectory(): Promise<void> {
    const stat = await lstat(this.root).catch(error => { if (missing(error)) return undefined; throw error; });
    if (stat && (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0)) {
      throw new GatewayError("conflict", "Private SSH directory is unsafe");
    }
  }

  private async secureFile(path: string): Promise<boolean> {
    const stat = await lstat(path).catch(error => { if (missing(error)) return undefined; throw error; });
    if (!stat) return false;
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0 || stat.size > 1024 * 1024) {
      throw new GatewayError("conflict", "Private SSH file ownership, permissions or size is unsafe");
    }
    return true;
  }

  private async text(path: string): Promise<string | undefined> {
    return await this.secureFile(path) ? readFile(path, "utf8") : undefined;
  }

  private async command(tool: string, args: string[]): Promise<string> {
    const result = await this.run(tool, args, 2_000);
    if (result.code !== 0 || result.timedOut) throw new GatewayError("conflict", `${tool.split("/").at(-1)} failed while preparing the owned SSH service`);
    return result.output;
  }

  private async mutate<T>(operation: (fence: () => void) => Promise<T>): Promise<T> {
    return this.mutex.run(async () => {
      if (process.platform !== "darwin" || process.getuid?.() === 0) throw new GatewayError("unsupported", "Private Mac SSH requires an ordinary macOS user");
      await mkdir(this.root, { recursive: true, mode: 0o700 });
      await this.secureDirectory();
      let compromised: Error | undefined;
      const release = await lockfile.lock(this.root, { realpath: true, retries: 0, onCompromised: error => { compromised = error; } });
      const fence = () => { if (compromised) throw new GatewayError("conflict", "SSH lifecycle ownership was lost"); };
      try { return await operation(fence); }
      finally { await release(); }
    });
  }
}
