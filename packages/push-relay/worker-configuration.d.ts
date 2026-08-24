import type { PushRegistry } from "./src/registry";

declare global {
  namespace Cloudflare {
    interface Env {
      APNS_KEY_P8: string;
      APNS_KEY_ID: string;
      APNS_TEAM_ID: string;
      APPLE_TEAM_ID: string;
      PUSH_REGISTRY: DurableObjectNamespace<PushRegistry>;
    }
  }
}

export {};
