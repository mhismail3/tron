import { lstat, mkdtemp, mkdir, readFile, readdir, readlink, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { preflightAgentHome } from "./agent-home-preflight.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture(prefix: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), prefix));
  roots.push(root);
  return root;
}

function codes(result: Awaited<ReturnType<typeof preflightAgentHome>>): string[] {
  return result.issues.map(entry => entry.code);
}

interface FixtureManifestEntry {
  type: "directory" | "file" | "symlink" | "special";
  mode: number;
  bytes?: string;
  target?: string;
}

async function manifest(root: string, current = root): Promise<Record<string, FixtureManifestEntry>> {
  const output: Record<string, FixtureManifestEntry> = {};
  const entry = await lstat(current);
  const relativePath = current === root ? "." : current.slice(root.length + 1);
  const type = entry.isDirectory() ? "directory" : entry.isFile() ? "file" : entry.isSymbolicLink() ? "symlink" : "special";
  const record: FixtureManifestEntry = { type, mode: entry.mode & 0o7777 };
  if (entry.isFile()) record.bytes = (await readFile(current)).toString("base64");
  if (entry.isSymbolicLink()) record.target = await readlink(current, "utf8");
  output[relativePath] = record;
  if (entry.isDirectory()) {
    for (const name of (await readdir(current)).sort()) Object.assign(output, await manifest(root, join(current, name)));
  }
  return output;
}

