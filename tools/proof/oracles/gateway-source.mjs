// Purpose: import shipped Gateway TypeScript sources directly under the pinned Node. Gateway sources import
// each other as `./x.js` (their compiled names), so a relative `.js` specifier inside packages/gateway/src
// resolves to its `.ts` file, and those files are transformed (not only stripped: they use parameter
// properties) with Node's own TypeScript transform. Oracles and their tests load sources through it.
import { existsSync, readFileSync } from "node:fs";
import { registerHooks, stripTypeScriptTypes } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const GATEWAY_SRC = join(resolve(dirname(fileURLToPath(import.meta.url)), "../../.."), "packages/gateway/src");
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL?.startsWith("file:")
      && fileURLToPath(context.parentURL).startsWith(`${GATEWAY_SRC}/`)) {
      const ts = resolve(dirname(fileURLToPath(context.parentURL)), specifier.replace(/\.js$/, ".ts"));
      if (existsSync(ts)) return next(pathToFileURL(ts).href, context);
    }
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url.startsWith("file:") && url.endsWith(".ts") && fileURLToPath(url).startsWith(`${GATEWAY_SRC}/`)) {
      const source = stripTypeScriptTypes(readFileSync(fileURLToPath(url), "utf8"), { mode: "transform", sourceUrl: url });
      return { format: "module", source, shortCircuit: true };
    }
    return next(url, context);
  },
});

/** Imports packages/gateway/src/<path> (a .ts file). */
export function importGatewaySource(path) {
  return import(pathToFileURL(join(GATEWAY_SRC, path)).href);
}
