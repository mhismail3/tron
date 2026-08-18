import { homedir } from "node:os";
import { join } from "node:path";
import { readJson } from "../util/json.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

const LOCAL_CREDENTIAL_MAX_BYTES = 64 * 1_024;

export async function readLocalCredential(tronHome: string): Promise<string> {
  const path = join(tronHome, "gateway", "local-auth.json");
  let document: Record<string, unknown>;
  try { document = await readJson<Record<string, unknown>>(path, {}, LOCAL_CREDENTIAL_MAX_BYTES); }
  catch { throw new Error(`Tron local credential is missing or invalid at ${path.replace(homedir(), "~")}`); }
  const keys = Object.keys(document);
  if (keys.length !== 4 || !keys.every((key) => ["version", "bearerToken", "purpose", "lastUpdated"].includes(key))
    || document.version !== 2 || document.purpose !== "local-wrapper-health"
    || typeof document.lastUpdated !== "string" || !isGatewayTimestamp(document.lastUpdated)
    || typeof document.bearerToken !== "string" || Buffer.byteLength(document.bearerToken) < 32
    || Buffer.byteLength(document.bearerToken) > 256) {
    throw new Error(`Tron local credential is missing or invalid at ${path.replace(homedir(), "~")}`);
  }
  return document.bearerToken;
}
