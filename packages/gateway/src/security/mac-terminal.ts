import { randomBytes } from "node:crypto";
import { lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { syncDurably } from "../foundation/durable-json.js";

/** Private authorized_keys store used only by MacTerminalService. Marked
 * device lines are logged settings resources; unrelated bytes are preserved.
 * No production caller points this store at the user’s global SSH directory. */

/** The marker that identifies a Tron line. Anything after it is commentary. */
const MAC_TERMINAL_MARKER = "tron-mac-terminal:";
/** Defense in depth: the private service accepts device keys only from Tailnet IPv4. */
export const MAC_TERMINAL_SOURCES = "100.64.0.0/10";
const KEY_OPTIONS = `from="${MAC_TERMINAL_SOURCES}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc`;
/** The iPhone's key is a Secure Enclave P-256 key; nothing else is admitted. */
const KEY_TYPE = "ecdsa-sha2-nistp256";
const MAXIMUM_AUTHORIZED_KEYS_BYTES = 1024 * 1024;
const DEVICE_ID = /^[A-Za-z0-9-]{1,100}$/u;

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

function validateMacTerminalDevice(deviceId: string): string {
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

function macTerminalLine(device: string, key: string): string {
  return `${KEY_OPTIONS} ${key} ${MAC_TERMINAL_MARKER}${device} Tron Mac Terminal key for one paired iPhone; delete this line to revoke it`;
}

export class MacTerminalKeys {
  private readonly lock = new AsyncMutex();

  /** The private service’s authorization directory; fixtures name their own. */
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
