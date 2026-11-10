import { resolveTronHomePath } from "./tron-home-environment-policy.mjs";
import { GatewayError } from "./errors.js";

export function resolveTronHome(environment = process.env): string {
  try {
    return resolveTronHomePath(environment);
  } catch (error) {
    if (error instanceof Error) throw new GatewayError("invalid_request", error.message);
    throw error;
  }
}
