import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { disposeFixtures, fixture as homeFixture, reportCall } from "../../../test-support/home-task-fixture.js";
import { displayOwnerOf, homeOwnerOf, projectsOwnerOf } from "../../../test-support/gateway-registry.js";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { UploadStore } from "../../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../../config.js";
import { APPROVAL_TTL_MS } from "../../kernel/settings/settings-approvals.js";
import { SETTINGS_OUTCOME_MESSAGE, type ChangeResult } from "../../kernel/settings/tool-contract.js";

const exec = promisify(execFile);
const artifact = join(dirname(new URL(import.meta.url).pathname), "../../../test-results/project-lifecycle/report.json");
const evidence: unknown[] = [];
const roots: string[] = [];
afterEach(async () => { await disposeFixtures(); await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
afterAll(async () => { await mkdir(dirname(artifact), { recursive: true }); await writeFile(artifact, JSON.stringify(evidence, null, 2)); });
let command = 0;
const phone = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;

async function fixture(github = false) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-project-lifecycle-")));
  roots.push(root);
  const workspace = join(root, "Workspace");
  await mkdir(workspace);
  const executable = join(root, "gh-fixture");
  // A spawned fixture executable, not a mocked settings/TrustService method.
  // It records the real CLI arguments and emulates only GitHub's external port.
  await writeFile(executable, `#!/bin/sh\nprintf '%s\\n' "$@" > ${JSON.stringify(join(root, "gh-args"))}\n[ "$1" = repo ] && [ "$2" = create ] && [ "$4" = --private ] || exit 2\ngit -C "$6" remote add origin "https://github.invalid/fixture/$3.git"\n`, { mode: 0o700 });
  let clock = Date.now();
  const f = await homeFixture(false, false, undefined, false, undefined, { projectOptions: { workspace, ...(github ? { githubExecutable: executable } : {}) }, settingsNow: () => new Date(clock) });
  const changes = f.settings.settingsChanges;
  await setHomeMemoryModels(f.registry, [f.model]);
  const service = new GatewayService({ display: displayOwnerOf(f.registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel: f.settings.settingsModel, settingsChanges: changes, sessions: f.registry, home: homeOwnerOf(f.registry),
    receipts: new CommandReceiptStore(f.tronHome), uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES),
    notifications: { enqueue: async () => "queued" }, broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (op: () => Promise<unknown>) => op(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const home = await f.registry.acquire(f.home.sessionId);
  const calls = new Map<string, Record<string, unknown>>();
  const results = new Map<string, { isError: boolean; details: ChangeResult; text: string }>();
  const text = (message: { content: unknown }) => typeof message.content === "string" ? message.content : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("");
  const responder = (context: TranscriptContext): AssistantMessage => {
    const last = context.messages.at(-1)!;
    if (last.role === "toolResult") {
      const key = [...calls.keys()].findLast(key => context.messages.some(message => message.role === "user" && text(message) === key));
      if (key) results.set(key, { isError: last.isError === true, details: last.details as ChangeResult, text: text(last) });
      return fauxAssistantMessage("Done");
    }
    if (context.messages.some(message => message.role === "user" && text(message).includes("Report ready"))) return fauxAssistantMessage([reportCall("project-ready", "Trusted project admitted")], { stopReason: "toolUse" });
    const turn = context.messages.slice(context.messages.findLastIndex(message => message.role === "assistant") + 1);
    const key = turn.map(text).find(key => calls.has(key));
    return key ? fauxAssistantMessage([fauxToolCall("projects", calls.get(key)!)], { stopReason: "toolUse" }) : fauxAssistantMessage("Outcome noted");
  };
  f.faux.setResponses(Array.from({ length: 100 }, () => responder as never));
  const settled = () => waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null && home.snapshot().phase === "idle" || undefined, "Home idle");
  async function request(args: Record<string, unknown>) {
    await (homeOwnerOf(f.registry) as unknown as { wakeDrain?: Promise<void> }).wakeDrain;
    await settled();
    const key = `project request ${++command}`;
    calls.set(key, { reason: "Lifecycle boundary proof", ...args });
    await home.prompt(key);
    const result = await waitFor(() => results.get(key), "project tool result");
    await settled();
    evidence.push({ args, ...result });
    return result;
  }
  const decide = (result: ChangeResult, approved = true) => service.invoke(phone, "settings.decide", { commandId: `project-decision-${++command}`, requestId: result.approval!.requestId, digest: result.approval!.digest, approved }) as Promise<ChangeResult>;
  const outcomes = () => home.canonicalSessionEntries().flatMap(entry => entry.type === "custom_message" && entry.customType === SETTINGS_OUTCOME_MESSAGE ? [entry] : []);
  const path = (name: string) => join(workspace, name);
  const git = async (name: string, args: string[]) => (await exec("git", ["-C", path(name), ...args])).stdout.trim();
  async function create(name: string, github = false) {
    const result = await request({ action: "create", name, github });
    expect(result.isError, result.text).toBe(false);
    expect(result.details.status).toBe("pending");
    return result.details;
  }
  return { ...f, root, workspace, path, git, request, create, decide, outcomes, changes, service, settled, advance: (ms: number) => { clock += ms; } };
}

describe("Gateway project lifecycle", () => {
  it("Home creates an untrusted main repository, approval grants trust and the real delegate owner immediately admits work", async () => {
    const f = await fixture();
    const pending = await f.create("slim-key");
    expect(await f.git("slim-key", ["symbolic-ref", "--short", "HEAD"])).toBe("main");
    expect((await f.trust.inspect(f.path("slim-key"))).effectiveDecision).toBe(false);
    await expect(homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "untrusted-task", target: f.path("slim-key"), intent: "Report a finite result" }).then(handle => handle.completion)).rejects.toThrow(/trust/i);
    const projection = await f.service.invoke(phone, "settings.approvals", {}) as unknown as { requests: Array<{ action?: { subject: string } }> };
    expect(projection.requests.some(request => request.action?.subject === "project.lifecycle")).toBe(true);
    await expect(f.changes.decide(pending.approval!.requestId, { digest: pending.approval!.digest, approved: true, decidedBy: { kind: "home", id: f.home.sessionId } })).rejects.toThrow(/maintainer/i);
    expect((await f.decide(pending)).status).toBe("approved");
    expect((await f.trust.inspect(f.path("slim-key"))).effectiveDecision).toBe(true);
    await waitFor(() => f.outcomes().some(entry => JSON.stringify(entry).includes(pending.approval!.requestId)) || undefined, "Home hears trust outcome");
    const task = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "trusted-task", target: f.path("slim-key"), intent: "Report ready" });
    expect(task.taskId).toBeTruthy();
    const completed = await task.completion;
    expect(completed.lifecycle).toBe("terminal");
    evidence.push({ delegated: completed });
    expect(completed.reportRef?.resultId, JSON.stringify(completed)).toBe("project-ready");
  });

  it("decline and 24h expiry never grant authority and the requester hears both", async () => {
    const f = await fixture();
    const declined = await f.create("declined");
    expect((await f.decide(declined, false)).status).toBe("declined");
    const expired = await f.create("expired");
    f.advance(APPROVAL_TTL_MS + 1);
    await f.changes.pendingApprovals();
    await expect(f.decide(expired)).rejects.toThrow(/no longer|expired/i);
    for (const name of ["declined", "expired"]) expect((await f.trust.inspect(f.path(name))).effectiveDecision).toBe(false);
    await waitFor(() => [declined, expired].every(result => f.outcomes().some(entry => JSON.stringify(entry).includes(result.approval!.requestId))) || undefined, "Home hears both outcomes");
  });

  it("refuses traversal, existing files/directories, project symlinks and archive symlink escape", async () => {
    const f = await fixture();
    for (const name of ["../escape", "/tmp/escape", ".archive", "a/b", "a b"]) expect((await f.request({ action: "create", name })).isError).toBe(true);
    const pending = await f.create("existing");
    expect((await f.request({ action: "create", name: "existing" })).isError).toBe(true);
    await writeFile(f.path("existing-file"), "preserve");
    expect((await f.request({ action: "create", name: "existing-file" })).isError).toBe(true);
    await symlink(f.path("existing"), f.path("linked"));
    expect((await f.request({ action: "trust", name: "linked" })).isError).toBe(true);
    await f.decide(pending);
    await symlink(f.root, f.path(".archive"));
    expect((await f.request({ action: "archive", name: "existing" })).isError).toBe(true);
    expect(await readFile(f.path("existing-file"), "utf8")).toBe("preserve");
  });

  it("rename, archive and untrust require taps, retain data and leave no stale trusted source name", async () => {
    const f = await fixture();
    await f.decide(await f.create("original"));
    await writeFile(f.path("original/data"), "keep this");
    const rename = await f.request({ action: "rename", name: "original", newName: "renamed" });
    expect(rename.isError, rename.text).toBe(false);
    expect(await readFile(f.path("original/data"), "utf8")).toBe("keep this");
    await f.decide(rename.details);
    expect(await readFile(f.path("renamed/data"), "utf8")).toBe("keep this");
    expect((await f.trust.inspect(f.path("renamed"))).effectiveDecision).toBe(true);
    const untrust = await f.request({ action: "untrust", name: "renamed" });
    expect(untrust.isError, untrust.text).toBe(false);
    expect((await f.trust.inspect(f.path("renamed"))).effectiveDecision).toBe(true);
    await f.decide(untrust.details);
    expect((await f.trust.inspect(f.path("renamed"))).effectiveDecision).toBe(false);
    const archive = await f.request({ action: "archive", name: "renamed" });
    expect(archive.isError, archive.text).toBe(false);
    await f.decide(archive.details);
    const [name] = await readdir(f.path(".archive"));
    expect(await readFile(f.path(`.archive/${name}/data`), "utf8")).toBe("keep this");
    expect((await f.trust.inspect(f.path(`.archive/${name}`))).effectiveDecision).toBe(false);
    await mkdir(f.path("original"));
    expect((await f.trust.inspect(f.path("original"))).effectiveDecision).toBe(false);
  });

  it("busy real project sessions and linked worktrees refuse archive, including work starting after submission", async () => {
    const f = await fixture();
    await f.decide(await f.create("busy"));
    const pending = await f.request({ action: "archive", name: "busy" });
    expect(pending.isError, pending.text).toBe(false);
    let release!: () => void;
    let entered = false;
    const held = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { entered = true; await held; return fauxAssistantMessage("Worker finished"); }]);
    const worker = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "busy-worker", target: f.path("busy"), intent: "Hold this real worker active" });
    await waitFor(() => entered || undefined, "worker model entered");
    const direct = () => projectsOwnerOf(f.registry)!.request({ action: "archive", name: "busy", reason: "Busy boundary" }, { kind: "home", id: f.home.sessionId, sessionId: f.home.sessionId }, `busy-request-${++command}`);
    try {
      await expect(f.decide(pending.details)).rejects.toThrow(/superseded|session|busy/i);
      await expect(direct()).rejects.toThrow(/session|busy|worker/i);
    } finally { release(); await worker.completion; }
    await f.git("busy", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"]);
    await f.git("busy", ["worktree", "add", "-b", "worker", join(f.root, "worker-tree")]);
    await expect(projectsOwnerOf(f.registry)!.request({ action: "untrust", name: "busy", reason: "Worktree boundary" }, { kind: "home", id: f.home.sessionId }, `worktree-request-${++command}`)).rejects.toThrow(/worktree/i);
  });

  it("pins new exact roots under an enclosing repository and default-always trust; partial relocation stays untrusted", async () => {
    const f = await fixture();
    await f.changes.change({ kind: "global" }, [{ key: "permissions.defaultProjectTrust", layer: "global", op: "set", value: "always" }], { actor: { kind: "ui", id: "fixture" } });
    await exec("git", ["-C", f.workspace, "init", "--initial-branch=main"]);
    const ancestor = await f.trust.inspect(f.workspace);
    const pending = await f.create("nested");
    expect((await f.trust.inspect(f.path("nested"))).effectiveDecision).toBe(false);
    expect((await f.trust.inspect(f.workspace)).savedDecision).toBe(ancestor.savedDecision);
    await f.decide(pending);
    const destination = f.path("retained");
    await mkdir(destination);
    let release!: () => void;
    let entered = false;
    const held = new Promise<void>(resolve => { release = resolve; });
    const relocating = f.trust.relocate(f.path("nested"), destination, false, async () => {
      entered = true;
      await held;
      await rename(f.path("nested"), destination);
      throw new Error("fixture interrupted after filesystem effect");
    }, inspection => f.registry.reloadProject(inspection.projectDir, false, false), inspection => f.registry.commitProjectReload(inspection.projectDir));
    try {
      await waitFor(() => entered || undefined, "relocation fence acquired");
      await expect(f.registry.create(f.path("nested"))).rejects.toThrow(/trust|reconfigured|busy/i);
      expect((await f.trust.inspect(destination)).effectiveDecision).toBe(false);
    } finally { release(); }
    await expect(relocating).rejects.toThrow(/fixture interrupted/);
    expect((await f.trust.inspect(destination)).effectiveDecision).toBe(false);
    await mkdir(f.path("nested"));
    await exec("git", ["-C", f.path("nested"), "init", "--initial-branch=main"]);
    expect((await f.trust.inspect(f.path("nested"))).effectiveDecision).toBe(false);
    const slot = await f.registry.create(f.path("nested"));
    expect(slot.cwd).toBe(f.path("nested"));
  });

  it("identity replacement supersedes approval, workspace symlinks refuse and retained claim branches block effects", async () => {
    const f = await fixture();
    const pending = await f.create("replaced");
    await rename(f.path("replaced"), join(f.root, "retained-source"));
    await mkdir(join(f.root, "outside"));
    await symlink(join(f.root, "outside"), f.path("replaced"));
    await expect(f.decide(pending)).rejects.toThrow(/superseded|symlink/i);
    expect((await f.trust.inspect(join(f.root, "outside"))).effectiveDecision).not.toBe(true);
    const claimed = await f.create("claimed");
    await f.decide(claimed);
    await f.git("claimed", ["checkout", "-b", "feat/42-worker"]);
    await f.git("claimed", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "claim\n\nWork-Claim-Session: fixture-worker"]);
    expect((await f.request({ action: "archive", name: "claimed" })).isError).toBe(true);
    await rename(f.workspace, join(f.root, "relocated-workspace"));
    await symlink(join(f.root, "relocated-workspace"), f.workspace);
    expect((await f.request({ action: "create", name: "escaped" })).isError).toBe(true);
  });

  it("optional private GitHub creation crosses only the approved spawned fixture boundary and sets origin without a push", async () => {
    const f = await fixture(true);
    const pending = await f.create("private-project", true);
    await expect(readFile(join(f.root, "gh-args"))).rejects.toThrow();
    await f.decide(pending);
    const args = await readFile(join(f.root, "gh-args"), "utf8");
    expect(args.split("\n")).toEqual(["repo", "create", "private-project", "--private", "--source", f.path("private-project"), "--remote", "origin", ""]);
    expect(await f.git("private-project", ["remote", "get-url", "origin"])).toBe("https://github.invalid/fixture/private-project.git");
    expect((await f.trust.inspect(f.path("private-project"))).effectiveDecision).toBe(true);
    await expect(f.decide(pending)).rejects.toThrow(/no longer|approved/i);
  });
});
