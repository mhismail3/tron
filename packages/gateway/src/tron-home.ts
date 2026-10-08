import { resolveTronHomePath } from "./tron-home-environment-policy.mjs";
import { GatewayError } from "./errors.js";

/**
 * Resolves the Tron data directory from the environment. Kept free of
 * third-party imports because the startup entrypoint uses it to record
 * failures of the Gateway's own module graph.
 */
export function resolveTronHome(environment = process.env): string {
  try {
    return resolveTronHomePath(environment);
  } catch (error) {
    if (error instanceof Error) throw new GatewayError("invalid_request", error.message);
    throw error;
  }
}
