import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { disposeFixtures, fixture as homeFixture, reportCall } from "../../../../test-support/home-task-fixture.js";
import { displayOwnerOf, homeOwnerOf } from "../../../../test-support/gateway-registry.js";
import { setHomeMemoryModels } from "../../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../../transport/gateway-service.js";
import { CommandReceiptStore } from "../../../transport/command-receipts.js";
import { UploadStore } from "../../../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../../../config.js";
import type { ChangeResult } from "../../../kernel/settings/tool-contract.js";
import type { ExtensionInteraction } from "../../../protocol/types.js";
import { maintainerChange } from "../../../../test-support/native-change.js";

const exec = promisify(execFile);
const artifact = join(dirname(new URL(import.meta.url).pathname), "../../../../test-results/project-lifecycle/report.json");
const evidence: unknown[] = [];
const roots: string[] = [];
afterEach(async () => {
  const disposals = await Promise.allSettled([disposeFixtures()]);
  const removals = await Promise.allSettled(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  const failures = [...disposals, ...removals].flatMap(result => result.status === "rejected" ? [result.reason] : []);
  if (failures.length) throw new AggregateError(failures, "project fixture teardown failed");
});
afterAll(async () => { await mkdir(dirname(artifact), { recursive: true }); await writeFile(artifact, JSON.stringify(evidence, null, 2)); });
let command = 0;
const phone = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-project-lifecycle-")));
  roots.push(root);
  const workspace = join(root, "Workspace");
  await mkdir(workspace);
  let clock = Date.now();
  const f = await homeFixture(false, false, undefined, false, undefined, { projectOptions: { workspace }, settingsNow: () => new Date(clock) });
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
  const calls = new Map<string, { tool: "projects" | "settings"; args: Parameters<typeof fauxToolCall>[1] }>();
  const results = new Map<string, { isError: boolean; details: ChangeResult; text: string }>();
  const text = (message: { content: unknown }) => typeof message.content === "string" ? message.content : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("");
  const responder = (context: TranscriptContext): AssistantMessage => {
    const last = context.messages.at(-1)!;
    if (last.role === "toolResult") {
      const key = [...calls.keys()].findLast(key => context.messages.some(message => message.role === "user" && text(message) === key));
      if (key) results.set(key, { isError: last.isError === true, details: last.details as unknown as ChangeResult, text: text(last) });
      return fauxAssistantMessage("Done");
    }
    if (context.messages.some(message => message.role === "user" && text(message).includes("Report ready"))) return fauxAssistantMessage([reportCall("project-ready", "Trusted project admitted")], { stopReason: "toolUse" });
    const turn = context.messages.slice(context.messages.findLastIndex(message => message.role === "assistant") + 1);
    const key = turn.map(text).find(key => calls.has(key));
    return key ? fauxAssistantMessage([fauxToolCall(calls.get(key)!.tool, calls.get(key)!.args)], { stopReason: "toolUse" }) : fauxAssistantMessage("Outcome noted");
  };
  f.faux.setResponses(Array.from({ length: 100 }, () => responder as never));
  const settled = () => waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null && home.snapshot().phase === "idle" || undefined, "Home idle");
  const cards = new Map<string, { key: string; interaction: Extract<ExtensionInteraction, { method: "change" }> }>();
  async function request(args: { action: string; name: string }) {
    await (homeOwnerOf(f.registry) as unknown as { wakeDrain?: Promise<void> }).wakeDrain;
    await settled();
    const key = `project request ${++command}`;
    calls.set(key, args.action === "create"
      ? { tool: "projects", args: { reason: "Lifecycle boundary proof", name: args.name } }
      : { tool: "settings", args: { action: "change", reason: "Lifecycle boundary proof", changes: [
        { key: "permissions.projectTrust", layer: "global", op: "set", value: args.action === "trust", qualifiers: { project: path(args.name) } }] } });
    await home.prompt(key);
    const result = await waitFor(() => results.get(key) ?? (() => {
      const interaction = home.snapshot().extensionPresentation.pendingInteractions[0];
      if (interaction?.method !== "change") return undefined;
      cards.set(interaction.review.digest, { key, interaction });
      return { isError: false, text: "Exact native review", details: { status: "review" as const, review: interaction.review, changes: [] } };
    })(), "project result or exact native review");
    if (result.details.status !== "review") await settled();
    evidence.push({ args, ...result });
    return result;
  }
  const decide = async (result: ChangeResult, approved = true): Promise<ChangeResult> => {
    const card = cards.get(result.review!.digest);
    if (card) {
      const { interaction } = card;
      await service.invoke(phone, "extension.respond", { commandId: `project-native-${++command}`, sessionId: home.id,
        interactionId: interaction.id, hostEpoch: interaction.hostEpoch, presentationRevision: interaction.presentationRevision,
        value: { digest: result.review!.digest, approved } });
      const answer = await waitFor(() => results.get(card.key), "native project callback result");
      await settled();
      if (answer.isError) throw new Error(answer.text);
      return answer.details;
    }
    throw new Error("Native review has no card; nothing is applied without its exact tap");
  };
  const path = (name: string) => join(workspace, name);
  const git = async (name: string, args: string[]) => (await exec("git", ["-C", path(name), ...args])).stdout.trim();
  async function create(name: string) {
    const result = await request({ action: "create", name });
    expect(result.isError, result.text).toBe(false);
    expect(result.details.status).toBe("review");
    return result.details;
  }
  return { ...f, root, workspace, path, git, request, create, decide, changes, service, settled, advance: (ms: number) => { clock += ms; } };
}

