import type { Agent, StreamFn } from "./agent-core.js";
import { initTheme as initPiTheme, type AgentSessionRuntime, type FileEntry, type ModelRuntime, type SessionManager } from "./coding-agent.js";

const canonicalAppendOwner = Symbol("canonical-append-owner");

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

export function wrapModelRuntimeStream(
  runtime: ModelRuntime,
  wrap: (streamSimple: ModelRuntime["streamSimple"]) => ModelRuntime["streamSimple"],
): void {
  const streamSimple = runtime.streamSimple.bind(runtime);
  runtime.streamSimple = wrap(streamSimple);
}

export interface AgentPipelineStages {
  convertToLlm(inner: Agent["convertToLlm"]): Agent["convertToLlm"];
  prepareRequest(inner: Agent["prepareRequest"]): NonNullable<Agent["prepareRequest"]>;
  streamFunction(provider: StreamFn): StreamFn;
  outer?: {
    transformContext(inner: Agent["transformContext"], convertToLlm: Agent["convertToLlm"]): NonNullable<Agent["transformContext"]>;
    prepareRequest(inner: Agent["prepareRequest"]): NonNullable<Agent["prepareRequest"]>;
  };
  finishTurn?(inner: Agent["finishTurn"]): NonNullable<Agent["finishTurn"]>;
}

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

export function bindRuntimeSession(runtime: AgentSessionRuntime, hooks: {
  beforeInvalidate: () => void;
  rebind: () => Promise<void>;
}): void {
  runtime.setBeforeSessionInvalidate(hooks.beforeInvalidate);
  runtime.setRebindSession(hooks.rebind);
}

export function initTheme(): void {
  initPiTheme("dark", false);
}
