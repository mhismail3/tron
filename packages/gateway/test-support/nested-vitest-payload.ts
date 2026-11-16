import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { cp, mkdir, readFile, readdir, rm, symlink } from "node:fs/promises";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const packageRoot = fileURLToPath(new URL("../", import.meta.url));
const PAYLOAD_FILES = ["test-support", "vitest.config.ts", "vitest.nested.config.ts", "package.json"];

export interface GatewaySource { top: string; tree: string; commit: string }

export async function gatewaySourceForSubagentsVersion(version: string): Promise<GatewaySource> {
  const run = async (...args: string[]) => (await promisify(execFile)("git", args)).stdout;
  const gateway = process.env.TRON_SUBAGENTS_SOURCE_GATEWAY ?? packageRoot;
  const top = (await run("-C", gateway, "rev-parse", "--show-toplevel")).trim();
  const prefix = (await run("-C", gateway, "rev-parse", "--show-prefix")).trim();
  const commit = (await run("-C", gateway, "log", "-1", "--format=%H", `-S"version": "${version}"`, "--", "pi-subagents-pin.json")).trim();
  if (!/^[0-9a-f]{40}$/u.test(commit)) throw new Error(`No Gateway commit pins pi-subagents ${version}`);
  if (JSON.parse(await run("-C", top, "show", `${commit}:${prefix}pi-subagents-pin.json`)).version !== version) {
    throw new Error(`Gateway commit ${commit} does not select pi-subagents ${version}`);
  }
  return { top, tree: `${commit}:${prefix}`, commit };
}

export async function copyPayload(payload: string, ownTestFile: string, gateway?: GatewaySource): Promise<void> {
  await mkdir(payload);
  const source = gateway ? `${payload}.source` : packageRoot;
  if (gateway) {
    await mkdir(source);
    await promisify(execFile)("git", ["-C", gateway.top, "archive", "--format=tar", `--output=${source}.tar`, gateway.tree, "src", ...PAYLOAD_FILES]);
    await promisify(execFile)("tar", ["-xf", `${source}.tar`, "-C", source]);
    await rm(`${source}.tar`);
  }
  let ownTest: string | undefined;
  await cp(join(source, "src"), join(payload, "src"), {
    recursive: true,
    filter: (path) => {
      if (!path.endsWith(".test.ts")) return true;
      if (path.endsWith(ownTestFile)) ownTest = relative(source, path);
      return path.endsWith(ownTestFile);
    },
  });
  for (const file of PAYLOAD_FILES) await cp(join(source, file), join(payload, file), { recursive: true });
  if (gateway) {
    if (!ownTest) throw new Error(`Gateway ${gateway.commit} has no ${ownTestFile}`);
    await cp(join(packageRoot, ownTest), join(payload, ownTest));
    await rm(source, { recursive: true, force: true });
  }
  await symlink(join(packageRoot, "node_modules"), join(payload, "node_modules"));
  await symlink(join(packageRoot, "artifacts"), join(payload, "artifacts"));
}

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

export async function refuseUnjoinedFixture(root: string): Promise<void> {
  let failure: string;
  try { failure = await readFile(process.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(root, "process-owner-failure.jsonl"), "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  throw new Error(`Refusing fixture removal after process join failure: ${failure}`);
}
