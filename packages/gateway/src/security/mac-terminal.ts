import { randomBytes } from "node:crypto";
import { lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { Socket } from "node:net";
import { userInfo } from "node:os";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { syncDurably } from "../util/durable-json.js";
import { readTailscaleStatus, runBoundedCommand, type BoundedCommand } from "../transport/tailscale-peer.js";

/**
 * Mac Terminal (README "Mac Terminal"): the iPhone opens a login shell on this
 * Mac through macOS Remote Login (the built-in sshd) over Tailscale, without the
 * Gateway. The Gateway's part ends at enrollment:
 *
 * - `MacTerminalKeys` owns this Mac's `~/.ssh/authorized_keys` lines that carry
 *   a `tron-mac-terminal:<device>` comment, one per paired iPhone. They are the
 *   `permissions.macTerminalKey` settings store, so enrolling and revoking go
 *   through the logged change path (approve floor; the maintainer's tap is the
 *   approval). Every other line of the file is preserved byte for byte.
 * - `MacTerminalHost` reports what the iPhone pins and dials: the login user,
 *   the MagicDNS name and Tailscale addresses, sshd's host keys, and whether
 *   Remote Login answers. Tron never turns Remote Login on.
 */

/** The marker that identifies a Tron line. Anything after it is commentary. */
export const MAC_TERMINAL_MARKER = "tron-mac-terminal:";
/** Tailscale's IPv4 CGNAT range and IPv6 ULA prefix: a Tron key is accepted
 * only from a tailnet source address, never from the LAN, loopback or Internet. */
export const MAC_TERMINAL_SOURCES = "100.64.0.0/10,fd7a:115c:a1e0::/48";
const KEY_OPTIONS = `from="${MAC_TERMINAL_SOURCES}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc`;
/** The iPhone's key is a Secure Enclave P-256 key; nothing else is admitted. */
const KEY_TYPE = "ecdsa-sha2-nistp256";
const MAXIMUM_AUTHORIZED_KEYS_BYTES = 1024 * 1024;
const DEVICE_ID = /^[A-Za-z0-9-]{1,100}$/u;
const SSH_PORT = 22;
const HOST_KEY_FILES = ["ssh_host_ed25519_key.pub", "ssh_host_ecdsa_key.pub"] as const;

/** A Tron line's public key, validated as an OpenSSH `ecdsa-sha2-nistp256`
 * key whose blob names the same type and curve and holds an uncompressed point. */
export function validateMacTerminalKey(value: unknown, field = "value"): string {
  if (typeof value !== "string") throw new GatewayError("invalid_request", `${field} must be an OpenSSH public key`);
  const parts = value.trim().split(/\s+/u);
  if (parts.length < 2 || parts[0] !== KEY_TYPE || !/^[A-Za-z0-9+/]+={0,2}$/u.test(parts[1]!)) {
    throw new GatewayError("invalid_request", `${field} must be an ${KEY_TYPE} public key`);
  }
  const blob = Buffer.from(parts[1]!, "base64");
  const fields: Buffer[] = [];
  let offset = 0;
  while (offset < blob.length && fields.length < 4) {
    if (offset + 4 > blob.length) break;
    const length = blob.readUInt32BE(offset);
    if (offset + 4 + length > blob.length) break;
    fields.push(blob.subarray(offset + 4, offset + 4 + length));
    offset += 4 + length;
  }
  if (fields.length !== 3 || offset !== blob.length || fields[0]!.toString() !== KEY_TYPE
    || fields[1]!.toString() !== "nistp256" || fields[2]!.length !== 65 || fields[2]![0] !== 0x04) {
    throw new GatewayError("invalid_request", `${field} is not a valid ${KEY_TYPE} key`);
  }
  return `${KEY_TYPE} ${parts[1]}`;
}

export function validateMacTerminalDevice(deviceId: string): string {
  if (!DEVICE_ID.test(deviceId)) throw new GatewayError("invalid_request", "device must be a paired device id");
  return deviceId;
}

/** The Tron device a line belongs to, and its key, or undefined for any other line. */
function parseLine(line: string): { device: string; key: string } | undefined {
  const tokens = line.trim().split(/\s+/u);
  const marker = tokens.find(token => token.startsWith(MAC_TERMINAL_MARKER));
  const type = tokens.indexOf(KEY_TYPE);
  if (!marker || type < 0 || type + 1 >= tokens.length) return undefined;
  const device = marker.slice(MAC_TERMINAL_MARKER.length);
  if (!DEVICE_ID.test(device)) return undefined;
  return { device, key: `${KEY_TYPE} ${tokens[type + 1]}` };
}

export function macTerminalLine(device: string, key: string): string {
  return `${KEY_OPTIONS} ${key} ${MAC_TERMINAL_MARKER}${device} Tron Mac Terminal key for one paired iPhone; delete this line to revoke it`;
}

export class MacTerminalKeys {
  private readonly lock = new AsyncMutex();

  /** `sshDirectory` is `~/.ssh` in production. A fixture names its own; a
   * Gateway built without one has no Mac Terminal store at all. */
  constructor(readonly sshDirectory: string) {}

  get path(): string { return join(this.sshDirectory, "authorized_keys"); }

  /** The Tron keys in the file now, by device. A hand-deleted line is simply
   * absent: the file is the store (F2), so a Mac-side removal is a revocation. */
  async read(): Promise<Record<string, string>> {
    const keys: Record<string, string> = {};
    for (const line of (await this.readLines()).lines) {
      const parsed = parseLine(line.toString("latin1"));
      if (parsed) keys[parsed.device] = parsed.key;
    }
    return keys;
  }

  /** Writes or removes one device's line under the store's lock, atomically,
   * preserving every other line exactly. */
  async set(device: string, key: string | null): Promise<void> {
    validateMacTerminalDevice(device);
    const admitted = key === null ? null : validateMacTerminalKey(key);
    await this.lock.run(async () => {
      const { lines, trailingNewline, exists } = await this.readLines();
      const kept = lines.filter(line => parseLine(line.toString("latin1"))?.device !== device);
      if (admitted !== null) kept.push(Buffer.from(macTerminalLine(device, admitted), "utf8"));
      if (!exists && admitted === null) return;
      const newline = Buffer.from("\n");
      const joined = kept.flatMap((line, index) => index === 0 ? [line] : [newline, line]);
      if (kept.length > 0 && (trailingNewline || admitted !== null)) joined.push(newline);
      await this.publish(Buffer.concat(joined));
    });
  }

  /** The file as raw lines: every line Tron does not own is written back with
   * exactly the bytes it had, whatever its encoding. */
  private async readLines(): Promise<{ lines: Buffer[]; trailingNewline: boolean; exists: boolean }> {
    let bytes: Buffer;
    try {
      const stat = await lstat(this.path);
      // Replacing a symlink with a file would silently move the user's keys.
      if (stat.isSymbolicLink() || !stat.isFile()) {
        throw new GatewayError("conflict", `${this.path} is not a regular file; Tron does not edit it`);
      }
      if (stat.size > MAXIMUM_AUTHORIZED_KEYS_BYTES) throw new GatewayError("conflict", `${this.path} is too large to edit safely`);
      bytes = await readFile(this.path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return { lines: [], trailingNewline: true, exists: false };
      throw error;
    }
    const trailingNewline = bytes.length > 0 && bytes[bytes.length - 1] === 0x0a;
    const body = trailingNewline ? bytes.subarray(0, -1) : bytes;
    const lines: Buffer[] = [];
    if (bytes.length > 0) {
      let start = 0;
      for (let index = 0; index <= body.length; index += 1) {
        if (index === body.length || body[index] === 0x0a) { lines.push(body.subarray(start, index)); start = index + 1; }
      }
    }
    return { lines, trailingNewline, exists: true };
  }

  private async publish(bytes: Buffer): Promise<void> {
    await mkdir(this.sshDirectory, { recursive: true, mode: 0o700 });
    const temporary = `${this.path}.tron-${process.pid}-${randomBytes(6).toString("hex")}.tmp`;
    try {
      const handle = await open(temporary, "wx", 0o600);
      try {
        await handle.writeFile(bytes);
        await syncDurably(handle);
      } finally {
        await handle.close();
      }
      await rename(temporary, this.path);
    } catch (error) {
      await rm(temporary, { force: true }).catch(() => {});
      throw error;
    }
  }
}

export interface MacTerminalStatus {
  /** The macOS account the shell logs in as: the Gateway's own user. */
  username: string;
  port: number;
  /** MagicDNS name first, then the Tailscale addresses. Empty off the tailnet. */
  hosts: string[];
  /** sshd's host public keys, which the iPhone pins. */
  hostKeys: string[];
  /** Whether sshd accepts a TCP connection. Remote Login listens on every
   * interface, so the loopback answers exactly as the Tailscale address would. */
  remoteLogin: "on" | "off" | "unknown";
  /** Whether this device's key is in authorized_keys now. */
  enrolled: boolean;
  /** The enrolled key, so the iPhone can tell its own key from a stale one. */
  enrolledKey?: string;
  /** The argv the iPhone's SSH session runs to reach the shell host that keeps
   * Mac Terminal's shells across disconnects (machine/mac-terminal-host.ts).
   * Absent when this Gateway has no compiled host; the iPhone then opens a
   * plain login shell that ends with its connection. */
  hostCommand?: string[];
}

export class MacTerminalHost {
  constructor(
    readonly keys: MacTerminalKeys,
    private readonly options: {
      hostKeyDirectory?: string;
      run?: BoundedCommand;
      port?: number;
      username?: () => string;
      hostCommand?: () => string[] | undefined;
    } = {},
  ) {}

  async status(device: string): Promise<MacTerminalStatus> {
    const port = this.options.port ?? SSH_PORT;
    const [hostKeys, hosts, keys] = await Promise.all([this.hostKeys(), this.tailnetHosts(), this.keys.read()]);
    const enrolledKey = keys[device];
    const hostCommand = this.options.hostCommand?.();
    return {
      username: (this.options.username ?? (() => userInfo().username))(),
      port,
      hosts,
      hostKeys,
      remoteLogin: await probeRemoteLogin(port),
      enrolled: enrolledKey !== undefined,
      ...(enrolledKey ? { enrolledKey } : {}),
      ...(hostCommand ? { hostCommand } : {}),
    };
  }

  private async hostKeys(): Promise<string[]> {
    const directory = this.options.hostKeyDirectory ?? "/etc/ssh";
    const keys: string[] = [];
    for (const name of HOST_KEY_FILES) {
      const text = await readFile(join(directory, name), "utf8").catch(() => undefined);
      const parts = text?.trim().split(/\s+/u);
      if (parts && parts.length >= 2) keys.push(`${parts[0]} ${parts[1]}`);
    }
    return keys;
  }

  private async tailnetHosts(): Promise<string[]> {
    const read = await readTailscaleStatus(this.options.run ?? runBoundedCommand, 2_000);
    if (!read.ok) return [];
    const name = read.status.selfDNSName?.replace(/\.$/u, "");
    return [...(name ? [name] : []), ...read.status.self];
  }
}

/** One bounded loopback TCP connect: refused is off, an accepted socket is on. */
function probeRemoteLogin(port: number): Promise<"on" | "off" | "unknown"> {
  return new Promise(resolve => {
    const socket = new Socket();
    const finish = (result: "on" | "off" | "unknown") => { socket.destroy(); resolve(result); };
    socket.setTimeout(1_500, () => finish("unknown"));
    socket.once("connect", () => finish("on"));
    socket.once("error", (error: NodeJS.ErrnoException) => finish(error.code === "ECONNREFUSED" ? "off" : "unknown"));
    socket.connect(port, "127.0.0.1");
  });
}
