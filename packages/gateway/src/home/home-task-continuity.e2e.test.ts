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
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { KnowledgeObservationService } from "../knowledge/knowledge-observation.js";
import { HOME_TASK_RUNNING_LIMIT } from "./home-task-dispatcher.js";

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
const PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
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
    // One fixture screenshot upload; the real store's validation is not this journey's boundary.
    materialize: async (ids: string[]) => ids.includes("screenshot-upload")
      ? { envelope: "[Attached image: screenshot.png]", images: [{ type: "image", data: PIXEL, mimeType: "image/png" }], attachments: [], photoCount: 1, fileAttachmentCount: 0 }
      : { envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 },
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
    send: async (sessionId: string, text: string, behavior?: "followUp" | "steer", uploadIds: string[] = []) => await client.request("session.prompt",
      { sessionId, text, uploadIds, commandId: randomUUID(), ...(behavior ? { behavior } : {}) }) as { operationId: string },
    /** The composer's Stop control. */
    stop: async (sessionId: string, operationId: string) => await client.request("session.abort", { sessionId, kind: "agent", operationId, commandId: randomUUID() }),
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
    let images = 0;
    f.faux.setResponses([holding(entered), (context: Context) => {
      seen.push(lastUser(context));
      const content = context.messages.findLast(message => message.role === "user")?.content;
      images = Array.isArray(content) ? content.filter(part => part.type === "image").length : 0;
      return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
    }]);
    const stopped = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "stopped-worker", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered.count === 1, "worker turn");
    await f.registry.homeOwner().stopTask({ taskId: stopped.taskId, operationId: stopped.operationId });
    await stopped.completion;
    await app.open(stopped.sessionId);
    // The maintainer continues it with the screenshots it was waiting for.
    const accepted = await app.send(stopped.sessionId, "continue with these screenshots", undefined, ["screenshot-upload"]);
    const resumed = await f.registry.homeOwner().taskStatus("stopped-worker.resume-1");
    expect(resumed).toMatchObject({ sessionId: stopped.sessionId, operationId: accepted.operationId });
    await waitFor(async () => (await f.registry.homeOwner().taskStatus("stopped-worker.resume-1")).lifecycle === "terminal", "maintainer-resumed task settles");
    expect(seen[0]).toContain("Instruction:\ncontinue with these screenshots\n\n[Attached image: screenshot.png]");
    expect(images).toBe(1);
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

/** Conversation observation on, wired to the Gateway's work registry as in gateway-main, with an
 * observation model call that holds until released: the stopped turn's settlement keeps
 * session-scoped `knowledge-observation` work live on the worker session. */
async function holdingObservation(f: Fixture) {
  const store = new KnowledgeStore(f.registry.knowledgeWorkspace());
  let release!: () => void;
  const released = new Promise<void>(resolve => { release = resolve; });
  const calls = { count: 0 };
  f.registry.setKnowledgeService(new KnowledgeService(store, new KnowledgeObservationService(store, { infer: async () => {
    calls.count += 1;
    await released;
    return JSON.stringify({ observations: [] });
  } }, f.registry.administrativeWorkRegistry)));
  const config = await store.config();
  await store.configure(randomUUID(), { ...config, eligibility: { ...config.eligibility, allSessions: true as const, projectIds: [] },
    observation: { ...config.observation, enabled: true, model: `${f.model.provider}/${f.model.id}` } });
  cleanups.push(async () => release());
  return { calls, release };
}

/** A worker turn that records the newest user text it saw, then reports. */
const reporting = (seen: string[], id = "report-one") => (context: Context) => {
  seen.push(lastUser(context));
  return fauxAssistantMessage([reportCall(id)], { stopReason: "toolUse" });
};

