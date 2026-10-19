import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const gateway = fileURLToPath(new URL("../", import.meta.url));
const reportPath = join(gateway, "test-results/typescript-build/report.json");

test("real npm/TypeScript checks reuse only no-emit work and retain all failure/emit guards", { timeout: 60_000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), "tron-typescript-build-"));
  const steps = [];
  const env = { ...process.env, HOME: root, TMPDIR: root, npm_config_update_notifier: "false",
    PATH: `${join(gateway, "node_modules/.bin")}${delimiter}${process.env.PATH}` };
  async function run(script, diagnostic) {
    console.log(`[typescript-build] ${script}: ${diagnostic ?? "success"}`);
    const start = performance.now();
    const result = await new Promise((resolve, reject) => {
      const child = spawn("npm", ["run", script], { cwd: root, env, detached: true });
      let output = "";
      const abort = () => {
        if (child.pid === undefined) return;
        try { process.kill(-child.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
      };
      t.signal.addEventListener("abort", abort, { once: true });
      child.stdout.on("data", chunk => { output += chunk; });
      child.stderr.on("data", chunk => { output += chunk; });
      child.once("error", reject);
      child.once("close", (code, signal) => {
        t.signal.removeEventListener("abort", abort);
        resolve({ code, signal, output });
      });
    });
    steps.push({ script, expected: diagnostic ?? "success", ...result, elapsedMs: performance.now() - start });
    assert.equal(result.signal, null, result.output);
    if (diagnostic) {
      assert.notEqual(result.code, 0, result.output);
      assert.ok(result.output.includes(diagnostic), result.output);
    } else assert.equal(result.code, 0, result.output);
  }
  const source = "export function next(value: number) { return value + 1; }\n";
  try {
    await Promise.all(["src", "test-support", "test-fixtures/pi-sdk", "node_modules"].map(path => mkdir(join(root, path), { recursive: true })));
    await symlink(join(gateway, "node_modules/@types"), join(root, "node_modules/@types"));
    for (const file of ["package.json", "tsconfig.json", "tsconfig.test-support.json"]) await cp(join(gateway, file), join(root, file));
    await writeFile(join(root, "src/index.ts"), source);
    await writeFile(join(root, "test-support/helper.ts"), "export const helper = 1;\n");
    const corpus = join(root, "test-fixtures/pi-sdk/record-corpus.integration.test.ts");
    await writeFile(corpus, "export const corpus = 1;\n");

    await run("check");
    await run("check"); // A second pass must actually reuse the native caches.
    await assert.rejects(stat(join(root, "dist")), { code: "ENOENT" });
    await run("build");
    const outputs = ["index.js", "index.d.ts", "index.js.map"].map(file => join(root, "dist", file));
    const original = await Promise.all(outputs.map(file => readFile(file)));
    for (const file of outputs) await rm(file);
    await run("build"); // A warmed no-emit cache must never suppress emission.
    assert.deepEqual(await Promise.all(outputs.map(file => readFile(file))), original);

    // Each scope has a unique unimported root. Cached success must not conceal
    // a newly introduced error, and cached errors must disappear only on repair.
    for (const path of ["src/unimported.ts", "test-support/unimported.ts", "test-fixtures/pi-sdk/record-corpus.integration.test.ts"]) {
      const file = join(root, path);
      const before = path.startsWith("test-fixtures") ? await readFile(file) : undefined;
      await writeFile(file, "export const wrong: string = 42;\n");
      await run("check", "TS2322");
      await run("check", "TS2322"); // A cached diagnostic is still a failure.
      await run("build", "TS2322");
      if (before) await writeFile(file, before); else await rm(file);
      await run("check");
    }

    // The production root boundary is a semantic guard -- noCheck drops it.
    await writeFile(join(root, "src/index.ts"), "import { helper } from '../test-support/helper.js'; export const outside = helper;\n");
    await run("check", "TS6059");
    await run("check", "TS6059");
    await run("build", "TS6059");
    await writeFile(join(root, "src/index.ts"), "export const anonymous = class { private value = 1; read() { return this.value; } };\n");
    await run("check", "TS4094");
    await run("check", "TS4094");
    await run("build", "TS4094");
    await writeFile(join(root, "src/index.ts"), source);
    await run("check");

    const baseConfig = join(root, "tsconfig.json");
    const configBytes = await readFile(baseConfig);
    const config = JSON.parse(configBytes);
    config.compilerOptions.noUnusedParameters = true;
    await writeFile(join(root, "src/index.ts"), "export function unused(value: number) { return 1; }\n");
    await run("check");
    await writeFile(baseConfig, JSON.stringify(config));
    await run("check", "TS6133");
    await writeFile(baseConfig, configBytes);
    await writeFile(join(root, "src/index.ts"), source);

    const dependency = join(root, "node_modules/fixture-types");
    await mkdir(dependency);
    await writeFile(join(dependency, "package.json"), JSON.stringify({ name: "fixture-types", types: "index.d.ts" }));
    await writeFile(join(dependency, "index.d.ts"), "export type Value = string;\n");
    await writeFile(join(root, "src/index.ts"), "export const typed: import('fixture-types').Value = 'ok';\n");
    await run("check");
    await writeFile(join(dependency, "index.d.ts"), "export type Value = number;\n");
    await run("check", "TS2322");
    await writeFile(join(root, "src/index.ts"), source);

    // Cache damage is not a remembered pass. TypeScript must recheck and report
    // the actual source error, then accept the repaired program.
    await run("check");
    for (const file of ["production-check.tsbuildinfo", "test-support.tsbuildinfo"]) {
      const path = join(root, "node_modules/.cache/tron", file);
      await readFile(path); // Corrupt an activated compiler cache, not a stand-in.
      await writeFile(path, "{broken");
    }
    await writeFile(join(root, "src/index.ts"), "export const wrong: string = 42;\n");
    await run("check", "TS2322");
    await writeFile(join(root, "src/index.ts"), source);
    await writeFile(join(root, "test-support/helper.ts"), "export const wrong: string = 42;\n");
    await run("check", "TS2322");
    await writeFile(join(root, "test-support/helper.ts"), "export const helper = 1;\n");
    await run("build");
    assert.deepEqual(await Promise.all(outputs.map(file => readFile(file))), original);
  } finally {
    try {
      await mkdir(join(gateway, "test-results/typescript-build"), { recursive: true });
      await writeFile(reportPath, `${JSON.stringify({ steps }, null, 2)}\n`);
    } finally { await rm(root, { recursive: true, force: true }); }
  }
});
