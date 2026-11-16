import fsPromises from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { afterEach, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../../test-support/home-task-fixture.js";

const actualReadFile = fsPromises.readFile;
let releaseRead: (() => void) | undefined;
let pendingFixture: ReturnType<typeof fixture> | undefined;
afterEach(async () => {
  releaseRead?.();
  let ready: Awaited<ReturnType<typeof fixture>> | undefined;
  try {
    ready = await pendingFixture;
  } finally {
    fsPromises.readFile = actualReadFile;
    syncBuiltinESMExports();
    releaseRead = undefined;
    pendingFixture = undefined;
    await disposeFixtures();
  }
  if (ready) await expect(fsPromises.readdir(ready.root)).rejects.toMatchObject({ code: "ENOENT" });
});

it("keeps real Gateway readiness behind an older registration config read before fixture removal", async () => {
  const entered = Promise.withResolvers<void>();
  const held = Promise.withResolvers<void>();
  releaseRead = () => held.resolve();
  let modelPath: string | undefined;
  let reads = 0;
  fsPromises.readFile = ((...args: unknown[]) => {
    const path = String(args[0]);
    if (!modelPath && /\/tron-task-dispatch-[^/]+\/agent\/models\.json$/u.test(path)) modelPath = path;
    const ordinal = path === modelPath ? ++reads : 0;
    const read = Reflect.apply(actualReadFile, fsPromises, args) as Promise<unknown>;
    const gate = async () => {
      if (ordinal !== 2) return;
      entered.resolve();
      await held.promise;
    };
    return read.then(async value => { await gate(); return value; }, async error => { await gate(); throw error; });
  }) as typeof fsPromises.readFile;
  syncBuiltinESMExports();
  pendingFixture = fixture();
  await Promise.race([entered.promise, pendingFixture.then(() => { throw new Error("Fixture readiness overtook the config-read gate"); })]);
  expect(reads).toBe(2);
  held.resolve();
  const ready = await pendingFixture;
  expect((await ready.registry.acquire(ready.home.sessionId)).snapshot().configurationBlocker).toBeNull();
});

it("settles a registration refresh still in flight before the fixture root is removed", async () => {
  const ready = await fixture();
  const entered = Promise.withResolvers<void>();
  const held = Promise.withResolvers<void>();
  const actualRm = fsPromises.rm;
  const inFlight = new Set<Promise<unknown>>();
  const refresh = ready.gateway.refresh;
  let armed = true;
  ready.gateway.refresh = function (this: typeof ready.gateway, ...args: Parameters<typeof refresh>) {
    const gated = armed;
    armed = false;
    if (gated) entered.resolve();
    const running = (gated ? held.promise : Promise.resolve()).then(() => Reflect.apply(refresh, this, args) as ReturnType<typeof refresh>);
    inFlight.add(running);
    void running.finally(() => inFlight.delete(running)).catch(() => {});
    return running;
  };
  const settle = ready.gateway.settleCredentialWrites;
  ready.gateway.settleCredentialWrites = function (this: typeof ready.gateway) {
    const settling = Reflect.apply(settle, this, []) as Promise<void>;
    void Promise.race([settling.then(() => "settled"), new Promise(resolve => setImmediate(() => resolve("waiting")))])
      .then(state => { if (state === "waiting") held.resolve(); });
    return settling;
  };
  let pendingAtRemoval: number | undefined;
  fsPromises.rm = (async (...args: Parameters<typeof actualRm>) => {
    if (String(args[0]) === ready.root) {
      pendingAtRemoval = inFlight.size;
      held.resolve();
    }
    return await actualRm(...args);
  }) as typeof fsPromises.rm;
  syncBuiltinESMExports();
  const registry = ready.registry as unknown as { slots: Map<string, unknown>; retireIdleRuntime(input: unknown): Promise<boolean> };
  for (const [sessionId, slot] of [...registry.slots]) {
    expect(await registry.retireIdleRuntime({ sessionId, slot, reason: "idle", eligible: () => true })).toBe(true);
  }
  expect(registry.slots.size).toBe(0);
  try {
    ready.gateway.registerVirtualModel({ provider: ready.model.provider, id: "late-registration", name: "Late registration",
      route: () => ({ model: ready.model, thinkingLevel: "off" }) });
    await entered.promise;
    await disposeFixtures();
  } finally {
    held.resolve();
    fsPromises.rm = actualRm;
    syncBuiltinESMExports();
  }
  expect(pendingAtRemoval).toBe(0);
});
