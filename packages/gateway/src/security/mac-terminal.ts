import { randomBytes } from "node:crypto";
import { lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { syncDurably } from "../foundation/durable-json.js";

const MAC_TERMINAL_MARKER = "tron-mac-terminal:";
export const MAC_TERMINAL_SOURCES = "100.64.0.0/10";
const KEY_OPTIONS = `from="${MAC_TERMINAL_SOURCES}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc`;
const KEY_TYPE = "ecdsa-sha2-nistp256";
const MAXIMUM_AUTHORIZED_KEYS_BYTES = 1024 * 1024;
const DEVICE_ID = /^[A-Za-z0-9-]{1,100}$/u;

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

function validateMacTerminalDevice(deviceId: string): string {
  if (!DEVICE_ID.test(deviceId)) throw new GatewayError("invalid_request", "device must be a paired device id");
  return deviceId;
}

function parseLine(line: string): { device: string; key: string } | undefined {
  const tokens = line.trim().split(/\s+/u);
  const marker = tokens.find(token => token.startsWith(MAC_TERMINAL_MARKER));
  const type = tokens.indexOf(KEY_TYPE);
  if (!marker || type < 0 || type + 1 >= tokens.length) return undefined;
  const device = marker.slice(MAC_TERMINAL_MARKER.length);
  if (!DEVICE_ID.test(device)) return undefined;
  return { device, key: `${KEY_TYPE} ${tokens[type + 1]}` };
}

function macTerminalLine(device: string, key: string): string {
  return `${KEY_OPTIONS} ${key} ${MAC_TERMINAL_MARKER}${device} Tron Mac Terminal key for one paired iPhone; delete this line to revoke it`;
}

export class MacTerminalKeys {
  private readonly lock = new AsyncMutex();

  constructor(readonly sshDirectory: string) {}

  get path(): string { return join(this.sshDirectory, "authorized_keys"); }

  async read(): Promise<Record<string, string>> {
    const keys: Record<string, string> = {};
    for (const line of (await this.readLines()).lines) {
      const parsed = parseLine(line.toString("latin1"));
      if (parsed) keys[parsed.device] = parsed.key;
    }
    return keys;
  }

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

  private async readLines(): Promise<{ lines: Buffer[]; trailingNewline: boolean; exists: boolean }> {
    let bytes: Buffer;
    try {
      const stat = await lstat(this.path);
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
