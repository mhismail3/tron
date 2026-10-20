import type { Agent, StreamFn } from "./agent-core.js";
import { initTheme as initPiTheme, type AgentSessionRuntime, type FileEntry, type ModelRuntime, type SessionManager } from "./coding-agent.js";

// The Pi internals the Gateway adapts (K-0 §4), one named adapter each. An adapter owns
// only the Pi side (which member, private or public, and in which order); the Gateway's
// behavior stays in the closures its owner passes.

const canonicalAppendOwner = Symbol("canonical-append-owner");

/**
 * Routes every canonical append of `sessionManager` through `around`, by replacing Pi's
 * private `SessionManager._appendEntry`. `around` must call `append` to write. The guard
 * belongs to the manager, not to a runtime rebuild, and its immutable owner rejects sharing
 * one writer across owners: `false` means another owner already guards it; a repeat install
 * by the same owner is a no-op.
 */
export function guardCanonicalAppend(sessionManager: SessionManager, owner: object, around: (append: () => void) => void): boolean {
  const manager = sessionManager as unknown as {
    _appendEntry: ((entry: FileEntry) => void) & { [canonicalAppendOwner]?: object };
  };
  const current = manager._appendEntry[canonicalAppendOwner];
  if (current === owner) return true;
  if (current) return false;
  const appendEntry = manager._appendEntry.bind(manager);
  const guardedAppend = (entry: FileEntry) => around(() => appendEntry(entry));
  Object.defineProperty(guardedAppend, canonicalAppendOwner, { value: owner });
  manager._appendEntry = guardedAppend;
  return true;
}

/** Replaces `ModelRuntime.streamSimple` (the final provider cut, after the SDK merges its
 * own option defaults) with `wrap` of the runtime's bound original. */
export function wrapModelRuntimeStream(
  runtime: ModelRuntime,
  wrap: (streamSimple: ModelRuntime["streamSimple"]) => ModelRuntime["streamSimple"],
): void {
  const streamSimple = runtime.streamSimple.bind(runtime);
  runtime.streamSimple = wrap(streamSimple);
}

/** The stages the Gateway installs on a Pi `Agent`'s request pipeline. */
export interface AgentPipelineStages {
  /** Wraps Pi's message conversion. */
  convertToLlm(inner: Agent["convertToLlm"]): Agent["convertToLlm"];
  /** Wraps Pi's request preparation. */
  prepareRequest(inner: Agent["prepareRequest"]): NonNullable<Agent["prepareRequest"]>;
  /** The provider-facing stream chain over Pi's provider stream, captured before any stage. */
  streamFunction(provider: StreamFn): StreamFn;
  /** Outermost context and request stages, installed after every other stage. */
  outer?: {
    transformContext(inner: Agent["transformContext"], convertToLlm: Agent["convertToLlm"]): NonNullable<Agent["transformContext"]>;
    prepareRequest(inner: Agent["prepareRequest"]): NonNullable<Agent["prepareRequest"]>;
  };
  /** Wraps Pi's turn-boundary decision. */
  finishTurn?(inner: Agent["finishTurn"]): NonNullable<Agent["finishTurn"]>;
}

/**
 * Installs `stages` on `agent` in the one order the Gateway's request pipeline depends on:
 * Pi's provider stream is captured first; then message conversion, request preparation and
 * the stream chain (so a stream-side guard is innermost); then the outer context
 * transform (over the installed conversion) and the outermost preparation; then the turn
 * boundary.
 */
export function installAgentPipeline(agent: Agent, stages: AgentPipelineStages): void {
  const provider = agent.streamFunction;
  agent.convertToLlm = stages.convertToLlm(agent.convertToLlm);
  agent.prepareRequest = stages.prepareRequest(agent.prepareRequest);
  agent.streamFunction = stages.streamFunction(provider);
  if (stages.outer) {
    agent.transformContext = stages.outer.transformContext(agent.transformContext, agent.convertToLlm);
    agent.prepareRequest = stages.outer.prepareRequest(agent.prepareRequest);
  }
  if (stages.finishTurn) agent.finishTurn = stages.finishTurn(agent.finishTurn);
}

/** Binds a runtime's session-replacement hooks: `beforeInvalidate` runs when Pi commits a
 * replacement while the old session is still bound; `rebind` runs for the new session. */
export function bindRuntimeSession(runtime: AgentSessionRuntime, hooks: {
  beforeInvalidate: () => void;
  rebind: () => Promise<void>;
}): void {
  runtime.setBeforeSessionInvalidate(hooks.beforeInvalidate);
  runtime.setRebindSession(hooks.rebind);
}

/**
 * Pins Pi's process-global theme. Pi exposes `Theme` and `initTheme` at its package root,
 * but not its mutable global theme singleton. The former RPC default was Pi's dark theme;
 * explicitly pin process-global markdown helpers to it instead of the terminal-dependent
 * system default. Session callbacks continue to receive the host-owned baseline. The
 * composition (`startGatewayModules`) calls it before anything can load an extension.
 */
export function initTheme(): void {
  initPiTheme("dark", false);
}
