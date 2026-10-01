import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { preflightTerminalOwner } from "./gateway-payload-deploy.mjs";

const gateway = fileURLToPath(new URL("../packages/gateway/", import.meta.url));
const require = createRequire(join(gateway, "package.json"));
const ts = require("typescript");

test("terminal owner candidate preflight executes real cleanup and rejects substituted stdout proof", async () => {
  const root = await mkdtemp("/tmp/tron-terminal-preflight-");
  try {
    await mkdir(join(root, "app/dist/machine"), { recursive: true });
    await mkdir(join(root, "app/dist/lifecycle"), { recursive: true });
    await mkdir(join(root, "app/native"), { recursive: true });
    await mkdir(join(root, "runtime"));
    await symlink(process.execPath, join(root, process.arch === "arm64" ? "runtime/node-arm64" : "runtime/node-x64"));
    await symlink(join(gateway, "node_modules"), join(root, "app/node_modules"));
    await writeFile(join(root, "app/package.json"), JSON.stringify({ type: "module" }));
    for (const path of ["machine/terminal-owner", "lifecycle/process-lease-host", "errors"]) {
      const source = await readFile(join(gateway, "src", `${path}.ts`), "utf8");
      const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2023, module: ts.ModuleKind.ESNext } }).outputText;
      await writeFile(join(root, "app/dist", `${path}.js`), output);
    }
    const executable = join(root, "app/native/terminal-owner");
    execFileSync("xcrun", ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", join(gateway, "native/terminal-owner.c"), "-o", executable]);
    await preflightTerminalOwner(root, undefined, 5000);
    await rm(executable);
    await assert.rejects(preflightTerminalOwner(root, undefined, 5000), /exit 1/);
    await writeFile(executable, "#!/bin/sh\nprintf 'E0\\n'\nexit 0\n", { mode: 0o755 });
    // A callback/forged stdout is deliberately insufficient; only the private
    // native receipt may let this readiness probe exit successfully.
    await assert.rejects(preflightTerminalOwner(root, undefined, 5000), /exit 1/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
