import { createHash } from "node:crypto";
import { cp, mkdir, readFile, readdir, symlink } from "node:fs/promises";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = fileURLToPath(new URL("../", import.meta.url));

/** Copies the package as a payload for a nested vitest run of one test file.
 * Copying every other test file was over half of each nested leg's cost under
 * host load; the source modules the leg imports are all kept. */
export async function copyPayload(payload: string, ownTestFile: string): Promise<void> {
  await mkdir(payload);
  await cp(join(packageRoot, "src"), join(payload, "src"), {
    recursive: true,
    filter: (source) => !source.endsWith(".test.ts") || source.endsWith(ownTestFile),
  });
  for (const file of ["test-support", "vitest.config.ts", "package.json"]) {
    await cp(join(packageRoot, file), join(payload, file), { recursive: true });
  }
  await symlink(join(packageRoot, "node_modules"), join(payload, "node_modules"));
  await symlink(join(packageRoot, "artifacts"), join(payload, "artifacts"));
}

/** Digest of every regular file under `root`, keyed by its relative path. */
export async function retainedFiles(root: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {};
  async function visit(path: string): Promise<void> {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const file = join(path, entry.name);
      if (entry.isDirectory()) await visit(file);
      else if (entry.isFile()) result[relative(root, file)] = createHash("sha256").update(await readFile(file)).digest("hex");
    }
  }
  await visit(root);
  return result;
}

/** Refuses fixture removal while a nested run's process owner reports an unjoined child. */
export async function refuseUnjoinedFixture(root: string): Promise<void> {
  let failure: string;
  try { failure = await readFile(process.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(root, "process-owner-failure.jsonl"), "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  throw new Error(`Refusing fixture removal after process join failure: ${failure}`);
}
