import { execFile, spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const GIT_IDENTITY = ["-c", "user.name=Tron Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"];

export async function publishedNpmRegistry(root: string, packages: readonly { name: string; versions: readonly string[]; latest: string }[]) {
  const tarballs = join(root, "tarballs");
  await mkdir(tarballs, { recursive: true });
  for (const { name, versions } of packages) {
    for (const version of versions) {
      const build = join(root, "build", name, version, "package");
      await mkdir(build, { recursive: true });
      await writeFile(join(build, "package.json"), JSON.stringify({ name, version }));
      await execFileAsync("tar", ["-czf", join(tarballs, `${name}-${version}.tgz`), "-C", join(root, "build", name, version), "package"]);
    }
  }
  const state = { latest: Object.fromEntries(packages.map(({ name, latest }) => [name, latest])) as Record<string, string>, base: "" };
  const server = createServer(async (request, response) => {
    const url = request.url ?? "";
    const published = packages.find(({ name }) => url === `/${name}`);
    if (published) {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({
        name: published.name,
        "dist-tags": { latest: state.latest[published.name] },
        versions: Object.fromEntries(published.versions.map(version => [version, { name: published.name, version,
          dist: { tarball: `${state.base}/-/${published.name}-${version}.tgz` } }])),
      }));
      return;
    }
    if (url.startsWith("/-/")) {
      const content = await readFile(join(tarballs, basename(url))).catch(() => undefined);
      if (content) { response.setHeader("content-type", "application/octet-stream"); response.end(content); return; }
    }
    response.statusCode = 404;
    response.end("{}");
  });
  await new Promise<void>(done => server.listen(0, "127.0.0.1", done));
  state.base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { base: state.base, state, close: () => new Promise<void>(done => server.close(() => done())) };
}

async function freePort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>(done => probe.listen(0, "127.0.0.1", done));
  const port = (probe.address() as AddressInfo).port;
  await new Promise<void>(done => probe.close(() => done()));
  return port;
}

export async function gitDaemonRepository(root: string, name: string) {
  const base = join(root, "git-daemon");
  const bare = join(base, `${name}.git`);
  const work = join(root, `${name}-work`);
  await mkdir(base, { recursive: true });
  await execFileAsync("git", ["init", "--bare", "--initial-branch=main", "-q", bare]);
  await execFileAsync("git", ["init", "-q", "--initial-branch=main", work]);
  const port = await freePort();
  const url = `git://127.0.0.1:${port}/${name}.git`;
  const daemon: ChildProcess = spawn("git", ["daemon", "--reuseaddr", "--export-all", "--listen=127.0.0.1", `--port=${port}`, `--base-path=${base}`, base], { stdio: "ignore" });
  for (let attempt = 0; ; attempt += 1) {
    if (await execFileAsync("git", ["ls-remote", url]).then(() => true, () => false)) break;
    if (attempt > 100) throw new Error("git daemon fixture did not start");
    await new Promise(done => setTimeout(done, 50));
  }
  const commit = async (content: string, message: string): Promise<string> => {
    await writeFile(join(work, "index.txt"), content);
    await execFileAsync("git", ["-C", work, "add", "index.txt"]);
    await execFileAsync("git", ["-C", work, ...GIT_IDENTITY, "commit", "-q", "-m", message]);
    await execFileAsync("git", ["-C", work, "push", "-q", bare, "HEAD:refs/heads/main"]);
    return (await execFileAsync("git", ["-C", work, "rev-parse", "HEAD"])).stdout.trim();
  };
  const locator = `example.test/${name}.git`;
  const activate = (): (() => void) => {
    const keys = ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"] as const;
    const saved = keys.map(key => process.env[key]);
    process.env.GIT_CONFIG_COUNT = "1";
    process.env.GIT_CONFIG_KEY_0 = `url.git://127.0.0.1:${port}/.insteadOf`;
    process.env.GIT_CONFIG_VALUE_0 = "https://example.test/";
    return () => keys.forEach((key, index) => {
      if (saved[index] === undefined) delete process.env[key]; else process.env[key] = saved[index];
    });
  };
  return { url, source: `git:${locator}`, commit, activate, close: () => new Promise<void>(done => { daemon.once("exit", () => done()); daemon.kill(); }) };
}
