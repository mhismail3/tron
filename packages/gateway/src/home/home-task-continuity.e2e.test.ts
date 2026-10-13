/**
 * Stopped or restarted Home workers never block the maintainer (#929). Real RuntimeRegistry,
 * GatewayService and GatewayServer with a faux model; the claim journey runs the real
 * `scripts/tron work` CLI and owner-status helper against this Gateway over its socket.
 */
import { execFile, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import { mkdir, mkdtemp, readFile, rm, writeFile, copyFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type Context } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "../transport/server.js";
import { GatewayService, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { waitFor } from "../../test-support/wait-for.js";
import { disposeFixtures, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { TRON_ASK_USER_INTERRUPTED } from "../extensions/tron-ask-user-contract.js";
import { GatewayProtocolClient } from "../client/gateway-client.js";
import { readLocalCredential } from "../client/local-credential.js";

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
  const uploads = {
    acquire: async () => ({ release: () => {} }), removeSession: async () => {},
    materialize: async () => ({ envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 }),
  };
  const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: f.registry.homeOwner(), uploads,
    receipts: new CommandReceiptStore(join(f.root, "receipts")), logger: { log: () => {} } } as unknown as GatewayServiceDependencies);
  const server = new GatewayServer({ host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576, devices, sessions: f.registry, service,
    uploads: uploads as never,
    auth: { cancelOwner: () => {}, detachClient: () => {} } as never, logger: { log: () => {} } as never });
  await server.listen();
  cleanups.push(async () => { await server.close(); });
  return { service, port: (server as unknown as { server: { address(): { port: number } } }).server.address().port };
}

const APPROVAL = { title: "Approval", questions: [{ question: "Move the claim to the active worker?", options: [{ label: "Move it" }, { label: "Keep it" }] }] };
/** The text of the newest user message the provider saw. */
const lastUser = (context: Context) => {
  const message = context.messages.findLast(candidate => candidate.role === "user");
  const content = message?.content;
  return typeof content === "string" ? content : (content ?? []).map(part => part.type === "text" ? part.text : "").join("");
};
/** The maintainer's app over the Gateway's real socket: open (subscribe) a chat, then send to it. */
async function maintainerClient(f: Fixture, port: number) {
  const client = new GatewayProtocolClient(`ws://127.0.0.1:${port}/v1/socket`, await readLocalCredential(f.tronHome));
  await client.connect(5_000);
  cleanups.push(async () => client.close());
  return {
    open: async (sessionId: string) => {
      const baseline = await client.request("session.open", { sessionId }) as { syncToken: string };
      await client.request("session.sync", { sessionId, syncToken: baseline.syncToken });
    },
    send: async (sessionId: string, text: string, behavior?: "followUp" | "steer") => await client.request("session.prompt",
      { sessionId, text, uploadIds: [], commandId: randomUUID(), ...(behavior ? { behavior } : {}) }) as { operationId: string },
  };
}

/** The worker re-asks, as the resume brief tells it, the exact question it restates. */
const reAsk = (seen: string[]) => (context: Context) => {
  const brief = lastUser(context);
  seen.push(brief);
  const start = brief.indexOf("{", brief.indexOf("ask it again"));
  const json = brief.slice(start, brief.lastIndexOf("}") + 1);
  return fauxAssistantMessage([fauxToolCall("ask_user", JSON.parse(json))], { stopReason: "toolUse" });
};

