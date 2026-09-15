import { rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const source = dirname(fileURLToPath(import.meta.url));
await rm(join(source, "../../../dist/delegation/pi-subagents"), { recursive: true, force: true });
