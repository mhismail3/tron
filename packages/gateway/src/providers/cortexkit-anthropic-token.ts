import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";

/** The wire API CortexKit's Pi provider registers for `anthropic`. */
export const CORTEXKIT_ANTHROPIC_API = "cortexkit-anthropic-messages";

const MAX_FILE_BYTES = 1024 * 1024;
/** A token this close to expiry may lapse in flight; CortexKit refreshes it on its next request. */
const EXPIRY_MARGIN_MS = 60_000;

/**
 * Where CortexKit 2.x keeps Pi's account pool: beside its sidecar path, which is
 * `PI_ANTHROPIC_AUTH_FILE` when set and otherwise the Pi agent directory
 * (CortexKit docs/custody-state-machine.md, "Storage").
 */
export function cortexKitPoolDirectory(agentDir: string, env: NodeJS.ProcessEnv = process.env): string {
  const sidecar = env.PI_ANTHROPIC_AUTH_FILE?.trim();
  return sidecar ? dirname(sidecar) : agentDir;
}

/**
 * The main account's current Anthropic OAuth access token from CortexKit 2.x's
 * local pool, or undefined when there is none to use.
 *
 * CortexKit 2.x moves the Anthropic login out of Pi's auth.json into its own
 * pool, so Pi resolves no bearer for `anthropic`. CortexKit owns that
 * credential: this reads it and never refreshes or writes, because a refresh
 * rotates the token CortexKit serves with. A vault-custody pool, a non-OAuth
 * main account, an unknown file version or a token near expiry yield undefined.
 */
export async function readCortexKitAnthropicAccessToken(directory: string, now: number): Promise<string | undefined> {
  const pool = await readJsonObject(join(directory, "anthropic-auth-pool.json"));
  if (pool?.version !== 1 || typeof pool.mainAccountId !== "string") return undefined;
  const custody = object(pool.claustrum)?.mode;
  if (custody !== undefined && custody !== "local") return undefined;
  const accounts = Array.isArray(pool.accounts) ? pool.accounts : [];
  const main = accounts.map(object).find((account) => account?.id === pool.mainAccountId);
  if (main?.type !== "oauth") return undefined;
  const state = await readJsonObject(join(directory, "anthropic-auth-pool-state.json"));
  if (state?.version !== 1) return undefined;
  const credential = object(object(state.accounts)?.[pool.mainAccountId]);
  const access = credential?.access;
  const expires = credential?.expires;
  if (typeof access !== "string" || access.length === 0 || typeof expires !== "number") return undefined;
  return expires - now > EXPIRY_MARGIN_MS ? access : undefined;
}

async function readJsonObject(path: string): Promise<Record<string, unknown> | undefined> {
  try {
    const bytes = await readFile(path);
    if (bytes.byteLength > MAX_FILE_BYTES) return undefined;
    return object(JSON.parse(bytes.toString("utf8")));
  } catch {
    // Absent, unreadable or mid-replace: no token this read.
    return undefined;
  }
}

function object(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}
