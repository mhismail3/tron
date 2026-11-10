import type { AgentSession } from "../pi/coding-agent.js";

const TOOL_CANCELLATION_GRACE_MS = 2_000;
export const TOOL_INTERRUPT_SIGNAL_GRACE_MS = 5_000;
const TOOL_INTERRUPT_ABANDON_MS = 3 * TOOL_INTERRUPT_SIGNAL_GRACE_MS;
const BOUNDED = Symbol("tron.boundedToolCancellation");

type AgentToolLike = { name: string; execute: (...args: never[]) => Promise<unknown> };
type InFlightCall = { readonly name: string; readonly controller: AbortController };

export class ToolCallInterrupt extends Error {
  constructor(readonly by: string) {
    super(`interrupted by ${by}`);
    this.name = "ToolCallInterrupt";
  }
}

const interruptedText = (interrupt: ToolCallInterrupt, name: string, output: string) =>
  `Interrupted by ${interrupt.by}: this ${name} call was cancelled before it finished${name === "bash" ? ", and its command was stopped with its child processes" : ""}. `
  + "Your session, worktree, branch and commits are unchanged; a following message may say what to do instead."
  + (output.trim() ? `\n\nOutput before the interrupt:\n${output}` : "");

const resultText = (value: unknown): string => {
  const content = (value as { content?: Array<{ type?: string; text?: string }> } | undefined)?.content;
  return Array.isArray(content) ? content.map(part => part.type === "text" ? part.text ?? "" : "").join("") : "";
};

export function boundToolCancellation(session: AgentSession, graceMs = TOOL_CANCELLATION_GRACE_MS): void {
  const state = session.agent.state as { tools: AgentToolLike[] } & { [BOUNDED]?: Set<InFlightCall> };
  if (state[BOUNDED]) return;
  const descriptor = Object.getOwnPropertyDescriptor(state, "tools");
  if (!descriptor?.get || !descriptor.set || !descriptor.configurable) {
    throw new Error("Pi agent state no longer exposes a tools accessor; tool cancellation cannot be bounded");
  }
  const get = descriptor.get.bind(state), set = descriptor.set.bind(state);
  const inFlight = new Set<InFlightCall>();
  const wrapped = new WeakSet<object>();
  const bound = (tool: AgentToolLike): AgentToolLike => {
    if (wrapped.has(tool)) return tool;
    const execute = tool.execute as (id: string, params: unknown, signal?: AbortSignal, ...rest: unknown[]) => Promise<unknown>;
    const next = { ...tool, execute: (id: string, params: unknown, signal?: AbortSignal, ...rest: unknown[]) => {
      const controller = new AbortController();
      const follow = () => controller.abort(signal!.reason);
      if (signal?.aborted) follow();
      else signal?.addEventListener("abort", follow, { once: true });
      const call: InFlightCall = { name: tool.name, controller };
      inFlight.add(call);
      const interrupt = () => controller.signal.reason instanceof ToolCallInterrupt ? controller.signal.reason : undefined;
      return new Promise((resolve, reject) => {
        let timer: NodeJS.Timeout | undefined;
        const settle = () => {
          if (timer) clearTimeout(timer);
          controller.signal.removeEventListener("abort", abandon);
          signal?.removeEventListener("abort", follow);
          signal?.removeEventListener("abort", stopAfterInterrupt);
          inFlight.delete(call);
        };
        const abandon = () => {
          if (timer) clearTimeout(timer);
          const interrupted = signal?.aborted ? undefined : interrupt();
          const ms = interrupted ? TOOL_INTERRUPT_ABANDON_MS : graceMs;
          timer = setTimeout(() => {
            settle();
            resolve({ isError: true, details: { abandonedAfterCancellationMs: ms },
              content: [{ type: "text", text: `${interrupted ? `${interruptedText(interrupted, tool.name, "")}\n\n` : ""}Tool ${tool.name} did not stop within ${ms} ms of cancellation; its call was abandoned and any later result is discarded.` }] });
          }, ms);
          timer.unref?.();
        };
        const stopAfterInterrupt = () => { if (interrupt()) abandon(); };
        signal?.addEventListener("abort", stopAfterInterrupt, { once: true });
        if (controller.signal.aborted) abandon();
        else controller.signal.addEventListener("abort", abandon, { once: true });
        let running: Promise<unknown>;
        try { running = Promise.resolve(execute.call(tool, id, params, controller.signal, ...rest)); }
        catch (error) { running = Promise.reject(error); }
        running.then(
          value => { const interrupted = interrupt(); if (interrupted) reject(new Error(interruptedText(interrupted, tool.name, resultText(value)))); else resolve(value); },
          error => { const interrupted = interrupt(); reject(interrupted ? new Error(interruptedText(interrupted, tool.name, error instanceof Error ? error.message : String(error))) : error); },
        ).finally(settle);
      });
    } } as AgentToolLike;
    wrapped.add(next);
    return next;
  };
  Object.defineProperty(state, "tools", { configurable: true, enumerable: descriptor.enumerable ?? true,
    get, set: (tools: AgentToolLike[]) => set(tools.map(bound)) });
  state[BOUNDED] = inFlight;
  set(get().map(bound));
}

export async function interruptToolCalls(session: AgentSession, interrupt: ToolCallInterrupt, before?: () => Promise<void>): Promise<string[]> {
  const targets = [...(session.agent.state as { [BOUNDED]?: Set<InFlightCall> })[BOUNDED] ?? []];
  if (before) await before();
  const inFlight = (session.agent.state as { [BOUNDED]?: Set<InFlightCall> })[BOUNDED];
  const interrupted: string[] = [];
  for (const call of targets) {
    if (!inFlight?.has(call) || call.controller.signal.aborted) continue;
    call.controller.abort(interrupt);
    interrupted.push(call.name);
  }
  return interrupted;
}
