import { chmod, lchmod, lstat, mkdir, mkdtemp, readFile, readlink, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  createAgentHomeManifest,
  cleanupStagedAgentHome,
  stageAgentHome,
  verifyStagedAgentHome,
} from "./agent-home-migration.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture(prefix: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), prefix));
  roots.push(root);
  return root;
}

describe("agent home migration staging", () => {
  it("copies a synthetic home with bytes, modes, and portable links, then verifies it", async () => {
    const root = await fixture("tron-agent-migration-");
    const source = join(root, "source");
    const destination = join(root, "destination");
    const staging = join(root, "staging");
    await writeFile(join(root, "placeholder"), "parent exists");
    await mkdir(join(source, "sessions"), { recursive: true, mode: 0o750 });
    await writeFile(join(source, "settings.json"), JSON.stringify({ packages: ["./packages"] }));
    await writeFile(join(source, "sessions", "one.jsonl"), '{"type":"session"}\n', { mode: 0o640 });
    await symlink("sessions", join(source, "session-link"));
    await chmod(join(source, "settings.json"), 0o600);

    const staged = await stageAgentHome({ source, destination, staging, acknowledgeQuiescence: true, acknowledgeBackup: true });
    expect(staged.changesMade).toBe(true);
    expect(staged.publicationMode).toBe("same-filesystem-rename");
    expect(staged.sourceManifest.digest).toBe(staged.stagedManifest.digest);
    expect(await readFile(join(staging, "sessions", "one.jsonl"), "utf8")).toBe('{"type":"session"}\n');
    expect((await lstat(join(staging, "sessions", "one.jsonl"))).mode & 0o7777).toBe(0o640);
    expect(await readlink(join(staging, "session-link"))).toBe("sessions");

    const verified = await verifyStagedAgentHome(staging);
    expect(verified.changesMade).toBe(false);
    expect(verified.stagedManifest.digest).toBe(staged.sourceManifest.digest);
  });

  it.skipIf(process.platform !== "darwin")("preserves symlink modes independently of the creation umask without chmodding targets", async () => {
    const root = await fixture("tron-agent-migration-link-mode-");
    const source = join(root, "source");
    const staging = join(root, "staging");
    await mkdir(source);
    await writeFile(join(source, "target"), "unchanged", { mode: 0o600 });
    const link = join(source, "link");
    await symlink("target", link);
    // Force a mismatch with the mode assigned by symlink() under this process's
    // umask, without changing process-global umask in a Vitest worker.
    const mode = ((await lstat(link)).mode & 0o777) ^ 0o040;
    await lchmod(link, mode);
    await stageAgentHome({ source, destination: join(root, "destination"), staging, acknowledgeQuiescence: true, acknowledgeBackup: true });
    expect((await lstat(join(staging, "link"))).mode & 0o777).toBe(mode);
    expect((await lstat(join(staging, "target"))).mode & 0o777).toBe(0o600);
    expect((await lstat(join(source, "target"))).mode & 0o777).toBe(0o600);
    await expect(verifyStagedAgentHome(staging)).resolves.toMatchObject({ changesMade: false });
  });

  it("refuses staging without both operator acknowledgements and never creates roots", async () => {
    const root = await fixture("tron-agent-migration-ack-");
    const source = join(root, "source");
    const staging = join(root, "staging");
    const destination = join(root, "destination");
    await mkdir(source);
    await expect(stageAgentHome({ source, destination, staging, acknowledgeQuiescence: true, acknowledgeBackup: false })).rejects.toThrow(/acknowledgements/);
    await expect(lstat(staging)).rejects.toMatchObject({ code: "ENOENT" });
  });


  it("removes only the exact legacy Ask User package in staged settings with an accounted manifest transform", async () => {
    const root = await fixture("tron-agent-migration-legacy-ask-user-");
    const source = join(root, "source");
    const destination = join(root, "destination");
    const staging = join(root, "staging");
    const original = JSON.stringify({ packages: ["npm:@zhushanwen/pi-ask-user@7.0.15", "npm:pi-subagents@0.59.0"] });
    await mkdir(source);
    await writeFile(join(source, "settings.json"), original);

    const staged = await stageAgentHome({ source, destination, staging, removeLegacyAskUser: true, acknowledgeQuiescence: true, acknowledgeBackup: true });

    expect(staged.legacyAskUserTransform?.removedCount).toBe(1);
    expect(await readFile(join(source, "settings.json"), "utf8")).toBe(original);
    const stagedSettings = JSON.parse(await readFile(join(staging, "settings.json"), "utf8")) as { packages: string[] };
    expect(stagedSettings.packages).toEqual(["npm:pi-subagents@0.59.0"]);
    await expect(verifyStagedAgentHome(staging)).resolves.toMatchObject({ legacyAskUserTransform: { removedCount: 1 } });
    await writeFile(join(staging, "settings.json"), `${JSON.stringify({ packages: ["npm:pi-subagents@0.59.0", "npm:tampered@1.0.0"] })}\n`);
    await expect(verifyStagedAgentHome(staging)).rejects.toThrow(/staging no longer matches/);
  });

  it("refuses a requested legacy Ask User transform when the exact package is absent", async () => {
    const root = await fixture("tron-agent-migration-legacy-ask-user-absent-");
    const source = join(root, "source");
    await mkdir(source);
    await writeFile(join(source, "settings.json"), JSON.stringify({ packages: ["npm:pi-subagents@0.59.0"] }));
    await expect(stageAgentHome({ source, destination: join(root, "destination"), staging: join(root, "staging"), removeLegacyAskUser: true, acknowledgeQuiescence: true, acknowledgeBackup: true })).rejects.toThrow(/not configured/);
  });


  it("refuses staging when a portable child extension reference is missing", async () => {
    const root = await fixture("tron-agent-migration-agent-reference-");
    const source = join(root, "source");
    const staging = join(root, "staging");
    await mkdir(join(source, "agents"), { recursive: true });
    await writeFile(join(source, "agents", "worker.md"), "---\nname: worker\ndescription: child\nsubagentOnlyExtensions: ./missing.js\n---\nworker\n");
    await expect(stageAgentHome({ source, destination: join(root, "destination"), staging, acknowledgeQuiescence: true, acknowledgeBackup: true })).rejects.toThrow(/preflight/);
    await expect(lstat(staging)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("refuses destination collisions and unsafe special links before staging", async () => {
    const root = await fixture("tron-agent-migration-safety-");
    const source = join(root, "source");
    const destination = join(root, "destination");
    const staging = join(root, "staging");
    await mkdir(source);
    await mkdir(destination);
    await expect(stageAgentHome({ source, destination, staging, acknowledgeQuiescence: true, acknowledgeBackup: true })).rejects.toThrow(/destination already exists/);
    await rm(destination, { recursive: true });
    await symlink("/private/outside", join(source, "escape"));
    await expect(stageAgentHome({ source, destination, staging, acknowledgeQuiescence: true, acknowledgeBackup: true })).rejects.toThrow(/preflight/);
    await expect(lstat(staging)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("does not accept an interrupted or tampered staging tree as verified and cleans only marked staging", async () => {
    const root = await fixture("tron-agent-migration-tamper-");
    const source = join(root, "source");
    const destination = join(root, "destination");
    const staging = join(root, "staging");
    await mkdir(source);
    await writeFile(join(source, "session.jsonl"), "before\n");
    await stageAgentHome({ source, destination, staging, acknowledgeQuiescence: true, acknowledgeBackup: true });
    await writeFile(join(source, "session.jsonl"), "after\n");
    await expect(verifyStagedAgentHome(staging)).rejects.toThrow(/no longer matches/);
    await cleanupStagedAgentHome(staging);
    await expect(lstat(staging)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(lstat(`${staging}.tron-agent-migration.json`)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects malformed markers without recursively deleting an unowned directory", async () => {
    const root = await fixture("tron-agent-migration-marker-");
    const staging = join(root, "staging");
    await mkdir(staging);
    await writeFile(`${staging}.tron-agent-migration.json`, JSON.stringify({ version: 1, staging }), { mode: 0o600 });
    await expect(cleanupStagedAgentHome(staging)).rejects.toThrow(/marker is malformed/);
    expect((await lstat(staging)).isDirectory()).toBe(true);
  });

  it("bounds manifests and rejects root/special inputs without exposing file contents", async () => {
    const root = await fixture("tron-agent-migration-bounds-");
    const source = join(root, "source");
    await mkdir(source);
    await writeFile(join(source, "secret.json"), "provider-token-body");
    await expect(createAgentHomeManifest(source, 1)).rejects.toThrow(/entry limit/);
    const manifest = await createAgentHomeManifest(source, 10);
    expect(JSON.stringify(manifest)).not.toContain("provider-token-body");
    await symlink("/private/outside", join(source, "unsafe"));
    await expect(createAgentHomeManifest(source, 10)).rejects.toThrow(/absolute symlinks/);
  });
});
