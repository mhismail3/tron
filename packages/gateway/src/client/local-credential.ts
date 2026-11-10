import { homedir } from "node:os";
import { isLocalAuthDocument } from "../security/device-store.js";
import { readSecureJson } from "../foundation/secure-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const LOCAL_CREDENTIAL_MAX_BYTES = 64 * 1_024;

export async function readLocalCredential(tronHome: string): Promise<string> {
  const path = tronHomePath(tronHome, "gateway/local-auth.json");
  try {
    const result = await readSecureJson<Record<string, unknown>>(path, LOCAL_CREDENTIAL_MAX_BYTES);
    if (result.present && isLocalAuthDocument(result.value)) return result.value.bearerToken;
  } catch { }
  throw new Error(`Tron local credential is missing or invalid at ${path.replace(homedir(), "~")}`);
}
