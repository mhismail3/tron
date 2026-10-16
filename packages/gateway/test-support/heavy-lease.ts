import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { TestProject } from "vitest/node";

/**
 * Every direct `vitest` run on this Mac waits for the host-wide heavy queue
 * (tools/work/heavy.py, docs/host-load.md), like gate shards do, so admission sees
 * diagnosis runs too (#1105). A gate shard already holds a slot (TRON_HEAVY_LEASE_HELD)
 * and hosted CI has no shared host; both take none.
 *
 * The lease is held by a `tron-heavy run` child that waits on this process's pipe:
 * when vitest ends, normally or killed, the pipe closes and the slot is freed.
 */
export default async function setup(project: TestProject): Promise<(() => Promise<void>) | undefined> {
  if (process.env.TRON_HEAVY_LEASE_HELD || process.env.GITHUB_ACTIONS === "true" || process.env.CI) return undefined;
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
  // A nested run's payload copy (test-support/nested-vitest-payload.ts) is not a checkout;
  // it runs inside a leased parent run.
  if (!existsSync(join(root, "tools/work/heavy.py"))) return undefined;
  const serial = project.config.fileParallelism === false;
  const cores = serial ? 2 : Math.max(1, Number(project.config.maxWorkers) || 4);
  const holder = "import os, sys\nprint('admitted', os.environ.get('TRON_HEAVY_CORES', ''), flush=True)\nsys.stdin.read()";
  const child = spawn("python3", [join(root, "tools/work/heavy.py"), "run",
    "--owner", `vitest ${serial ? "serial " : ""}in ${basename(root)}`,
    "--need-mb", serial ? "1600" : "2500", "--cores", String(cores), ...(serial ? ["--pool", "serial"] : []),
    "--", "python3", "-c", holder], { stdio: ["pipe", "pipe", "inherit"] });
  await new Promise<void>((admitted, refused) => {
    let output = "";
    child.stdout!.on("data", (chunk: Buffer) => {
      output += chunk.toString();
      if (output.includes("admitted")) admitted();
    });
    child.once("exit", code => refused(new Error(`heavy queue admission ended with ${code} before admitting vitest`)));
  });
  // Nested vitest and real Gateway children this run starts share its slot.
  process.env.TRON_HEAVY_LEASE_HELD = "vitest";
  return async () => {
    delete process.env.TRON_HEAVY_LEASE_HELD;
    child.stdin!.end();
    if (child.exitCode === null) await new Promise(done => child.once("exit", done));
  };
}
