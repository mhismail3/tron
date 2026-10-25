import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { createTestRegistry } from "../../test-support/gateway-registry.js";
import type { RuntimeRegistry } from "../kernel/session/runtime-registry.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import { BrowserLiveViewRegistry } from "./browser-live-view.js";

it.each(["replace", "dispose"] as const)("K1 display retirement revokes only the retiring runtime's exact view and load on %s", async boundary => {
  const root = await mkdtemp(join(tmpdir(), "tron-display-retirement-"));
  const views = new BrowserLiveViewRegistry();
  let registry: RuntimeRegistry | undefined;
  try {
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDir = join(root, "sessions");
    await Promise.all([agentDir, cwd, sessionDir].map(path => mkdir(path, { recursive: true })));
    const faux = fauxProvider({ provider: "tron-display-retirement" });
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({
      sessionDir, defaultProvider: faux.provider, defaultModel: faux.getModel().id,
    }));
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    registry = await createTestRegistry({
      trust, agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, browserLiveViews: views,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    const target = await registry.create(cwd);
    const unrelated = await registry.create(cwd);
    const admit = (sessionId: string) => {
      const loadToken = views.beginSessionLoad(sessionId);
      const registration = { sessionId, loadToken, viewId: "current-view", generation: "current-generation",
        cdpUrl: "ws://127.0.0.1:43127/devtools/browser/12345678-1234-1234-1234-123456789abc",
        title: "Lifecycle view", fallbackText: "Unavailable" };
      return { registration, descriptor: views.register(registration) };
    };
    const retiring = admit(target.id);
    const retained = admit(unrelated.id);
    // Establish admission before retirement so a denied or pre-retired fixture cannot pass.
    for (const { registration: ref, descriptor } of [retiring, retained]) {
      expect(views.isLoadActive(ref.sessionId, ref.loadToken)).toBe(true);
      expect(views.describe(ref.sessionId, ref.viewId, ref.generation)).toEqual(descriptor);
    }
    if (boundary === "replace") {
      expect(await target.runtime.newSession()).toEqual({ cancelled: false });
      expect(target.runtime.session.sessionId).not.toBe(retiring.registration.sessionId);
    } else {
      await target.dispose();
    }
    const old = retiring.registration;
    expect(views.isLoadActive(old.sessionId, old.loadToken)).toBe(false);
    expect(() => views.describe(old.sessionId, old.viewId, old.generation)).toThrow();
    expect(() => views.register(old)).toThrow();
    const other = retained.registration;
    expect(views.isLoadActive(other.sessionId, other.loadToken)).toBe(true);
    expect(views.describe(other.sessionId, other.viewId, other.generation)).toEqual(retained.descriptor);
    const evidence = join(process.cwd(), "test-results", "display-runtime-retirement");
    await mkdir(evidence, { recursive: true });
    await writeFile(join(evidence, `${boundary}.json`), JSON.stringify({
      boundary, revoked: retiring.descriptor, retained: retained.descriptor,
      oldLoadActive: views.isLoadActive(old.sessionId, old.loadToken), unrelatedLoadActive: views.isLoadActive(other.sessionId, other.loadToken),
    }, null, 2));
  } finally {
    try { await registry?.dispose(); } finally {
      views.dispose();
      await rm(root, { recursive: true, force: true });
    }
  }
});
