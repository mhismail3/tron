import { registerHooks, syncBuiltinESMExports } from "node:module";
import fs from "node:fs/promises";

registerHooks({
  resolve(specifier, context, nextResolve) {
    try { return nextResolve(specifier, context); }
    catch (error) {
      if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context);
      throw error;
    }
  },
});

if (process.env.TRON_APPS_CRASH_CUT === "retirement") {
  const rm = fs.rm;
  fs.rm = async (path, ...args) => {
    if (String(path).startsWith(process.env.TRON_APPS_CRASH_ROOT + "/tron/workspace/state/apps/.removed-")
      && /\/\.removed-[a-z0-9-]+-[a-f0-9]{12}$/.test(String(path))) {
      // remove() has already fsynced the renamed parent; hold before erasing data.
      await globalThis[Symbol.for("tron.apps.crashCut")]();
    }
    return rm(path, ...args);
  };
  syncBuiltinESMExports();
}

// Install before durable-json captures its production FS functions. Only this
// child and its exact temporary Apps sources can encounter this test-only cut.
if (process.env.TRON_APPS_CRASH_CUT === "source") {
  const open = fs.open;
  fs.open = async (...args) => {
    const handle = await open(...args);
    const path = String(args[0]);
    if (path.startsWith(process.env.TRON_APPS_CRASH_ROOT + "/tron/workspace/state/apps/")
      && /\/sources\/[a-f0-9]{64}\.swift\..*\.tmp$/.test(path)) {
      const sync = handle.sync.bind(handle);
      handle.sync = async () => {
        await sync();
        await globalThis[Symbol.for("tron.apps.crashCut")]();
      };
    }
    return handle;
  };
  syncBuiltinESMExports();
}
