import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

// Apple's security.c uses a 4096-byte interactive input buffer. Bound the
// entire escaped UTF-8 line so truncation cannot lose the explicit keychain.
const SECURITY_INPUT_BUFFER_BYTES = 4_096;

function securityCommandArgument(value: string): string {
  if (/[\u0000-\u001f\u007f-\u009f]/.test(value) || Buffer.from(value).toString("utf8") !== value) throw new Error("Connector credential is invalid");
  // security.c split_line is not a shell: inside double quotes, a backslash
  // escapes the next character. Escape both backslashes and double quotes.
  return `"${value.replace(/[\\"]/g, "\\$&")}"`;
}

/** The Keychain service the Gateway credential adapter reads. */
export const CONNECTOR_CREDENTIAL_SERVICE = "Tron Connector Credentials";

/** Connector credentials are addressed by opaque references, never copied into
 * knowledge state or DTOs. The Mac implementation reads the dedicated Tron
 * Keychain service without placing a secret in argv or logs. Writes accept only
 * printable ASCII tokens: security's `find-generic-password -w` emits unmarked
 * hex for non-printable bytes, making other values ambiguous to read back. */
export interface ConnectorCredentialStore {
  read(reference: string): Promise<string | undefined>;
}

export interface WritableConnectorCredentialStore extends ConnectorCredentialStore {
  write(reference: string, value: string): Promise<void>;
  delete(reference: string): Promise<void>;
}

/** Configuration admission must bind an opaque credential reference to the
 * connector that will consume it. The generic syntax remains useful to the
 * Mac Keychain adapter (including Jev), but it is not a provider admission
 * check by itself. */
export function isConnectorCredentialReference(reference: string, connector: "raindrop" | "x"): boolean {
  return new RegExp(`^connector:${connector}:[A-Za-z0-9._:-]{1,160}$`).test(reference);
}

export class MacKeychainConnectorCredentialStore implements WritableConnectorCredentialStore {
  constructor(
    private readonly service = CONNECTOR_CREDENTIAL_SERVICE,
    /** Test dependency: the fixture owns this private keychain's lifetime. */
    private readonly keychainPath?: string,
  ) {
    if ((process.env.VITEST || process.env.NODE_ENV === "test") && !keychainPath) throw new Error("Connector credential tests require an explicit keychain path");
  }

  async read(reference: string): Promise<string | undefined> {
    if (!/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(reference)) return undefined;
    try {
      const result = await execFileAsync("security", ["find-generic-password", "-s", this.service, "-a", reference, "-w", ...this.keychainArguments()], { maxBuffer: 8 * 1024, windowsHide: true });
      // Remove the CLI's output newline, not whitespace belonging to the secret.
      const value = result.stdout.replace(/\n$/, "");
      return value.length > 0 && value.length <= 8_192 ? value : undefined;
    } catch {
      return undefined;
    }
  }

  async write(reference: string, value: string): Promise<void> {
    this.assertWritable(reference, value);
    const command = ["add-generic-password", "-U", "-s", this.service, "-a", reference, "-w", value, ...this.keychainArguments()].map(securityCommandArgument).join(" ") + "\n";
    if (Buffer.byteLength(command, "utf8") >= SECURITY_INPUT_BUFFER_BYTES) throw new Error("Mac Keychain credential command is too long");
    // Interactive command input supports an explicit keychain without putting
    // the secret in argv. Production and tests share this stdin-only path.
    await new Promise<void>((resolve, reject) => {
      const child = spawn("security", ["-i"], { stdio: ["pipe", "ignore", "ignore"], windowsHide: true });
      const failed = () => reject(new Error("Mac Keychain credential could not be stored"));
      child.once("error", failed);
      child.stdin.once("error", failed);
      child.once("close", code => code === 0 ? resolve() : failed());
      child.stdin.end(command);
    });
    if (await this.read(reference) !== value) throw new Error("Mac Keychain credential could not be verified");
  }

  async delete(reference: string): Promise<void> {
    if (!/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(reference)) throw new Error("Connector credential reference is invalid");
    try { await execFileAsync("security", ["delete-generic-password", "-s", this.service, "-a", reference, ...this.keychainArguments()], { maxBuffer: 1_024, windowsHide: true }); }
    catch { /* Deletion is idempotent; do not reveal Keychain diagnostics. */ }
  }

  private keychainArguments(): string[] {
    return this.keychainPath === undefined ? [] : [this.keychainPath];
  }

  private assertWritable(reference: string, value: string): void {
    if (!/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(reference) || typeof value !== "string" || value.length < 1 || value.length > 8_192) throw new Error("Connector credential is invalid");
    if (/[^\x20-\x7e]/.test(value)) throw new TypeError("Connector credential is invalid: expected printable ASCII");
  }
}
