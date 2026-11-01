import fsPromises from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { afterEach, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";

// Gate the real filesystem continuation, not a fake ModelRuntime/store. The
// Registry fixture registers its provider and then awaits offline readiness.
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
      // First read belongs to ModelRuntime.create. The second is the detached
      // registration refresh; hold its real result (normally ENOENT).
      if (ordinal !== 2) return;
      entered.resolve();
      await held.promise;
    };
    return read.then(async value => { await gate(); return value; }, async error => { await gate(); throw error; });
  }) as typeof fsPromises.readFile;
  syncBuiltinESMExports();
  pendingFixture = fixture();
  await Promise.race([entered.promise, pendingFixture.then(() => { throw new Error("Fixture readiness overtook the config-read gate"); })]);
  // Later registration/readiness calls must not even dispatch another config
  // read while the older one can still start credential/model-store work.
  expect(reads).toBe(2);
  held.resolve();
  const ready = await pendingFixture;
  expect((await ready.registry.acquire(ready.home.sessionId)).snapshot().configurationBlocker).toBeNull();
});
