/**
 * Stopped or restarted Home workers never block the maintainer (#929). Real RuntimeRegistry,
 * GatewayService and GatewayServer with a faux model; the claim journey runs the real
 * `scripts/tron work` CLI and owner-status helper against this Gateway over its socket.
 */
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile, copyFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fauxAssistantMessage, type Context } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "../transport/server.js";
import { GatewayService, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { waitFor } from "../../test-support/wait-for.js";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";

const REPO = resolve(process.cwd(), "../..");
const evidence: Array<Record<string, unknown>> = [];
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup().catch(() => {});
  await disposeFixtures();
});
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile("test-results/home-task-continuity.json", JSON.stringify({ suite: "home-task-continuity", evidence }, null, 2));
});

type Fixture = Awaited<ReturnType<typeof fixture>>;
/** A provider turn that holds until the task's Stop aborts it. */
const holding = (entered: { count: number }) => (_context: Context, options?: { signal?: AbortSignal }) => {
  entered.count += 1;
  return new Promise<never>((_resolve, reject) => {
    options?.signal?.addEventListener("abort", () => reject(new Error("stopped")), { once: true });
  });
};

async function listen(f: Fixture) {
  const devices = new DeviceStore(f.tronHome, "machine-task-test");
  await devices.initialize();
  const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: f.registry.homeOwner(),
    receipts: new CommandReceiptStore(join(f.root, "receipts")) } as unknown as GatewayServiceDependencies);
  const server = new GatewayServer({ host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576, devices, sessions: f.registry, service,
    uploads: { acquire: async () => ({ release: () => {} }), removeSession: async () => {} } as never,
    auth: { cancelOwner: () => {}, detachClient: () => {} } as never, logger: { log: () => {} } as never });
  await server.listen();
  cleanups.push(async () => { await server.close(); });
  return { service, port: (server as unknown as { server: { address(): { port: number } } }).server.address().port };
}

describe("claims of stopped Home workers", () => {
  it("hands a settled owner's claim to a live successor Home task without --force-maintainer and refuses a live owner", async () => {
    const f = await fixture();
    const { port } = await listen(f);
    const entered = { count: 0 };
    f.faux.setResponses([holding(entered), holding(entered)]);
    const stopped = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "worker-one", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered.count === 1, "first worker turn");
    await f.registry.homeOwner().stopTask({ taskId: stopped.taskId, operationId: stopped.operationId });
    expect((await stopped.completion).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const successor = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "worker-two", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered.count === 2, "successor worker turn");
    cleanups.push(async () => {
      await f.registry.homeOwner().stopTask({ taskId: successor.taskId, operationId: successor.operationId }).catch(() => {});
      await successor.completion.catch(() => {});
    });

    // A real claim, created by `work start` for the stopped worker's session.
    const root = await mkdtemp(join(tmpdir(), "tron-claim-takeover-"));
    cleanups.push(() => rm(root, { recursive: true, force: true }));
    const repo = join(root, "repo"), home = join(root, "home"), state = join(root, "github.json");
    for (const directory of [join(repo, ".github"), join(repo, "scripts"), home]) await mkdir(directory, { recursive: true });
    await copyFile(join(REPO, ".github/work.json"), join(repo, ".github/work.json"));
    await copyFile(join(REPO, "scripts/personal-info-guard.sh"), join(repo, "scripts/personal-info-guard.sh"));
    await writeFile(state, JSON.stringify({ state: "OPEN", status: "Ready", labels: [], blockers: [], comments: [], writes: [] }));
    const env = { ...process.env, HOME: home, TMPDIR: join(f.root, "tmp"), WORK_GH: join(REPO, "scripts/test-work-start.py"),
      WORK_START_FIXTURE: state, PYTHONDONTWRITEBYTECODE: "1", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
      TRON_DATA_DIR: f.tronHome, TRON_GATEWAY_HOST: "127.0.0.1", TRON_GATEWAY_PORT: String(port), PI_CODING_AGENT_DIR: f.agentDir };
    delete (env as Record<string, unknown>).PI_SESSION_ID;
    const git = (...args: string[]) => {
      const result = spawnSync("git", args, { cwd: repo, env, encoding: "utf8" });
      if (result.status) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
      return result.stdout.trim();
    };
    git("init", "-b", "main"); git("config", "user.name", "Fixture"); git("config", "user.email", "fixture@example.invalid");
    git("add", "."); git("commit", "-m", "base");
    git("init", "--bare", join(root, "remote.git")); git("remote", "add", "origin", join(root, "remote.git")); git("push", "origin", "main");
    const work = (session: string, ...args: string[]) => {
      const result = spawnSync("python3", [join(REPO, "tools/work/cli.py"), ...args], { cwd: repo, env: { ...env, WORK_SESSION_ID: session }, encoding: "utf8", timeout: 240_000 });
      evidence.push({ case: "work", session, args, exit: result.status, stdout: result.stdout, stderr: result.stderr });
      return result;
    };

    const created = work(stopped.sessionId, "start", "41");
    expect(created.status, created.stderr).toBe(0);
    const branch = /branch:\s+(\S+)/u.exec(created.stdout)![1]!;
    git("fetch", "-q", "origin");
    expect(git("log", "-1", "--format=%B", `origin/${branch}`)).toContain(`Work-Claim-Session: ${stopped.sessionId}`);

    // A session that runs no Home task is refused even though the owner is settled.
    const outsider = work("01a10000-0000-7000-8000-000000000000", "start", "41");
    expect(outsider.status).not.toBe(0);
    expect(outsider.stderr).toMatch(/settled owner .* runs no live Home task/u);

    // The successor Home task takes over automatically, audited, without --force-maintainer.
    const takeover = work(successor.sessionId, "start", "41");
    expect(takeover.status, takeover.stderr).toBe(0);
    git("fetch", "-q", "origin");
    const transfer = git("log", "-1", "--format=%B", `origin/${branch}`);
    expect(transfer).toContain(`Work-Claim-Session: ${successor.sessionId}`);
    expect(transfer).toContain(`Work-Handoff-From: ${stopped.sessionId}`);
    expect(transfer).toContain("successor Home task worker-two");
    const comments = (JSON.parse(await readFile(state, "utf8")) as { comments: string[] }).comments;
    expect(comments.some(comment => comment.includes(`\`${stopped.sessionId}\` → \`${successor.sessionId}\``))).toBe(true);

    // The successor is live: a further claimant is refused, naming the live verdict.
    const live = work("01a10000-0000-7000-8000-000000000001", "start", "41");
    expect(live.status).not.toBe(0);
    expect(live.stderr).toMatch(/owner is live/u);
    git("fetch", "-q", "origin");
    expect(git("log", "-1", "--format=%B", `origin/${branch}`)).toContain(`Work-Claim-Session: ${successor.sessionId}`);
    evidence.push({ case: "settled-claim-takeover", stopped: stopped.sessionId, successor: successor.sessionId, outsiderRefused: true, liveRefused: true });
  }, 300_000);
});