describe("Gateway project lifecycle", () => {
  it("Cancel and Stop close the native continuation without filesystem effects or invented audit outcomes", async () => {
    const f = await fixture();
    const before = (await f.changes.record.page({ limit: 50 })).entries;
    const declined = await f.create("cancelled-create");
    expect((await f.decide(declined, false)).status).toBe("declined");
    await f.create("stopped-create");
    await (await f.registry.acquire(f.home.sessionId)).abort("agent");
    await f.settled();
    expect(await readdir(f.workspace)).toEqual([]);
    expect((await f.changes.record.page({ limit: 50 })).entries).toEqual(before);
  });

  it("retains the native response fence when a failed create's audit publication also fails", async () => {
    const f = await fixture(), audit = f.changes.record.path, retained = audit + "-retained";
    const realGit = (await exec("/usr/bin/which", ["git"])).stdout.trim();
    const bin = join(f.root, "failing-init-bin"), counter = join(f.root, "init-calls");
    await mkdir(bin);
    await writeFile(join(bin, "git"), `#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = init ]; then
    printf attempt >> ${JSON.stringify(counter)}
    mv ${JSON.stringify(audit)} ${JSON.stringify(retained)}
    printf blocked > ${JSON.stringify(audit)}
    exit 7
  fi
done
exec ${JSON.stringify(realGit)} "$@"
`, { mode: 0o700 });
    const reviewed = await f.create("uncertain-init");
    vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
    try {
      await expect(f.decide(reviewed)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
    } finally { vi.unstubAllEnvs(); }
    expect((await f.trust.inspect(f.path("uncertain-init"))).effectiveDecision).toBe(false);
    await rm(audit); await rename(retained, audit);
    const directory = join(f.tronHome, "state", "command-receipts");
    const receipts = await Promise.all((await readdir(directory)).filter(name => name.endsWith(".json")).map(async name =>
      JSON.parse(await readFile(join(directory, name), "utf8"))));
    const pending = receipts.filter(receipt => receipt.method === "extension.respond" && receipt.status === "pending");
    expect(pending).toHaveLength(1);
    await expect(f.service.invoke(phone, "extension.respond", { commandId: pending[0].commandId })).rejects.toMatchObject({
      code: "conflict", details: { outcomeUnknown: true } });
    expect(await readFile(counter, "utf8")).toBe("attempt");
    evidence.push({ failedAuditReceipt: pending[0], partialCreateRetained: true });
  });

  it("Home creates an untrusted main repository, approval grants trust and the real delegate owner immediately admits work", async () => {
    const f = await fixture();
    await f.decide(await f.create("slim-key"));
    expect((await f.request({ action: "untrust", name: "slim-key" })).details).toMatchObject({ status: "applied", changes: [{ key: "permissions.projectTrust", status: "applied" }] });
    expect(await f.git("slim-key", ["symbolic-ref", "--short", "HEAD"])).toBe("main");
    expect((await f.trust.inspect(f.path("slim-key"))).effectiveDecision).toBe(false);
    await expect(homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "untrusted-task", target: f.path("slim-key"), intent: "Report a finite result" }).then(handle => handle.completion)).rejects.toThrow(/trust/i);
    const pending = (await f.request({ action: "trust", name: "slim-key" })).details;
    expect((await f.decide(pending)).status).toBe("applied");
    expect((await f.trust.inspect(f.path("slim-key"))).effectiveDecision).toBe(true);
    const task = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "trusted-task", target: f.path("slim-key"), intent: "Report ready" });
    expect(task.taskId).toBeTruthy();
    const completed = await task.completion;
    expect(completed.lifecycle).toBe("terminal");
    evidence.push({ delegated: completed });
    expect(completed.reportRef?.resultId, JSON.stringify(completed)).toBe("project-ready");
  });

  it("refuses traversal, existing files/directories and a symlinked Workspace on creation", async () => {
    const f = await fixture();
    for (const name of ["../escape", "/tmp/escape", ".archive", "a/b", "a b", "trailing "]) expect((await f.request({ action: "create", name })).isError).toBe(true);
    await f.decide(await f.create("existing"));
    expect((await f.request({ action: "create", name: "existing" })).isError).toBe(true);
    await writeFile(f.path("existing-file"), "preserve");
    expect((await f.request({ action: "create", name: "existing-file" })).isError).toBe(true);
    expect(await readFile(f.path("existing-file"), "utf8")).toBe("preserve");
  });

  it("pins new exact roots under an enclosing repository and default-always trust", async () => {
    const f = await fixture();
    await maintainerChange(f.service, phone, "settings.change", { commandId: `default-trust-${++command}`, target: { kind: "global" },
      changes: [{ key: "permissions.defaultProjectTrust", layer: "global", op: "set", value: "always" }] });
    await exec("git", ["-C", f.workspace, "init", "--initial-branch=main"]);
    const ancestor = await f.trust.inspect(f.workspace);
    const pending = await f.create("nested");
    expect(await readdir(f.workspace)).not.toContain("nested");
    await f.decide(pending);
    expect((await f.trust.inspect(f.path("nested"))).projectDir).toBe(f.path("nested"));
    expect((await f.trust.inspect(f.workspace)).savedDecision).toBe(ancestor.savedDecision);
    const slot = await f.registry.create(f.path("nested"));
    expect(slot.cwd).toBe(f.path("nested"));
  });

  it("a symlinked Workspace refuses creation without moving or following the link", async () => {
    const f = await fixture();
    await rename(f.workspace, join(f.root, "relocated-workspace"));
    await symlink(join(f.root, "relocated-workspace"), f.workspace);
    expect((await f.request({ action: "create", name: "escaped" })).isError).toBe(true);
  });

  it("a busy refusal before reload never reports a nonexistent acquired fence or changes trust", async () => {
    const f = await fixture();
    await f.decide(await f.create("busy-reload"));
    const project = await f.registry.create(f.path("busy-reload"));
    let entered = false;
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { entered = true; await held; return fauxAssistantMessage("Released"); }]);
    const prompt = project.prompt("Hold the real runtime");
    try {
      await waitFor(() => entered || undefined, "busy reload runtime entered");
      const error = await f.trust.setAndApply(project.cwd, false,
        inspection => f.registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false),
        inspection => f.registry.commitProjectReload(inspection.projectDir),
        inspection => f.registry.abortProjectReload(inspection.projectDir)).catch(error => error as Error);
      expect(error).toMatchObject({ code: "internal", details: { failure: "Stop active sessions before changing project trust", rollbackFailure: "Stop active sessions before changing project trust" } });
      expect((await f.trust.inspect(project.cwd)).effectiveDecision).toBe(true);
      expect((await f.registry.create(project.cwd)).cwd).toBe(project.cwd);
      expect((error as Error).message).not.toMatch(/remains fenced/);
    } finally { release(); await prompt; }
  });

  it("a failed trust application with successful compensation restores trusted project resources without retiring the session", async () => {
    const f = await fixture();
    await f.decide(await f.create("restored-source"));
    const source = f.path("restored-source");
    await mkdir(join(source, ".pi", "extensions"), { recursive: true });
    await writeFile(join(source, ".pi", "extensions", "restoration-probe.ts"), `export default function(pi) {
  pi.registerTool({ name: "restoration_probe", label: "Restoration", description: "Trusted resource proof",
    parameters: { type: "object", properties: {} },
    execute: async () => ({ content: [{ type: "text", text: "trusted resource" }] }) });
}`);
    const slot = await f.registry.create(source);
    const tools = () => (slot as unknown as { runtime: { session: { getAllTools(): Array<{ name: string }> } } }).runtime.session.getAllTools().map(tool => tool.name);
    expect(tools()).toContain("restoration_probe");
    let applications = 0;
    await expect(f.trust.setAndApply(source, false, async inspection => {
      await f.registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false);
      if (++applications === 1) throw new Error("Fixture failure after the first native reload");
    }, inspection => f.registry.commitProjectReload(inspection.projectDir),
    inspection => f.registry.abortProjectReload(inspection.projectDir))).rejects.toThrow(/first native reload/);
    expect(applications).toBe(2);
    expect((await f.trust.inspect(source)).effectiveDecision).toBe(true);
    expect(slot.isDisposed).toBe(false);
    expect(tools()).toContain("restoration_probe");
    expect((await f.registry.create(source)).cwd).toBe(source);
  });

  it("failed application and compensation retire uncertain runtimes and release native project admission", async () => {
    const f = await fixture();
    await f.decide(await f.create("aborted-reload"));
    const source = f.path("aborted-reload");
    const slot = await f.registry.create(source);
    const start = f.events.length;
    try {
      await expect(f.trust.setAndApply(source, false, async inspection => {
        await f.registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false);
        throw new Error("Fixture failure after native reload, including compensation");
      }, inspection => f.registry.commitProjectReload(inspection.projectDir),
      inspection => f.registry.abortProjectReload(inspection.projectDir))).rejects.toMatchObject({ code: "internal" });
      expect((await f.registry.create(source)).cwd).toBe(source);
      expect(slot.isDisposed).toBe(true);
      await expect(slot.prompt("An aborted frame must not execute")).rejects.toMatchObject({ code: "conflict" });
      expect(f.events.slice(start).filter(event => event.topic === "session.resourcesChanged")).toEqual([]);
      expect((await f.trust.inspect(source)).effectiveDecision).toBe(true);
    } finally {
      if (!slot.isDisposed) await f.registry.commitProjectReload(source);
    }
  });


});
