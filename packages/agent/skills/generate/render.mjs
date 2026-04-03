#!/usr/bin/env node
//
// render.mjs — Server-side render a json-render spec to a standalone HTML file.
//
// Usage:
//   node render.mjs <input-spec.json> [output.html]
//   node render.mjs --version
//
// The input JSON must have the json-render spec format with root + elements.
// Output defaults to ./index.html in the same directory as the input.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname, basename } from "node:path";
import { createElement } from "react";
import { renderToString } from "react-dom/server";

const VERSION = "1.0.0";

// ── CLI ────────────────────────────────────────────────────

const args = process.argv.slice(2);

if (args.includes("--version")) {
  console.log(`tron-json-render ${VERSION}`);
  process.exit(0);
}

if (args.length === 0) {
  console.error("Usage: node render.mjs <input-spec.json> [output.html]");
  process.exit(1);
}

const inputPath = resolve(args[0]);
const outputPath = args[1]
  ? resolve(args[1])
  : resolve(dirname(inputPath), "index.html");

// ── Load spec ──────────────────────────────────────────────

let specJson;
try {
  specJson = readFileSync(inputPath, "utf-8");
} catch (err) {
  console.error(`Failed to read input: ${err.message}`);
  process.exit(1);
}

let spec;
try {
  spec = JSON.parse(specJson);
} catch (err) {
  console.error(`Invalid JSON: ${err.message}`);
  process.exit(1);
}

// ── Import json-render (dynamic to handle missing deps gracefully) ──

let Renderer, JSONUIProvider, defineRegistry, defineCatalog, shadcnComponentDefinitions, shadcnComponents, schema;

try {
  const core = await import("@json-render/core");
  const react = await import("@json-render/react");
  const shadcnCatalog = await import("@json-render/shadcn/catalog");
  const shadcnImpl = await import("@json-render/shadcn");

  defineCatalog = core.defineCatalog;
  schema = react.schema ?? (await import("@json-render/react/schema")).schema;
  Renderer = react.Renderer;
  JSONUIProvider = react.JSONUIProvider;
  defineRegistry = react.defineRegistry;
  shadcnComponentDefinitions = shadcnCatalog.shadcnComponentDefinitions;
  shadcnComponents = shadcnImpl.shadcnComponents;
} catch (err) {
  console.error(`Failed to load json-render packages: ${err.message}`);
  console.error("Run: cd ~/.tron/tools/json-render && npm install");
  process.exit(1);
}

// ── Build catalog + registry ───────────────────────────────

let catalog, registry;
try {
  catalog = defineCatalog(schema, {
    components: shadcnComponentDefinitions,
  });

  const reg = defineRegistry(catalog, {
    components: shadcnComponents,
  });
  registry = reg.registry;
} catch (err) {
  console.error(`Failed to build catalog/registry: ${err.message}`);
  process.exit(1);
}

// ── Render ─────────────────────────────────────────────────

let html;
try {
  const app = createElement(
    JSONUIProvider,
    { initialState: spec.state ?? {} },
    createElement(Renderer, { spec, registry })
  );
  html = renderToString(app);
} catch (err) {
  console.error(`Render failed: ${err.message}`);
  process.exit(1);
}

// ── Write standalone HTML ──────────────────────────────────

const title = spec.title ?? "Generated UI";

const fullHtml = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(title)}</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    body { font-family: system-ui, -apple-system, sans-serif; }
    /* shadcn default CSS variables */
    :root {
      --background: 0 0% 100%;
      --foreground: 0 0% 3.9%;
      --card: 0 0% 100%;
      --card-foreground: 0 0% 3.9%;
      --popover: 0 0% 100%;
      --popover-foreground: 0 0% 3.9%;
      --primary: 0 0% 9%;
      --primary-foreground: 0 0% 98%;
      --secondary: 0 0% 96.1%;
      --secondary-foreground: 0 0% 9%;
      --muted: 0 0% 96.1%;
      --muted-foreground: 0 0% 45.1%;
      --accent: 0 0% 96.1%;
      --accent-foreground: 0 0% 9%;
      --destructive: 0 84.2% 60.2%;
      --destructive-foreground: 0 0% 98%;
      --border: 0 0% 89.8%;
      --input: 0 0% 89.8%;
      --ring: 0 0% 3.9%;
      --radius: 0.5rem;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --background: 0 0% 3.9%;
        --foreground: 0 0% 98%;
        --card: 0 0% 3.9%;
        --card-foreground: 0 0% 98%;
        --popover: 0 0% 3.9%;
        --popover-foreground: 0 0% 98%;
        --primary: 0 0% 98%;
        --primary-foreground: 0 0% 9%;
        --secondary: 0 0% 14.9%;
        --secondary-foreground: 0 0% 98%;
        --muted: 0 0% 14.9%;
        --muted-foreground: 0 0% 63.9%;
        --accent: 0 0% 14.9%;
        --accent-foreground: 0 0% 98%;
        --destructive: 0 62.8% 30.6%;
        --destructive-foreground: 0 0% 98%;
        --border: 0 0% 14.9%;
        --input: 0 0% 14.9%;
        --ring: 0 0% 83.1%;
      }
    }
  </style>
</head>
<body class="bg-background text-foreground min-h-screen p-6">
  <div id="root">${html}</div>

  <!-- Hydration: re-mount React for interactivity -->
  <script type="importmap">
  {
    "imports": {
      "react": "https://esm.sh/react@19",
      "react-dom": "https://esm.sh/react-dom@19",
      "react-dom/client": "https://esm.sh/react-dom@19/client",
      "react/jsx-runtime": "https://esm.sh/react@19/jsx-runtime",
      "@json-render/core": "https://esm.sh/@json-render/core@0.16",
      "@json-render/react": "https://esm.sh/@json-render/react@0.16",
      "@json-render/react/schema": "https://esm.sh/@json-render/react@0.16/schema",
      "@json-render/shadcn": "https://esm.sh/@json-render/shadcn@0.16",
      "@json-render/shadcn/catalog": "https://esm.sh/@json-render/shadcn@0.16/catalog"
    }
  }
  </script>
  <script type="module">
    import { createElement } from "react";
    import { hydrateRoot } from "react-dom/client";
    import { Renderer, JSONUIProvider } from "@json-render/react";
    import { defineCatalog } from "@json-render/core";
    import { schema } from "@json-render/react/schema";
    import { shadcnComponentDefinitions } from "@json-render/shadcn/catalog";
    import { shadcnComponents } from "@json-render/shadcn";
    import { defineRegistry } from "@json-render/react";

    const catalog = defineCatalog(schema, { components: shadcnComponentDefinitions });
    const { registry } = defineRegistry(catalog, { components: shadcnComponents });
    const spec = ${JSON.stringify(spec)};

    const app = createElement(
      JSONUIProvider,
      { initialState: spec.state ?? {} },
      createElement(Renderer, { spec, registry })
    );
    hydrateRoot(document.getElementById("root"), app);
  </script>
</body>
</html>`;

try {
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, fullHtml, "utf-8");
  console.log(`Rendered: ${outputPath}`);
} catch (err) {
  console.error(`Failed to write output: ${err.message}`);
  process.exit(1);
}

function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
