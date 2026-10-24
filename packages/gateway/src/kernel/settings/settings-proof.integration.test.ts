import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { expect, it } from "vitest";

const execute = promisify(execFile);
const gateway = resolve(import.meta.dirname, "../../..");
const prelude = `import type { Planned, SettingsChangeOwner, ChangeContext, SettingsWriters } from '../../src/kernel/settings/settings-change.js';
import type { SettingsStores } from '../../src/kernel/settings/settings-types.js';
import type { SettingsTarget } from '../../src/kernel/settings/tool-contract.js';
declare const owner: SettingsChangeOwner, target: SettingsTarget, stores: SettingsStores, context: ChangeContext, writers: SettingsWriters;
declare const admitted: Planned, raw: Omit<Planned, symbol>;
`;

it("requires admission at the real store applier and rejects explicit capability casts with the real linter", async () => {
  const results: unknown[] = [];
  const directory = resolve(gateway, "test-results");
  await mkdir(directory, { recursive: true });
  const root = await mkdtemp(join(directory, "proof-compile-"));
  const source = join(root, "fixture.ts");
  const config = join(root, "tsconfig.json");
  await writeFile(config, JSON.stringify({ extends: "../../tsconfig.json", compilerOptions: { rootDir: "../..", noUnusedLocals: false }, include: ["fixture.ts"], exclude: [] }));
  const run = async (tool: string, args: string[]) => {
    const result = await execute(join(gateway, "node_modules/.bin", tool), args, { cwd: gateway, timeout: 30_000, maxBuffer: 2_000_000 })
      .then(row => ({ code: 0, output: row.stdout + row.stderr }), (error: { code: number; stdout: string; stderr: string }) => ({ code: error.code, output: error.stdout + error.stderr }));
    results.push({ tool, ...result });
    return result;
  };
  try {
    await writeFile(source, prelude + "void owner.applyStore(target, stores, admitted, admitted.after, context, writers);\n");
    expect((await run("tsc", ["-p", config, "--noEmit"])).code).toBe(0);
    await writeFile(source, prelude + "void owner.applyStore(target, stores, raw, raw.after, context, writers);\n");
    const missing = await run("tsc", ["-p", config, "--noEmit"]);
    expect(missing.code).not.toBe(0);
    expect(missing.output).toContain("TS2741");
    expect(missing.output).toContain("[settingsAdmission]");

    // Casts DO bypass TypeScript. The separate linter must reject them; claiming
    // these fail tsc would hide the precise limitation being measured.
    for (const cast of ["raw as Planned", "raw as unknown as Planned", "raw as Alias", "raw as ns.Planned"]) {
      await writeFile(source, prelude + `import type * as ns from '../../src/kernel/settings/settings-change.js';\ntype Alias = Planned;\nconst forged = ${cast};\nvoid owner.applyStore(target, stores, forged, forged.after, context, writers);\n`);
      expect((await run("tsc", ["-p", config, "--noEmit"])).code).toBe(0);
      const forged = await run("oxlint", ["-c", join(gateway, ".oxlintrc.json"), "--no-ignore", source]);
      expect(forged.code).not.toBe(0);
      expect(forged.output).toContain("no-forged-plan");
    }
  } finally {
    await rm(root, { recursive: true, force: true });
    await mkdir(join(directory, "proof-spike"), { recursive: true });
    await writeFile(join(directory, "proof-spike", "capability.json"), JSON.stringify(results, null, 2));
  }
}, 120_000);
