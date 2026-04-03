#!/usr/bin/env node
// Outputs the json-render catalog prompt for AI-generated UI specs.
// Usage: node prompt.mjs

import { defineCatalog } from "@json-render/core";
import { schema } from "@json-render/react/schema";
import { shadcnComponentDefinitions } from "@json-render/shadcn/catalog";

const catalog = defineCatalog(schema, { components: shadcnComponentDefinitions });
console.log(catalog.prompt());
