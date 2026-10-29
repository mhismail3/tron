import { registerHooks } from "node:module";

// Child-process TypeScript resolution only. Receipt durability cuts remain in
// apps-crash-child; retired source-install/removal cuts have no current owner.
registerHooks({
  resolve(specifier, context, nextResolve) {
    try { return nextResolve(specifier, context); }
    catch (error) {
      if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context);
      throw error;
    }
  },
});
