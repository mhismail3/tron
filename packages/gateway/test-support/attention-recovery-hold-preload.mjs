import fs from "node:fs/promises";
import { existsSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";

// Test-only preload for a Gateway process (#2235). Startup attention recovery
// runs after the listener is serving and ends by re-reading the runtime-marker
// directory. This holds that one read until the parent creates
// `${TRON_TEST_HOLD_ATTENTION_RECOVERY}.go`, after writing `.held`, so a client
// can deterministically reach the Gateway inside the post-listen recovery
// window. Nothing else is delayed or replaced.
const hold = process.env.TRON_TEST_HOLD_ATTENTION_RECOVERY;
if (hold) {
  const readdir = fs.readdir;
  fs.readdir = async (path, ...args) => {
    if (String(path).endsWith("/gateway/runtime-markers") && new Error().stack?.includes("recoverCanonicalAttention")) {
      writeFileSync(`${hold}.held`, "");
      while (!existsSync(`${hold}.go`)) await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return readdir(path, ...args);
  };
  syncBuiltinESMExports();
}
