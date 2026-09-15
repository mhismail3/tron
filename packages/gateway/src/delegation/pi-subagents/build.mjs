import { cp, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const source = dirname(fileURLToPath(import.meta.url));
const output = join(source, "../../../dist/delegation/pi-subagents");
await mkdir(output, { recursive: true });
for (const name of ["agents", "docs", "prompts", "skills", "LICENSE", "CHANGELOG.md", "README.md", "PROVENANCE.md", "package.json", "async-retention-discovery-worker.mjs", "inspector-runner.mjs", "install.mjs"]) {
  await cp(join(source, name), join(output, name), { recursive: true });
}
