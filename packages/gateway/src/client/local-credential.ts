import { homedir } from "node:os";
import { join } from "node:path";
import { isLocalAuthDocument } from "../security/device-store.js";
import { readSecureJson } from "../util/secure-json.js";

// The owning credential store bounds its own document at 4 KiB; this reader is
// reached from the terminal client and keeps its separate, larger bound.
const LOCAL_CREDENTIAL_MAX_BYTES = 64 * 1_024;

export async function readLocalCredential(tronHome: string): Promise<string> {
  const path = join(tronHome, "gateway", "local-auth.json");
  try {
    const result = await readSecureJson<Record<string, unknown>>(path, LOCAL_CREDENTIAL_MAX_BYTES);
    if (result.present && isLocalAuthDocument(result.value)) return result.value.bearerToken;
  } catch { /* Every boundary failure is reported as missing or invalid. */ }
  throw new Error(`Tron local credential is missing or invalid at ${path.replace(homedir(), "~")}`);
}
