import type { AgentSession } from "@earendil-works/pi-coding-agent";

/** How long a tool call may keep running after its turn is cancelled before its result is abandoned. */
export const TOOL_CANCELLATION_GRACE_MS = 2_000;
const BOUNDED = Symbol("tron.boundedToolCancellation");

type AgentToolLike = { name: string; execute: (...args: never[]) => Promise<unknown> };

/**
 * Bounds every tool call's life after cancellation (#961). Pi's agent loop awaits a tool's
 * `execute` and its `abort()` waits for the loop to go idle, so one tool that ignores its abort
 * signal (an extension or MCP call blocked on I/O) made Stop hang forever and left the worker
 * running. After `graceMs` the call resolves as an error result naming the abandoned tool; the
 * loop then ends the cancelled run and Stop settles. Built-in bash kills its process group on
 * abort and normally settles well inside the grace. The abandoned promise is not awaited; its
 * late result and updates are dropped by the loop.
 *
 * Pi assigns the declared tools to `agent.state.tools` whenever it rebuilds the loadout, so the
 * bound wraps each assignment once per session.
 */
export function boundToolCancellation(session: AgentSession, graceMs = TOOL_CANCELLATION_GRACE_MS): void {
  const state = session.agent.state as { tools: AgentToolLike[] } & { [BOUNDED]?: true };
  if (state[BOUNDED]) return;
  const descriptor = Object.getOwnPropertyDescriptor(state, "tools");
  if (!descriptor?.get || !descriptor.set || !descriptor.configurable) {
    throw new Error("Pi agent state no longer exposes a tools accessor; tool cancellation cannot be bounded");
  }
  const get = descriptor.get.bind(state), set = descriptor.set.bind(state);
  const wrapped = new WeakSet<object>();
  const bound = (tool: AgentToolLike): AgentToolLike => {
    if (wrapped.has(tool)) return tool;
    const execute = tool.execute as (id: string, params: unknown, signal?: AbortSignal, ...rest: unknown[]) => Promise<unknown>;
    const next = { ...tool, execute: (id: string, params: unknown, signal?: AbortSignal, ...rest: unknown[]) => {
      const running = execute.call(tool, id, params, signal, ...rest);
      if (!signal) return running;
      return new Promise((resolve, reject) => {
        let timer: NodeJS.Timeout | undefined;
        const abandon = () => {
          timer = setTimeout(() => resolve({ isError: true, details: { abandonedAfterCancellationMs: graceMs },
            content: [{ type: "text", text: `Tool ${tool.name} did not stop within ${graceMs} ms of cancellation; its call was abandoned and any later result is discarded.` }] }), graceMs);
          timer.unref?.();
        };
        if (signal.aborted) abandon();
        else signal.addEventListener("abort", abandon, { once: true });
        running.then(resolve, reject).finally(() => { if (timer) clearTimeout(timer); signal.removeEventListener("abort", abandon); });
      });
    } } as AgentToolLike;
    wrapped.add(next);
    return next;
  };
  Object.defineProperty(state, "tools", { configurable: true, enumerable: descriptor.enumerable ?? true,
    get, set: (tools: AgentToolLike[]) => set(tools.map(bound)) });
  state[BOUNDED] = true;
  set(get().map(bound));
}
