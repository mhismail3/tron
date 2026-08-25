import { describe, expect, it } from "vitest";
import { ExtensionLifecycleCoordinator } from "./extension-lifecycle-coordinator.js";
import { SemanticUIBroker } from "./semantic-ui-broker.js";
import { ExtensionPresentationStore } from "../extensions/host/extension-presentation-store.js";

function broker(): SemanticUIBroker { return new SemanticUIBroker(new ExtensionPresentationStore(() => {})); }

describe("ExtensionLifecycleCoordinator", () => {
  it("tracks command, presentation, and shutdown control state", async () => {
    const semantic = broker();
    const lifecycle = new ExtensionLifecycleCoordinator(semantic.presentation);
    let resolve!: () => void;
    const command = lifecycle.trackCommand(new Promise<void>((done) => { resolve = done; }), () => {});
    expect(lifecycle.hasPendingCommands).toBe(true);
    semantic.context().setStatus("work", "pending");
    expect(lifecycle.hasRetainedPresentation).toBe(true);
    lifecycle.requestShutdown();
    expect(lifecycle.preventsOperationalQuiescence).toBe(true);
    resolve();
    await command;
    expect(lifecycle.hasPendingCommands).toBe(false);
    lifecycle.retire();
    expect(lifecycle.isShutdownRequested).toBe(false);
  });

  it("counts generic component/focus/render activity and freezes starts after drain cutoff", () => {
    const semantic = broker();
    const lifecycle = new ExtensionLifecycleCoordinator(semantic.presentation);
    semantic.context().setStatus("ready", "Ready");
    expect(lifecycle.preventsOperationalQuiescence).toBe(false);
    expect(lifecycle.preventsEviction).toBe(true);
    semantic.presentation.setPendingComponentFactories(1);
    semantic.presentation.setScheduledRenders(1);
    expect(lifecycle.preventsOperationalQuiescence).toBe(true);
    semantic.presentation.setPendingComponentFactories(0);
    semantic.presentation.setScheduledRenders(0);

    lifecycle.beginPreflight("accepted-owner");
    lifecycle.resolvePreflight("accepted-owner", true);
    lifecycle.beginPreflight("pending-owner");
    lifecycle.beginPreflight("rejected-owner");
    lifecycle.resolvePreflight("rejected-owner", false);
    lifecycle.beginDrain();
    expect(lifecycle.admitAgentStartDuringDrain("unrelated-owner")).toBe(false);
    expect(lifecycle.admitAgentStartDuringDrain("rejected-owner")).toBe(false);
    expect(lifecycle.admitAgentStartDuringDrain("pending-owner")).toBe(true);
    expect(lifecycle.admitAgentStartDuringDrain("pending-owner")).toBe(false);
    expect(lifecycle.admitAgentStartDuringDrain("accepted-owner")).toBe(true);
    expect(lifecycle.admitAgentStartDuringDrain("accepted-owner")).toBe(false);
  });

  it("does not grant a second permit when agent_start precedes the acceptance callback", () => {
    const lifecycle = new ExtensionLifecycleCoordinator(broker().presentation);
    lifecycle.beginPreflight("owner");
    expect(lifecycle.admitAgentStartDuringDrain("owner")).toBe(true);
    lifecycle.resolvePreflight("owner", true);
    lifecycle.beginDrain();
    expect(lifecycle.admitAgentStartDuringDrain("owner")).toBe(false);
  });
});
