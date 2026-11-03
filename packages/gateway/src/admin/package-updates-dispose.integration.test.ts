import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { startLockGateway } from "../../test-support/gateway-lock-harness.js";
import { waitFor } from "../../test-support/wait-for.js";

// #2242: a package update check still running when its Gateway is disposed (its caller
// stopped waiting) kept spawning version-query children that wrote under the root the
// harness was removing (ENOTEMPTY). Disposal joins admitted work before removing it.
it("disposes only after an admitted package update check has settled", async () => {
  const outside = await mkdtemp(join(tmpdir(), "tron-package-dispose-outside-"));
  const root = await mkdtemp(join(tmpdir(), "tron-package-dispose-"));
  try {
    const started = join(outside, "started"), finished = join(outside, "finished");
    const child = join(root, "npm-view.mjs");
    await writeFile(child, `import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(started)}, '');
await new Promise(resolve => setTimeout(resolve, 1500));
writeFileSync(${JSON.stringify(finished)}, '');
console.log(JSON.stringify('2.0.0'));
`);
    const name = "fixture-dispose-0";
    const installed = join(root, "tron", "agent", "npm", "node_modules", name);
    await mkdir(installed, { recursive: true });
    await writeFile(join(installed, "package.json"), JSON.stringify({ name, version: "1.0.0" }));
    const gateway = await startLockGateway("package-updates-dispose", {
      root, administrativeResources: true,
      settings: { npmCommand: [process.execPath, child], packages: [`npm:${name}`] },
    });
    const phone = await gateway.connect("package-reader");
    void phone.request("packages.checkUpdates", { cwd: gateway.cwd }).catch(() => undefined);
    await waitFor(() => existsSync(started), "the version query to start");
    await gateway.dispose();
    expect(existsSync(finished), "disposal returned while the admitted update check was still running").toBe(true);
    expect(existsSync(root)).toBe(false);
  } finally {
    await rm(outside, { recursive: true, force: true });
    await rm(root, { recursive: true, force: true });
  }
});
