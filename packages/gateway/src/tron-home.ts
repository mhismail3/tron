import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { GatewayError } from "./errors.js";

/**
 * Resolves the Tron data directory from the environment. Kept free of
 * third-party imports because the startup entrypoint uses it to record
 * failures of the Gateway's own module graph.
 */
export function resolveTronHome(environment = process.env): string {
  const explicit = environment.TRON_DATA_DIR;
  if (explicit) {
    if (!isAbsolute(explicit)) throw new GatewayError("invalid_request", "TRON_DATA_DIR must be absolute");
    return resolve(explicit);
  }
  const homeName = environment.TRON_HOME_NAME;
  if (homeName) {
    if (homeName === "." || homeName === ".." || homeName.includes("/")) {
      throw new GatewayError("invalid_request", "TRON_HOME_NAME must be one home-relative directory name");
    }
    return join(homedir(), homeName);
  }
  return join(homedir(), ".tron");
}
