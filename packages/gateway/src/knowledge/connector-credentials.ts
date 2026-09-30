import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** The Keychain service the Gateway credential adapter reads. */
export const CONNECTOR_CREDENTIAL_SERVICE = "Tron Connector Credentials";

/** Connector credentials are addressed by opaque references, never copied into
 * knowledge state or DTOs. The Mac implementation reads the dedicated Tron
 * Keychain service without placing a secret in argv or logs. */
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
  constructor(private readonly service = CONNECTOR_CREDENTIAL_SERVICE) {}

  async read(reference: string): Promise<string | undefined> {
    if (!/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(reference)) return undefined;
    try {
      const result = await execFileAsync("security", ["find-generic-password", "-s", this.service, "-a", reference, "-w"], { maxBuffer: 8 * 1024, windowsHide: true });
      const value = result.stdout.trim();
      return value.length > 0 && value.length <= 8_192 ? value : undefined;
    } catch {
      return undefined;
    }
  }

  async write(reference: string, value: string): Promise<void> {
    this.assertWritable(reference, value);
    // `security` prompts for the password when -w has no argument. Send the
    // secret through stdin instead of exposing it in process arguments.
    await new Promise<void>((resolve, reject) => {
      const child = spawn("security", ["add-generic-password", "-U", "-s", this.service, "-a", reference, "-w"], { stdio: ["pipe", "ignore", "ignore"], windowsHide: true });
      child.once("error", () => reject(new Error("Mac Keychain credential could not be stored")));
      child.once("close", code => code === 0 ? resolve() : reject(new Error("Mac Keychain credential could not be stored")));
      // `security` reads and confirms two password lines when stdin is not a
      // TTY. A single line can exit successfully while storing an empty value.
      child.stdin.end(`${value}\n${value}\n`);
    });
    if (await this.read(reference) !== value) throw new Error("Mac Keychain credential could not be verified");
  }

  async delete(reference: string): Promise<void> {
    if (!/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(reference)) throw new Error("Connector credential reference is invalid");
    try { await execFileAsync("security", ["delete-generic-password", "-s", this.service, "-a", reference], { maxBuffer: 1_024, windowsHide: true }); }
    catch { /* Deletion is idempotent; do not reveal Keychain diagnostics. */ }
  }

  private assertWritable(reference: string, value: string): void {
    if (!/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(reference) || typeof value !== "string" || value.length < 1 || value.length > 8_192 || /[\u0000\r\n]/.test(value)) throw new Error("Connector credential is invalid");
  }
}
