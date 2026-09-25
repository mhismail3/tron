import { execFile } from "node:child_process";
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

/** Configuration admission must bind an opaque credential reference to the
 * connector that will consume it. The generic syntax remains useful to the
 * Mac Keychain adapter (including Jev), but it is not a provider admission
 * check by itself. */
export function isConnectorCredentialReference(reference: string, connector: "raindrop" | "x"): boolean {
  return new RegExp(`^connector:${connector}:[A-Za-z0-9._:-]{1,160}$`).test(reference);
}

export class MacKeychainConnectorCredentialStore implements ConnectorCredentialStore {
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
}