describe("agent home migration preflight", () => {
  it("is read-only and recognizes a safe internal package symlink", async () => {
    const root = await fixture("tron-agent-preflight-");
    const source = join(root, "source");
    const destination = join(root, "new-agent");
    await mkdir(join(source, "packages", "example"), { recursive: true });
    await writeFile(join(source, "settings.json"), JSON.stringify({ packages: ["./packages/example"] }));
    await symlink("example", join(source, "packages", "link"));
    const before = await readdir(root);

    const result = await preflightAgentHome({ source, destination });

    expect(result.status).toBe("assessment-only");
    expect(result.changesMade).toBe(false);
    expect(result.safeInternalSymlinks).toBe(1);
    expect(result.unresolvedSymlinks).toBe(0);
    expect(result.writerQuiescence).toBe("unproven");
    expect(await readdir(root)).toEqual(before);
    await expect(lstat(destination)).rejects.toMatchObject({ code: "ENOENT" });
    expect(await readFile(join(source, "settings.json"), "utf8")).toContain("packages");
  });

  it("keeps registry and VCS package specs portable when their installed trees move with the home", async () => {
    const root = await fixture("tron-agent-preflight-portable-packages-");
    const source = join(root, "source");
    const destination = join(root, "new-agent");
    await mkdir(join(source, "packages", "registry"), { recursive: true });
    await mkdir(join(source, "packages", "git"), { recursive: true });
    await writeFile(join(source, "settings.json"), JSON.stringify({
      packages: ["npm:pi-subagents@0.59.0", "git:github.com/example/portable.git#v1", "./packages/registry", "./packages/git", { source: "npm:pi-agent-browser-native@0.4.1", extensions: ["extensions/*.js"], skills: ["skills/*"] }],
    }));

    const result = await preflightAgentHome({ source, destination });

    expect(result.status).toBe("assessment-only");
    expect(result.externalConfigurationReferences).toBe(0);
    expect(codes(result)).not.toContain("configured-external-reference");
    expect(codes(result)).not.toContain("relocation-sensitive-reference");
  });

  it("blocks collisions and source/destination overlap without inspecting a destination", async () => {
    const root = await fixture("tron-agent-preflight-collision-");
    const source = join(root, "source");
    const destination = join(source, "agent");
    await mkdir(destination, { recursive: true });

    const result = await preflightAgentHome({ source, destination });

    expect(result.status).toBe("blocked");
    expect(codes(result)).toEqual(expect.arrayContaining(["source-destination-overlap", "destination-collision"]));
    expect(result.entriesInspected).toBe(0);
  });

  it("compares physical roots through missing destination suffixes", async () => {
    const root = await fixture("tron-agent-preflight-physical-overlap-");
    const source = join(root, "actual");
    const alias = join(root, "alias");
    await mkdir(source);
    await symlink(source, alias);

    const result = await preflightAgentHome({ source, destination: join(alias, "new-agent") });

    expect(result.status).toBe("blocked");
    expect(codes(result)).toEqual(expect.arrayContaining(["destination-ancestor-symlink", "source-destination-overlap"]));
  });

  it("rejects non-directory and root-symlink inputs", async () => {
    const root = await fixture("tron-agent-preflight-roots-");
    const target = join(root, "target");
    const file = join(root, "file");
    const link = join(root, "link");
    await mkdir(target);
    await writeFile(file, "not a directory");
    await symlink(target, link);

    const nonDirectory = await preflightAgentHome({ source: file, destination: join(root, "new-file") });
    const rootSymlink = await preflightAgentHome({ source: link, destination: join(root, "new-link") });

    expect(codes(nonDirectory)).toContain("source-root-not-directory");
    expect(codes(rootSymlink)).toContain("source-root-symlink");
    expect(nonDirectory.changesMade).toBe(false);
    expect(rootSymlink.changesMade).toBe(false);
  });

  it("does not follow escaping symlinks and redacts configured external values", async () => {
    const root = await fixture("tron-agent-preflight-external-");
    const source = join(root, "source");
    const destination = join(root, "new-agent");
    await mkdir(source);
    await writeFile(join(source, "settings.json"), JSON.stringify({
      sessionDir: "/private/secret-session-body",
      packages: [{ source: "/private/provider-token" }],
      extensions: ["../outside-extension"],
    }));
    await symlink("../../outside", join(source, "escape"));
    const result = await preflightAgentHome({ source, destination });
    const serialized = JSON.stringify(result);

    expect(result.status).toBe("blocked");
    expect(codes(result)).toEqual(expect.arrayContaining(["external-relative-symlink", "configured-external-reference"]));
    expect(result.unresolvedSymlinks).toBe(1);
    expect(result.externalConfigurationReferences).toBe(3);
    expect(serialized).not.toContain("secret-session-body");
    expect(serialized).not.toContain("provider-token");
    expect(serialized).not.toContain("outside-extension");
  });

  it("inspects nested package resource patterns using Pi relative-base semantics", async () => {
    const root = await fixture("tron-agent-preflight-package-resources-");
    const source = join(root, "source");
    const destination = join(root, "new-agent");
    await mkdir(join(source, "packages", "pkg", "extensions"), { recursive: true });
    await writeFile(join(source, "packages", "pkg", "extensions", "safe.ts"), "export {};");
    await writeFile(join(source, "settings.json"), JSON.stringify({
      packages: [{ source: "./packages/pkg", extensions: ["extensions/*.ts", "!/private/nested-extension"] }],
    }));
    const before = await manifest(source);

    const result = await preflightAgentHome({ source, destination });
    const after = await manifest(source);

    expect(result.status).toBe("decision-required");
    expect(result.externalConfigurationReferences).toBe(1);
    expect(codes(result)).toContain("configured-external-reference");
    expect(JSON.stringify(result)).not.toContain("nested-extension");
    expect(after).toEqual(before);
  });

  it("flags absolute and home-expanded references as relocation-sensitive", async () => {
    const root = await fixture("tron-agent-preflight-relocation-");
    const source = join(root, "source");
    const destination = join(root, "new-agent");
    await mkdir(join(source, "secret-package", "extensions"), { recursive: true });
    await writeFile(join(source, "settings.json"), JSON.stringify({
      sessionDir: join(source, "secret-sessions"),
      extensions: [join(source, "secret-extensions")],
      themes: ["~/secret-theme"],
      packages: [{
        source: join(source, "secret-package"),
        extensions: [join(source, "secret-package", "extensions")],
      }],
    }));

    const result = await preflightAgentHome({ source, destination });
    const relocationIssues = result.issues.filter(entry => entry.code === "relocation-sensitive-reference");
    const serialized = JSON.stringify(result);

    expect(result.status).toBe("decision-required");
    expect(result.externalConfigurationReferences).toBe(5);
    expect(relocationIssues).toHaveLength(5);
    expect(serialized).not.toContain("secret-sessions");
    expect(serialized).not.toContain("secret-extensions");
    expect(serialized).not.toContain("secret-package");
    expect(serialized).not.toContain("secret-theme");
  });

  it("enforces entry, depth, and settings-size bounds", async () => {
    const root = await fixture("tron-agent-preflight-bounds-");
    const source = join(root, "source");
    await mkdir(source);
    for (let index = 0; index < 5; index += 1) await writeFile(join(source, `file-${index}`), "x");
    const entryLimited = await preflightAgentHome({ source, destination: join(root, "entry-destination"), maxEntries: 2 });
    expect(codes(entryLimited)).toContain("traversal-entry-limit");

    const deepSource = join(root, "deep");
    let current = deepSource;
    await mkdir(current);
    for (let index = 0; index < 66; index += 1) {
      current = join(current, "d");
      await mkdir(current);
    }
    const depthLimited = await preflightAgentHome({ source: deepSource, destination: join(root, "depth-destination") });
    expect(codes(depthLimited)).toContain("traversal-depth-limit");

    const largeSource = join(root, "large");
    await mkdir(largeSource);
    await writeFile(join(largeSource, "settings.json"), `{\"padding\":\"${"x".repeat(1 * 1024 * 1024)}\"}`);
    const sizeLimited = await preflightAgentHome({ source: largeSource, destination: join(root, "size-destination") });
    expect(codes(sizeLimited)).toContain("settings-size-limit");
  });

  it("preserves malformed settings and rejects non-absolute input", async () => {
    const root = await fixture("tron-agent-preflight-malformed-");
    const source = join(root, "source");
    const destination = join(root, "new-agent");
    await mkdir(source);
    const original = "{not-json\n";
    await writeFile(join(source, "settings.json"), original);

    const malformed = await preflightAgentHome({ source, destination });
    const relativeInput = await preflightAgentHome({ source: "relative-source", destination });
    const invalidDestination = await preflightAgentHome({ source, destination: "relative-destination" });
    const invalidLimit = await preflightAgentHome({ source, destination, maxEntries: 0 });

    expect(codes(malformed)).toContain("malformed-settings");
    expect(await readFile(join(source, "settings.json"), "utf8")).toBe(original);
    for (const invalid of [relativeInput, invalidDestination, invalidLimit]) {
      expect(invalid.status).toBe("blocked");
      expect(invalid.entriesInspected).toBe(0);
      expect(invalid.changesMade).toBe(false);
      expect(codes(invalid)).not.toContain("malformed-settings");
    }
    expect(codes(relativeInput)).toContain("absolute-path-required");
    expect(codes(invalidDestination)).toContain("absolute-path-required");
    expect(codes(invalidLimit)).toContain("invalid-entry-limit");
  });
});
