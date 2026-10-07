import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type AgentSession } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, type AssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { SettingsService } from "../admin/settings-service.js";
import { TrustService } from "../admin/trust-service.js";
import type { GatewayConfig } from "../config.js";
import type { EpisodicSummarizer } from "../episodic/episodic-contract.js";
import type { HomeStatus } from "../protocol/types.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { waitFor } from "../../test-support/wait-for.js";
import { RuntimeRegistry } from "./runtime-registry.js";

// #480 A1-A4, found live: Home's chat reached Pi's built-in Anthropic provider
// instead of the user's CortexKit package. A user package registers its provider
// into the Gateway-wide runtime (GlobalProviderResources); here a faux provider
// registered only there stands in for it, and every per-session runtime the
// registry builds lacks it, as a session that loads no packages would.

const PACKAGE = { provider: "user-package", id: "chat" };
const BUILTIN = { provider: "builtin", id: "chat" };
const client = { id: "terminal", identity: "device:home-provider", isLocal: false, unsubscribe: () => {} } as unknown as ClientContext;
const zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const summarizer: EpisodicSummarizer = async () => ({ role: "assistant", content: [{ type: "text", text: "user: summarized" }],
  api: "faux", provider: "faux", model: "summarizer", usage: zero, stopReason: "stop", timestamp: Date.now() }) as AssistantMessage;

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });

async function fixture(options: { shareGatewayRuntime: boolean }) {
  const root = await mkdtemp(join(tmpdir(), "tron-home-provider-"));
  cleanups.push(async () => { await rm(root, { recursive: true, force: true }); });
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: BUILTIN.provider, defaultModel: BUILTIN.id }));
  const packaged = fauxProvider({ provider: PACKAGE.provider, models: [{ id: PACKAGE.id, reasoning: false }] });
  const builtinProvider = () => fauxProvider({ provider: BUILTIN.provider, models: [{ id: BUILTIN.id, reasoning: false }] });
  const builtins: Array<ReturnType<typeof builtinProvider>> = [];
  const create = async () => {
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const builtin = builtinProvider();
    builtin.setResponses(Array.from({ length: 4 }, () => fauxAssistantMessage("ordinary reply")));
    builtins.push(builtin);
    runtime.registerNativeProvider(builtin.provider);
    return runtime;
  };
  // The Gateway-wide runtime: built-ins plus the user's package provider.
  const gateway = await create();
  gateway.registerNativeProvider(packaged.provider);
  const registry = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000,
    modelRuntimeFactory: create,
    ...(options.shareGatewayRuntime ? { gatewayModelRuntime: gateway } : {}),
    trust: new TrustService(agentDir),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    homeMemorySummarizer: () => ({ summarizer }),
  });
  cleanups.push(async () => { await registry.dispose(); });
  const service = new GatewayService({
    config: { tronHome } as unknown as GatewayConfig, modelRuntime: gateway, sessions: registry, home: registry.homeOwner(),
    receipts: new CommandReceiptStore(join(tronHome, "receipts")), settings: new SettingsService(agentDir, gateway),
    trust: new TrustService(agentDir), sessionDeleted: () => {}, uploads: { removeSession: async () => {} },
  } as unknown as GatewayServiceDependencies);
  await registry.initialize();
  return { root, gateway, packaged, registry, service };
}

const sessionOf = (slot: unknown) => (slot as { runtime: { session: AgentSession } }).runtime.session;

function lastAssistant(session: AgentSession): AssistantMessage | undefined {
  return session.messages.filter((message): message is AssistantMessage => message.role === "assistant").at(-1);
}

async function homeTurn(f: Awaited<ReturnType<typeof fixture>>, text: string): Promise<AssistantMessage | undefined> {
  const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
  const home = await f.registry.acquire(status.sessionId!);
  await home.prompt(text);
  await waitFor(() => !home.isBusy, `the Home turn "${text}"`);
  return lastAssistant(sessionOf(home));
}

