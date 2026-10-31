import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterAll, afterEach, expect, it, vi } from "vitest";
import { disposeFixtures, fixture, TASK_VIRTUAL_MODEL_ID } from "../../../test-support/home-task-fixture.js";
import { createTestRegistry, homeOwnerOf } from "../../../test-support/gateway-registry.js";

const evidence: unknown[] = [];
afterEach(async () => { vi.restoreAllMocks(); await disposeFixtures(); });
afterAll(async () => {
  await mkdir("test-results/session-profile", { recursive: true });
  await writeFile("test-results/session-profile/creation-and-append.json", JSON.stringify(evidence, null, 2));
});

type Tools = { availableTools: { name: string }[] };

it("refuses virtual explicit choices for a Home creation-profile runtime without settings services", async () => {
  const base = await fixture();
  // The shared task fixture composes Settings. This boundary explicitly omits
  // that service in a separate real Registry and separate canonical store.
  const registry = await createTestRegistry({
    agentDir: base.agentDir, tronHome: join(base.root, "settings-free"), trust: base.trust,
    machineId: "settings-free-profile", idleRuntimeMs: Infinity, gatewayModelRuntime: base.gateway,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ modelsPath: join(base.agentDir, "models.json"), refreshOnCreate: false });
      runtime.registerNativeProvider(base.faux.provider);
      await runtime.refresh({ allowNetwork: false });
      return runtime;
    },
  });
  const f = { ...base, registry };
  try {
    await registry.initialize();
    const slot = await f.registry.create(f.cwd, "home");
    expect(homeOwnerOf(f.registry).profileFor(slot.id, slot.cwd)).toBe("unnamed");
    const before = slot.snapshot().model;
    await expect(slot.setModel(f.model.provider, TASK_VIRTUAL_MODEL_ID)).rejects.toMatchObject({
      code: "invalid_request", message: "Tron Home requires a fixed physical model; virtual models are not supported",
    });
    expect(slot.snapshot().model).toEqual(before);
    evidence.push({ case: "creation-profile-model-constraint", before, after: slot.snapshot().model });
  } finally {
    await registry.dispose();
    await registry.administrativeWorkRegistry.waitUntilSettled();
  }
});


it("uses an explicit creation profile once, then reconstructs an unrecorded session as ordinary", async () => {
  const f = await fixture();
  const slot = await f.registry.create(f.cwd, "home");
  expect(homeOwnerOf(f.registry).profileFor(slot.id, slot.cwd)).toBe("unnamed");
  const first = await slot.context() as unknown as Tools;
  const firstTools = first.availableTools.map(tool => tool.name);
  expect(firstTools).toContain("delegate");
  expect(firstTools).toEqual(expect.arrayContaining(["read", "write", "edit", "bash", "grep", "find", "ls"]));
  expect(firstTools).not.toContain("read_file");

  await slot.replaceRuntimeForProfile(async () => {});
  expect(homeOwnerOf(f.registry).profileFor(slot.id, slot.cwd)).toBe("unnamed");
  const second = await slot.context() as unknown as Tools;
  const secondTools = second.availableTools.map(tool => tool.name);
  expect(secondTools).toContain("write");
  expect(secondTools).not.toContain("delegate");
  evidence.push({ case: "creation-profile-once", firstTools, secondTools });
});

it("classifies a canonical append from the live record, not its fixed runtime profile", async () => {
  const f = await fixture();
  const slot = await f.registry.create(f.cwd, "home");
  const runtimeTools = (await slot.context() as unknown as Tools).availableTools.map(tool => tool.name);
  expect(runtimeTools).toContain("delegate");
  expect(homeOwnerOf(f.registry).profileFor(slot.id, slot.cwd)).toBe("unnamed");
  slot.sessionManager.appendMessage(fauxAssistantMessage("materialized canonical baseline"));
  const before = await readFile(slot.sessionFile!, "utf8");
  const owner = homeOwnerOf(f.registry);
  const state = owner.chapterStateFor.bind(owner);
  // Fault seam: the real owner never reports an unrecorded id as sealed. This
  // probe detects a fixed Home profile replacing live append classification.
  vi.spyOn(owner, "chapterStateFor").mockImplementation(sessionId => sessionId === slot.id
    ? { ...state(sessionId), sealed: true } : state(sessionId));
  expect(owner.chapterStateFor(slot.id).sealed).toBe(true);
  expect(() => slot.sessionManager.appendCustomEntry("live-profile-boundary", { retained: true })).not.toThrow();
  const after = await readFile(slot.sessionFile!, "utf8");
  const entries = after.trimEnd().split("\n").slice(1).map(line => JSON.parse(line));
  const appended = entries.filter(entry => entry.type === "custom" && entry.customType === "live-profile-boundary");
  expect(after.startsWith(before)).toBe(true);
  expect(appended).toHaveLength(1);
  expect(appended[0].data).toEqual({ retained: true });
  expect(slot.sessionManager.getBranch()).toEqual(entries);
  evidence.push({ case: "live-append-classification", runtimeTools, persistedAppends: appended.length,
    beforeBytes: Buffer.byteLength(before), afterBytes: Buffer.byteLength(after) });
});
