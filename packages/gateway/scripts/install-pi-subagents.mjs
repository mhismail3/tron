#!/usr/bin/env node
// Activation supplies its exact isolated home.
import { ManagedSubagents } from "../dist/kernel/delegation/managed-subagents.js";

if (process.argv.length !== 3 || !process.argv[2]?.trim()) {
  console.error("Usage: npm run install:pi-subagents -- <gateway-home> (requires npm run build)");
  process.exitCode = 1;
} else {
  try {
    console.log(new ManagedSubagents(process.argv[2]).install());
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