describe.sequential("Home's chat runtime", () => {
  // A1, A2, A3.
  it("reaches a provider only the Gateway-wide runtime has, through every Home lifecycle step", async () => {
    const f = await fixture({ shareGatewayRuntime: true });
    f.packaged.setResponses(Array.from({ length: 3 }, (_unused, index) => fauxAssistantMessage(`package reply ${index}`)));
    await f.service.invoke(client, "home.designate", { commandId: "provider-designate", model: PACKAGE });
    await f.service.invoke(client, "home.configureMemory", { commandId: "provider-memory", model: PACKAGE });
    const first = await homeTurn(f, "first");
    expect(first?.stopReason).toBe("stop");
    expect(first?.provider).toBe(PACKAGE.provider);

    // Disable and re-enable replace Home's runtime in place; the shared runtime stays usable.
    await f.service.invoke(client, "home.disable", { commandId: "provider-disable" });
    await f.service.invoke(client, "home.designate", { commandId: "provider-redesignate", model: PACKAGE });
    const second = await homeTurn(f, "second");
    expect(second?.stopReason).toBe("stop");
    expect(f.gateway.getModel(PACKAGE.provider, PACKAGE.id)).toBeDefined();

    // An ordinary session keeps a runtime of its own.
    const ordinary = await f.registry.create(f.root);
    expect(sessionOf(ordinary).modelRuntime).not.toBe(f.gateway);
    expect(sessionOf(ordinary).modelRuntime.getModel(PACKAGE.provider, PACKAGE.id)).toBeUndefined();
  });

  // A5 (review): Home's session-local context-window override must stay session-local.
  // SessionContextWindowPolicy replaces `getModel` on the runtime it is given, so a
  // shared runtime would leak the override into Gateway-wide lookups and stack each
  // replaced runtime's lookup under the next.
  it("keeps a Home context-window override out of the shared runtime, across runtime replacement", async () => {
    const f = await fixture({ shareGatewayRuntime: true });
    const catalogWindow = f.gateway.getModel(PACKAGE.provider, PACKAGE.id)!.contextWindow;
    await f.service.invoke(client, "home.designate", { commandId: "window-designate", model: PACKAGE });
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    const before = home.snapshot();
    await home.setContextWindow(PACKAGE.provider, PACKAGE.id, 60_000, before.revision, before.runtimeGeneration);
    expect(sessionOf(home).model?.contextWindow).toBe(60_000);
    expect(f.gateway.getModel(PACKAGE.provider, PACKAGE.id)!.contextWindow).toBe(catalogWindow);

    await f.service.invoke(client, "home.disable", { commandId: "window-disable" });
    await f.service.invoke(client, "home.designate", { commandId: "window-redesignate", model: PACKAGE });
    const replaced = await f.registry.acquire(status.sessionId!);
    expect(sessionOf(replaced).model?.contextWindow).toBe(60_000);
    const current = replaced.snapshot();
    await replaced.setContextWindow(PACKAGE.provider, PACKAGE.id, null, current.revision, current.runtimeGeneration);
    expect(sessionOf(replaced).model?.contextWindow).toBe(catalogWindow);
    expect(f.gateway.getModel(PACKAGE.provider, PACKAGE.id)!.contextWindow).toBe(catalogWindow);
  });

  // A1's negative control: the same Home on a runtime without the package provider cannot reach it.
  it("cannot reach that provider from a runtime the package never registered in", async () => {
    const f = await fixture({ shareGatewayRuntime: false });
    f.packaged.setResponses([fauxAssistantMessage("never sent")]);
    const outcome = await f.service.invoke(client, "home.designate", { commandId: "isolated-designate", model: PACKAGE })
      .then(async () => {
        await f.service.invoke(client, "home.configureMemory", { commandId: "isolated-memory", model: PACKAGE });
        return await homeTurn(f, "first");
      })
      .catch((error: Error) => error);
    if (outcome instanceof Error) expect(outcome.message).toMatch(/not registered|not found|model/iu);
    else expect(outcome?.provider).not.toBe(PACKAGE.provider);
  });
});
