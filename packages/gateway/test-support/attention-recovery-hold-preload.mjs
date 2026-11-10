import fs from "node:fs/promises";
import { existsSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";

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
