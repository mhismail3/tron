// Print the Gateway settings schema (KEYS, RECORD_SUBJECTS, LAYERS) as JSON for
// `scripts/tron docs settings` (tools/docs/README.md). The schema module is loaded,
// not parsed, because keys are built in code (template ids, role maps, helpers).
// Node strips TypeScript; this hook maps the sources' `./x.js` specifiers to `./x.ts`.
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL?.endsWith(".ts")) {
      const source = new URL(`${specifier.slice(0, -3)}.ts`, context.parentURL);
      if (existsSync(fileURLToPath(source))) return nextResolve(source.href, context);
    }
    return nextResolve(specifier, context);
  },
});

const [schemaPath, typesPath] = process.argv.slice(2);
const schema = await import(pathToFileURL(schemaPath).href);
const types = await import(pathToFileURL(typesPath).href);
process.stdout.write(JSON.stringify({ layers: types.LAYERS, keys: schema.KEYS, subjects: schema.RECORD_SUBJECTS }));
