import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";

// Real socket → PackageService → pinned Pi manager → owned version-query child.
// Never install packages or contact a registry. The call log rejects a silent
// empty success caused by offline mode, missing metadata or a broken child.
it.each([256, 257])("packages.checkUpdates admits only a bounded %i-row SDK projection", async (count) => {
  const root = await mkdtemp(join(tmpdir(), "tron-package-updates-"));
  let gateway: LockGateway | undefined;
  try {
    const child = join(root, "npm-view.mjs");
    const calls = join(root, "calls.jsonl");
    await writeFile(calls, "");
    await writeFile(child, `import { appendFileSync } from 'node:fs';
const [log, ...args] = process.argv.slice(2);
appendFileSync(log, JSON.stringify(args) + '\\n');
if (args.length !== 4 || args[0] !== 'view' || args[2] !== 'version' || args[3] !== '--json') process.exit(1);
console.log(JSON.stringify('2.0.0'));
`);
    const names = Array.from({ length: count }, (_, index) => `fixture-update-${index}`);
    const agentDir = join(root, "tron", "agent");
    const project = join(root, "workspace", ".pi");
    await mkdir(project, { recursive: true });
    await writeFile(join(project, "settings.json"), JSON.stringify({ packages: [`npm:${names[0]}`] }));
    for (const [index, name] of names.entries()) {
      const directory = join(index === 0 ? project : agentDir, "npm", "node_modules", name);
      await mkdir(directory, { recursive: true });
      await writeFile(join(directory, "package.json"), JSON.stringify({ name, version: "1.0.0" }));
    }
    gateway = await startLockGateway("package-updates", {
      root, administrativeResources: true,
      settings: { npmCommand: [process.execPath, child, calls], packages: names.slice(1).map(name => `npm:${name}`) },
    });
    const phone = await gateway.connect("package-reader");
    const response = await phone.request("packages.checkUpdates", { cwd: gateway.cwd });
    const queried = (await readFile(calls, "utf8")).trim().split("\n").map(line => JSON.parse(line) as string[]);
    expect(queried.map(args => args[1]).sort()).toEqual([...names].sort());
    expect(queried.every(args => args.length === 4 && args[0] === "view" && args[2] === "version" && args[3] === "--json")).toBe(true);
    if (count === 256) {
      expect(response.ok, JSON.stringify(response)).toBe(true);
      expect(response.result).toEqual({ updates: names.map((name, index) => ({
        source: `npm:${name}`, displayName: name, type: "npm", scope: index === 0 ? "project" : "user",
      })) });
    } else {
      expect(response.ok, JSON.stringify(response)).toBe(false);
      expect(response.error).toMatchObject({ code: "conflict", message: "Package updates exceed their item limit" });
    }
  } finally {
    if (gateway) await gateway.dispose();
    await rm(root, { recursive: true, force: true });
  }
});
