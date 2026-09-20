import { chmod, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  cleanupInternalLayout,
  preflightInternalLayout,
  publishInternalLayout,
  recoverInternalLayout,
  stageInternalLayout,
  verifyInternalLayout,
} from "./internal-layout-migration.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
async function fixture(prefix: string) { const root = await mkdtemp(join(tmpdir(), prefix)); roots.push(root); return root; }

const options = (root: string) => ({
  source: join(root, "legacy"), destination: join(root, "tron/internal/machine-group-id"),
  staging: join(root, "staging/machine-group-id"), acknowledgeQuiescence: true, acknowledgeBackup: true,
});

describe("internal layout migration", () => {
  it("preflights, stages, verifies and publishes exact bytes/mode without dual authority", async () => {
    const root = await fixture("tron-internal-migration-");
    const value = options(root);
    await mkdir(join(root, "tron/internal"), { recursive: true, mode: 0o700 });
    await writeFile(value.source, "stable-machine-group\n", { mode: 0o600 });
    expect((await preflightInternalLayout(value)).status).toBe("migration-required");
    const staged = await stageInternalLayout(value);
    await verifyInternalLayout(value.staging);
    expect(await readFile(value.staging, "utf8")).toBe("stable-machine-group\n");
    await publishInternalLayout(value.staging);
    await expect(lstat(value.source)).rejects.toMatchObject({ code: "ENOENT" });
    expect(await readFile(value.destination, "utf8")).toBe("stable-machine-group\n");
    expect((await lstat(value.destination)).mode & 0o777).toBe(staged.manifest.mode & 0o777);
  });

  it("blocks conflicting authorities and destination collisions", async () => {
    const root = await fixture("tron-internal-migration-conflict-");
    const value = options(root);
    await mkdir(join(root, "tron/internal"), { recursive: true });
    await writeFile(value.source, "one", { mode: 0o600 });
    await writeFile(value.destination, "two", { mode: 0o600 });
    expect((await preflightInternalLayout(value)).status).toBe("conflict");
    await expect(stageInternalLayout(value)).rejects.toThrow(/destination already exists/);
  });

  it("rejects unsafe permissions, symlinks, and oversized bytes", async () => {
    const root = await fixture("tron-internal-migration-safety-");
    const value = options(root);
    await mkdir(join(root, "tron/internal"), { recursive: true });
    await writeFile(value.source, "secret", { mode: 0o644 });
    await expect(stageInternalLayout(value)).rejects.toThrow(/owner-only/);
    await rm(value.source);
    await symlink(join(root, "outside"), value.source);
    await expect(preflightInternalLayout(value)).rejects.toThrow(/owner-only/);
    await rm(value.source);
    await writeFile(value.source, "bytes", { mode: 0o600 });
    await chmod(value.source, 0o600);
    await expect(stageInternalLayout({ ...value, acknowledgeBackup: false })).rejects.toThrow(/acknowledgements/);
  });

  it("retains an interrupted marker for explicit recovery", async () => {
    const root = await fixture("tron-internal-migration-recovery-");
    const value = options(root);
    await mkdir(join(root, "tron/internal"), { recursive: true });
    await writeFile(value.source, "stable", { mode: 0o600 });
    await stageInternalLayout(value);
    await writeFile(value.staging, "interrupted", { flag: "w", mode: 0o600 });
    await expect(verifyInternalLayout(value.staging)).rejects.toThrow(/changed/);
    await expect(recoverInternalLayout(value.staging)).resolves.toMatchObject({ action: "none" });
    await cleanupInternalLayout(value.staging);
    await expect(lstat(value.staging)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("does not regenerate a missing source or silently create authority", async () => {
    const root = await fixture("tron-internal-migration-none-");
    const value = options(root);
    await mkdir(join(root, "tron/internal"), { recursive: true });
    expect((await preflightInternalLayout(value)).status).toBe("not-required");
    expect(await lstat(value.destination).catch(() => undefined)).toBeUndefined();
  });
});