describe("resuming a stopped Home worker in place", () => {
  it("continues the same session and worktree from Home's task tool and re-asks the question the stop interrupted inside codemode", async () => {
    const f = await fixture(false, true);
    const { port } = await listen(f);
    const seen: string[] = [];
    // After the Stop the provider may or may not be asked again; each turn answers by what it sees.
    const turn = (context: Context) => {
      const last = context.messages.at(-1);
      if (last?.role === "toolResult" && last.toolName === "ask_user") {
        seen.push(JSON.stringify(last.content));
        return fauxAssistantMessage([reportCall("resumed-result", "Claim moved")], { stopReason: "toolUse" });
      }
      return lastUser(context).includes("ask it again") && last?.role === "user" ? reAsk(seen)(context) : fauxAssistantMessage("stopped");
    };
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: `return await tools.ask_user(${JSON.stringify(APPROVAL)});` }, { id: "approval-parent" })], { stopReason: "toolUse" }),
      turn, turn, turn,
    ]);
    const stopped = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "ios-worker", intent: "Finite work", target: f.cwd });
    const slot = await f.registry.acquire(stopped.sessionId);
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.some(item => item.method === "form"), "codemode approval question pending");
    await f.registry.homeOwner().stopTask({ taskId: stopped.taskId, operationId: stopped.operationId });
    expect((await stopped.completion).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const interrupted = slot.canonicalSessionEntries().filter(entry => entry.type === "custom" && entry.customType === TRON_ASK_USER_INTERRUPTED);
    expect(interrupted).toHaveLength(1);

    // Home continues it through its real task tool: no new worker, session or worktree.
    const sessionsBefore = (await f.registry.list("all")).length;
    const resumed = await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "resume", taskId: stopped.taskId, operationId: stopped.operationId }) as
      { taskId: string; sessionId: string; operationId: string };
    expect(resumed).toMatchObject({ taskId: "ios-worker.resume-1", sessionId: stopped.sessionId });
    expect(resumed.operationId).not.toBe(stopped.operationId);
    expect(await f.registry.acquire(stopped.sessionId)).toBe(slot);
    expect(slot.cwd).toBe((await f.registry.homeOwner().taskStatus(stopped.taskId)).target);
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.some(item => item.method === "form"), "re-asked approval question").catch(async error => {
      throw new Error(`${error.message}; seen=${JSON.stringify(seen).slice(0, 3000)}; status=${JSON.stringify((await f.registry.homeOwner().taskStatus(resumed.taskId)).terminalEvidence)}; tail=${JSON.stringify(slot.canonicalSessionEntries().slice(-6)).slice(0, 4000)}`);
    });
    const asked = slot.snapshot().extensionPresentation.pendingInteractions.find(item => item.method === "form")!;
    expect(asked.method === "form" && asked.form.questions.map(question => question.question)).toEqual([APPROVAL.questions[0]!.question]);
    expect(seen[0]).toContain(`Continue Home task ${stopped.taskId} in place`);
    // The work claim names the session, so it stays with the resumed task: the work tooling's
    // own owner check reads the session's live task as the successor.
    const owner = await promisify(execFile)("python3", ["-c", "import sys; sys.path.insert(0, sys.argv[1]); import handoff; print(handoff.home_task(sys.argv[2])[0])",
      join(REPO, "tools/work"), stopped.sessionId], { env: { ...process.env, TRON_DATA_DIR: f.tronHome, TRON_GATEWAY_HOST: "127.0.0.1", TRON_GATEWAY_PORT: String(port) }, encoding: "utf8" });
    expect(owner.stdout.trim()).toBe(resumed.taskId);
    slot.respondToInteraction(asked.id, asked.hostEpoch, asked.presentationRevision,
      { version: 1, answers: [{ questionId: "question-0", optionIds: ["question-0-option-0"] }] }, false);
    await waitFor(async () => (await f.registry.homeOwner().taskStatus(resumed.taskId)).lifecycle === "terminal", "resumed task settles");
    const final = await f.registry.homeOwner().taskStatus(resumed.taskId);
    expect(final).toMatchObject({ sessionId: stopped.sessionId, resumes: { taskId: stopped.taskId, operationId: stopped.operationId },
      terminalEvidence: { outcome: "final", reason: "explicit-report" } });
    expect(seen[1]).toContain("Move it");
    expect((await f.registry.list("all")).length).toBe(sessionsBefore);
    // The stopped task stays immutable and has exactly one successor.
    expect(await f.registry.homeOwner().taskStatus(stopped.taskId)).toMatchObject({ terminalEvidence: { outcome: "interrupted" } });
    await expect(f.registry.homeOwner().taskTool(f.home.sessionId, { action: "resume", taskId: stopped.taskId, operationId: stopped.operationId }))
      .rejects.toThrow(/already resumed as ios-worker\.resume-1/u);
    evidence.push({ case: "resume-in-place", stopped: stopped.taskId, resumed: resumed.taskId, sessionId: stopped.sessionId, reAsked: APPROVAL.questions[0]!.question, outcome: "final" });
  }, 60_000);

  it("resumes a stopped worker from the maintainer's message in its chat instead of refusing it", async () => {
    const f = await fixture();
    const { port } = await listen(f);
    const app = await maintainerClient(f, port);
    const entered = { count: 0 };
    const seen: string[] = [];
    f.faux.setResponses([holding(entered), (context: Context) => { seen.push(lastUser(context)); return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); }]);
    const stopped = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "stopped-worker", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered.count === 1, "worker turn");
    await f.registry.homeOwner().stopTask({ taskId: stopped.taskId, operationId: stopped.operationId });
    await stopped.completion;
    await app.open(stopped.sessionId);
    const accepted = await app.send(stopped.sessionId, "continue");
    const resumed = await f.registry.homeOwner().taskStatus("stopped-worker.resume-1");
    expect(resumed).toMatchObject({ sessionId: stopped.sessionId, operationId: accepted.operationId });
    await waitFor(async () => (await f.registry.homeOwner().taskStatus("stopped-worker.resume-1")).lifecycle === "terminal", "maintainer-resumed task settles");
    expect(seen[0]).toContain("Instruction:\ncontinue");
    evidence.push({ case: "maintainer-message-resumes", sessionId: stopped.sessionId, resumed: "stopped-worker.resume-1" });
  }, 60_000);
});

