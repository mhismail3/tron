import { homedir } from "node:os";
import { join } from "node:path";
import { readSecureJson } from "../util/secure-json.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

const LOCAL_CREDENTIAL_MAX_BYTES = 64 * 1_024;

export async function readLocalCredential(tronHome: string): Promise<string> {
  const path = join(tronHome, "gateway", "local-auth.json");
  let document: unknown;
  try {
    const result = await readSecureJson<Record<string, unknown>>(path, LOCAL_CREDENTIAL_MAX_BYTES);
    if (!result.present) throw new Error("missing");
    document = result.value;
  } catch { throw new Error(`Tron local credential is missing or invalid at ${path.replace(homedir(), "~")}`); }
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error(`Tron local credential is missing or invalid at ${path.replace(homedir(), "~")}`);
  }
  const record = document as Record<string, unknown>;
  const keys = Object.keys(record);
  if (keys.length !== 4 || !keys.every((key) => ["version", "bearerToken", "purpose", "lastUpdated"].includes(key))
    || record.version !== 2 || record.purpose !== "local-wrapper-health"
    || typeof record.lastUpdated !== "string" || !isGatewayTimestamp(record.lastUpdated)
    || typeof record.bearerToken !== "string" || Buffer.byteLength(record.bearerToken) < 32
    || Buffer.byteLength(record.bearerToken) > 256) {
    throw new Error(`Tron local credential is missing or invalid at ${path.replace(homedir(), "~")}`);
  }
  return record.bearerToken;
}