describe("maintainer messages to Home workers (#959)", () => {
  it("steers a message into a running worker in its session and never stops it", async () => {
    const f = await fixture();
    const { port } = await listen(f);
    const app = await maintainerClient(f, port);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const seen: string[] = [];
    f.faux.setResponses([
      async () => { await gate; return fauxAssistantMessage([fauxToolCall("read", { path: "missing" })], { stopReason: "toolUse" }); },
      reporting(seen),
    ]);
    const run = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "running-worker", intent: "Finite work", target: f.cwd });
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => slot.isBusy, "worker running");
    await app.open(run.sessionId);
    // The app's composer sends while the worker runs (no explicit behavior, as when Pi cannot queue).
    const accepted = await app.send(run.sessionId, "I did a vertical stroke");
    expect(accepted.operationId).toBeTruthy();
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ lifecycle: "active", operationId: run.operationId, stopIntent: null });
    release();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(seen[0]).toBe("I did a vertical stroke");
    await expect(f.registry.homeOwner().taskStatus(`${run.taskId}.resume-1`)).rejects.toThrow();
    evidence.push({ case: "959-running-worker-steered", taskId: run.taskId, delivered: seen[0], stopped: false });
  }, 60_000);

  it("resumes a stopped worker from the maintainer's message while the stopped turn is still being observed", async () => {
    const f = await fixture();
    const { port } = await listen(f);
    const app = await maintainerClient(f, port);
    const observation = await holdingObservation(f);
    const entered = { count: 0 };
    const seen: string[] = [];
    f.faux.setResponses([holding(entered), reporting(seen)]);
    const stopped = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "observed-worker", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered.count === 1, "worker turn");
    await app.open(stopped.sessionId);
    // The maintainer's Stop control, as on 2026-10-14 07:14:28.
    await app.stop(stopped.sessionId, stopped.operationId);
    expect((await stopped.completion).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    await waitFor(() => observation.calls.count > 0, "the stopped turn's observation is in flight");
    // Five seconds later the message arrives while that observation still runs.
    const accepted = await app.send(stopped.sessionId, "I did a vertical stroke");
    expect(await f.registry.homeOwner().taskStatus("observed-worker.resume-1")).toMatchObject({ sessionId: stopped.sessionId, operationId: accepted.operationId });
    await waitFor(async () => (await f.registry.homeOwner().taskStatus("observed-worker.resume-1")).lifecycle === "terminal", "resumed task settles");
    expect((await f.registry.homeOwner().taskStatus("observed-worker.resume-1")).terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(seen[0]).toContain("Instruction:\nI did a vertical stroke");
    observation.release();
    evidence.push({ case: "959-resume-during-observation", stopped: stopped.taskId, resumed: "observed-worker.resume-1", outcome: "final" });
  }, 60_000);

  it("queues a resume while the running-worker budget is full, then runs it in the same session with the message", async () => {
    const f = await fixture();
    const { port } = await listen(f);
    const app = await maintainerClient(f, port);
    const entered = { count: 0 };
    const seen: string[] = [];
    f.faux.setResponses([...Array.from({ length: HOME_TASK_RUNNING_LIMIT + 1 }, () => holding(entered)), reporting(seen)]);
    const stopped = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "capped-worker", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered.count === 1, "first worker turn");
    await f.registry.homeOwner().stopTask({ taskId: stopped.taskId, operationId: stopped.operationId });
    await stopped.completion;
    // The budget fills with other workers.
    const running: Array<Awaited<ReturnType<typeof dispatchRunning>>> = [];
    const dispatchRunning = (taskId: string) => f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId, intent: "Finite work", target: f.cwd });
    for (let index = 0; index < HOME_TASK_RUNNING_LIMIT; index += 1) {
      running.push(await dispatchRunning(`busy-${index}`));
      await waitFor(() => entered.count === index + 2, `busy worker ${index}`);
    }
    cleanups.push(async () => {
      for (const task of running) {
        await f.registry.homeOwner().stopTask({ taskId: task.taskId, operationId: task.operationId! }).catch(() => {});
        await task.completion.catch(() => {});
      }
    });
    await app.open(stopped.sessionId);
    const accepted = await app.send(stopped.sessionId, "I did a vertical stroke");
    const queued = await f.registry.homeOwner().taskStatus("capped-worker.resume-1");
    expect(queued).toMatchObject({ lifecycle: "pending", sessionId: null, resumes: { taskId: stopped.taskId, operationId: stopped.operationId } });
    expect(queued.queuedAt).toBeTruthy();
    expect(entered.count).toBe(HOME_TASK_RUNNING_LIMIT + 1);
    // A slot frees: the queued resume runs on the stopped worker's own session.
    await f.registry.homeOwner().stopTask({ taskId: running[0]!.taskId, operationId: running[0]!.operationId! });
    await waitFor(async () => (await f.registry.homeOwner().taskStatus("capped-worker.resume-1")).lifecycle === "terminal", "queued resume settles");
    expect(await f.registry.homeOwner().taskStatus("capped-worker.resume-1")).toMatchObject({ sessionId: stopped.sessionId, operationId: accepted.operationId,
      terminalEvidence: { outcome: "final", reason: "explicit-report" } });
    expect(seen[0]).toContain("Instruction:\nI did a vertical stroke");
    evidence.push({ case: "959-resume-queued-at-cap", stopped: stopped.taskId, resumed: "capped-worker.resume-1", queued: true, sessionId: stopped.sessionId });
  }, 120_000);

  it("keeps a stopped worker resumable after a refused resume and carries the undelivered message to the next one", async () => {
    const f = await fixture();
    const { port } = await listen(f);
    const app = await maintainerClient(f, port);
    const entered = { count: 0 };
    const seen: string[] = [];
    f.faux.setResponses([holding(entered), reporting(seen)]);
    const stopped = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "refused-worker", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered.count === 1, "worker turn");
    await app.open(stopped.sessionId);
    await app.stop(stopped.sessionId, stopped.operationId);
    await stopped.completion;
    // Other live work in the worker session (an export) genuinely refuses the rebind.
    const registry = f.registry.administrativeWorkRegistry;
    const work = registry.begin({ kind: "compaction-export", sessionId: stopped.sessionId, hostEpoch: registry.runtimeEpoch });
    await expect(app.send(stopped.sessionId, "I did a vertical stroke")).rejects.toThrow(/idle/u);
    const refused = await f.registry.homeOwner().taskStatus("refused-worker.resume-1");
    expect(refused).toMatchObject({ lifecycle: "terminal", sessionId: null, operationId: null,
      terminalEvidence: { outcome: "unknown", reason: "admission-refused", detail: expect.stringMatching(/idle/u) } });
    work.settle();
    // The stopped task is still resumable; the refused message reaches the worker with the new one.
    const resumed = await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "resume", taskId: stopped.taskId, operationId: stopped.operationId, text: "Then a horizontal one" }) as
      { taskId: string; sessionId: string; operationId: string };
    expect(resumed).toMatchObject({ taskId: "refused-worker.resume-2", sessionId: stopped.sessionId });
    await waitFor(async () => (await f.registry.homeOwner().taskStatus(resumed.taskId)).lifecycle === "terminal", "second resume settles");
    expect(await f.registry.homeOwner().taskStatus(resumed.taskId)).toMatchObject({ resumes: { taskId: stopped.taskId, operationId: stopped.operationId },
      terminalEvidence: { outcome: "final" } });
    expect(seen[0]).toMatch(/I did a vertical stroke[\s\S]*Then a horizontal one/u);
    await expect(f.registry.homeOwner().taskTool(f.home.sessionId, { action: "resume", taskId: stopped.taskId, operationId: stopped.operationId }))
      .rejects.toThrow(/already resumed as refused-worker\.resume-2/u);
    evidence.push({ case: "959-refused-resume-stays-resumable", refused: "refused-worker.resume-1", resumed: resumed.taskId, carried: true });
  }, 60_000);
});
