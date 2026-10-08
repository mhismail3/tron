import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeTaskAuthorization } from "./home-task-authorization.js";
import { HomeTaskStore } from "./home-task-store.js";
import { HomeOwner, type HomeSessionPort } from "./home-owner.js";

// The unreleased pre-route held build is fixed, not a moving branch tip.
const ROLLBACK_REVISION = "1f48788984de2bd6e706a230c8e8c97afd4a0058";
const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
const owners: HomeOwner[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

it("preserves and refuses a newer Home record in the held build, then reads it unchanged in the current build", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-task-rollback-"));
  roots.push(root);
  const workspace = new TronWorkspace(root);
  workspaces.push(workspace);
  await workspace.initialize();
  const sourceDirectory = dirname(fileURLToPath(import.meta.url));
  // Execute the older owner's actual held-branch source. Only
  // module addresses change, so its dependencies resolve from this checkout.
  const heldSource = execFileSync("git", ["show", `${ROLLBACK_REVISION}:packages/gateway/src/home/home-owner.ts`], {
    cwd: sourceDirectory, encoding: "utf8", timeout: 5_000,
  });
  const addressedSource = heldSource.replace(/from "(\.[^"]+)\.js"/gu, (_match, specifier: string) => `from ${JSON.stringify(resolve(sourceDirectory, `${specifier}.ts`))}`);
  const oldModule = join(root, "held-home-owner.ts");
  await writeFile(oldModule, addressedSource);
  const { HomeOwner: HeldHomeOwner } = await import(/* @vite-ignore */ oldModule) as { HomeOwner: typeof HomeOwner };
  const homeDirectory = join(root, "gateway", "home");
  await mkdir(homeDirectory, { mode: 0o700 });
  const recordPath = join(homeDirectory, "home.json");
  const homeBytes = JSON.stringify({
    version: 2, homeId: "home-1", bindingRevision: 1, generation: 1, routeGeneration: 1, policyRevision: 1, enabled: true,
    model: { provider: "test", id: "test-model" }, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
    chapters: [{ sessionId: "session-1", ordinal: 1, state: "active", activationStarted: true, createdAt: "2026-01-01T00:00:00.000Z" }],
  });
  await writeFile(recordPath, homeBytes, { mode: 0o600 });
  const sessions: HomeSessionPort = {
    createHomeSession: async () => { throw new Error("rollback must not create a session"); },
    applySessionModel: async () => {}, sessionPresent: async () => true, hasLiveRuntime: () => false,
    sessionFile: async () => undefined, serializeSessionMutation: async (_id, commit) => commit(),
    replaceRuntimeForProfile: async (_id, commit) => commit(),
    beginHomePublicationReconciliation: () => {}, retireHomeRuntimes: async () => {},
  };
  const options = { tronHome: root, workspace, sessions, trust: new TrustService(join(root, "agent")), memorySummarizer: () => ({ summarizer: async () => "summary" }) };
  const baseline = new HeldHomeOwner(options);
  owners.push(baseline);
  await baseline.initialize();
  const before = await baseline.status();
  const store = new HomeTaskStore(root, workspace);
  await store.initialize();
  await new HomeTaskAuthorization({ store: store.authorization, resolveTrustedTarget: async target => target }).enableInitialScope("epoch-1");
  const { createHash } = await import("node:crypto");
  const intent = { revision: 1, text: "Inspect a trusted project" };
  await store.put({
    version: 1, taskId: "task-1", revision: 1, homeId: "home-1", generation: 1, routeGeneration: 1,
    intent, intentDigest: createHash("sha256").update(JSON.stringify(intent)).digest("hex"),
    target: "/trusted/project", workerProfile: "home-task-v1", policyRevision: 1, grantRef: null, scopeRef: null,
    lifecycle: "pending", sessionId: null, operationId: null, controllerGeneration: null, stopIntent: null, spend: null, reportRefs: null, terminalEvidence: null, wake: null,
  }, null);
  const directory = join(homeDirectory, "tasks");
  const snapshot = Object.fromEntries(await Promise.all((await readdir(directory)).map(async name => [name, await readFile(join(directory, name), "utf8")])));
  const markerPath = join(root, "gateway", "workspace-state", "home-tasks-initialized.json");
  const marker = await readFile(markerPath, "utf8");
  const rollback = new HeldHomeOwner(options);
  owners.push(rollback);
  await rollback.initialize();
  expect(await rollback.status()).toEqual(before);
  expect(before).toMatchObject({ phase: "unavailable", available: false, enabled: false });
  expect(() => rollback.profileFor("session-1", rollback.homeWorkspacePath())).toThrow(/Home is unavailable/);
  expect(rollback.profileFor("ordinary-1", root)).toBe("unnamed");
  expect(rollback.modelFor("session-1")).toEqual(baseline.modelFor("session-1"));
  expect(await readFile(recordPath)).toEqual(Buffer.from(homeBytes));
  const current = new HomeOwner(options);
  owners.push(current);
  await current.initialize();
  expect(await current.status()).toMatchObject({ available: true, enabled: true, homeId: "home-1", routeGeneration: 1, sessionId: "session-1" });
  expect(current.profileFor("session-1", current.homeWorkspacePath())).toBe("home");
  expect(current.modelFor("session-1")).toEqual({ provider: "test", id: "test-model" });
  expect(await readFile(recordPath)).toEqual(Buffer.from(homeBytes));
  expect(Object.fromEntries(await Promise.all((await readdir(directory)).map(async name => [name, await readFile(join(directory, name), "utf8")])))).toEqual(snapshot);
  expect(await readFile(markerPath, "utf8")).toBe(marker);
});