describe("one ordered message lane per Home worker", () => {
  it("orders the maintainer's composer message after Home's steering while the worker runs", async () => {
    const f = await fixture();
    const { port } = await listen(f);
    const app = await maintainerClient(f, port);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([
      async () => { await gate; return fauxAssistantMessage([fauxToolCall("read", { path: "missing" })], { stopReason: "toolUse" }); },
      fauxAssistantMessage([fauxToolCall("read", { path: "missing" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }),
    ]);
    const run = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "shared-lane", intent: "Finite work", target: f.cwd });
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => slot.isBusy, "worker running");
    await app.open(run.sessionId);
    await f.registry.homeOwner().steerTask(f.home.sessionId, { taskId: run.taskId, operationId: run.operationId, text: "Home first" });
    // The app's composer sends a follow-up while the chat runs; it joins Home's steering lane.
    await app.send(run.sessionId, "Maintainer second", "followUp");
    release();
    const result = await run.completion;
    expect(result.terminalEvidence?.outcome).toBe("final");
    const users = slot.canonicalSessionEntries().flatMap(entry => entry.type === "message" && entry.message.role === "user"
      ? [typeof entry.message.content === "string" ? entry.message.content : entry.message.content.map(part => part.type === "text" ? part.text : "").join("")] : []);
    expect(users.indexOf("Home first")).toBeGreaterThan(0);
    expect(users.indexOf("Maintainer second")).toBeGreaterThan(users.indexOf("Home first"));
    evidence.push({ case: "shared-lane-maintainer-and-home", order: users.slice(1) });
  }, 60_000);
});

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
    // Asynchronous: the Gateway answering the owner-status helper runs in this process.
    const work = async (session: string, ...args: string[]) => {
      const result = await promisify(execFile)("python3", [join(REPO, "tools/work/cli.py"), ...args], { cwd: repo, env: { ...env, WORK_SESSION_ID: session }, encoding: "utf8", timeout: 240_000 })
        .then(({ stdout, stderr }) => ({ status: 0, stdout, stderr }), (error: { code?: number; stdout?: string; stderr?: string }) => ({ status: error.code ?? 1, stdout: error.stdout ?? "", stderr: error.stderr ?? "" }));
      evidence.push({ case: "work", session, args, exit: result.status, stdout: result.stdout, stderr: result.stderr });
      return result;
    };

    const created = await work(stopped.sessionId, "start", "41");
    expect(created.status, created.stderr).toBe(0);
    const branch = /branch:\s+(\S+)/u.exec(created.stdout)![1]!;
    git("fetch", "-q", "origin");
    expect(git("log", "-1", "--format=%B", `origin/${branch}`)).toContain(`Work-Claim-Session: ${stopped.sessionId}`);

    // A session that runs no Home task is refused even though the owner is settled.
    const outsider = await work("01a10000-0000-7000-8000-000000000000", "start", "41");
    expect(outsider.status).not.toBe(0);
    expect(outsider.stderr).toMatch(/settled owner .* runs no live Home task/u);

    // The successor Home task takes over automatically, audited, without --force-maintainer.
    const takeover = await work(successor.sessionId, "start", "41");
    expect(takeover.status, takeover.stderr).toBe(0);
    git("fetch", "-q", "origin");
    const transfer = git("log", "-1", "--format=%B", `origin/${branch}`);
    expect(transfer).toContain(`Work-Claim-Session: ${successor.sessionId}`);
    expect(transfer).toContain(`Work-Handoff-From: ${stopped.sessionId}`);
    expect(transfer).toContain("successor Home task worker-two");
    const comments = (JSON.parse(await readFile(state, "utf8")) as { comments: string[] }).comments;
    expect(comments.some(comment => comment.includes(`\`${stopped.sessionId}\` → \`${successor.sessionId}\``))).toBe(true);

    // The successor is live: a further claimant is refused, naming the live verdict.
    const live = await work("01a10000-0000-7000-8000-000000000001", "start", "41");
    expect(live.status).not.toBe(0);
    expect(live.stderr).toMatch(/owner is live/u);
    git("fetch", "-q", "origin");
    expect(git("log", "-1", "--format=%B", `origin/${branch}`)).toContain(`Work-Claim-Session: ${successor.sessionId}`);
    evidence.push({ case: "settled-claim-takeover", stopped: stopped.sessionId, successor: successor.sessionId, outsiderRefused: true, liveRefused: true });
  }, 300_000);
});
