import { Type, type TSchema } from "@earendil-works/pi-ai";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import { EPISODIC_CAP_CHARS, EPISODIC_CAP_TAIL_CHARS, EPISODIC_SEARCH_QUERY_CHARS } from "../episodic/episodic-contract.js";
import { capText } from "../episodic/episodic-tree.js";
import {
  homeMemoryToolUnavailable,
  type HomeMemoryToolAccess,
  type HomeMemoryToolResult,
  type HomeMemoryUnavailableReason,
} from "./home-memory.js";

/*
 * Home's three memory tools (gist §7.1, and `memory_search` as Tron's addition in
 * docs/home.md). They are the ONLY way Home opens a line of the view back up:
 * `zoom` walks the tree down to a message, `date` gives a message's time, and
 * `memory_search` finds a message by text.
 *
 * The tool definitions are constant: no timestamp, no session state, no view
 * text. The system prompt and the tool list are the head of every cached prefix,
 * so two activations must send them byte-identically (gist §7.2, §8).
 *
 * The accessor is resolved at every call, never captured: the memory behind a
 * running Home can be reconfigured, blocked or released, and a session that is
 * not the enabled Home has no memory at all. Each of those answers with a typed
 * unavailable result instead of an empty success.
 */

/** The tool names the tron-home extension registers live in `tron-modules.ts`
 * (`TRON_HOME_MODULE.tools`), which must match this factory, and in the
 * executable allowlist `HOME_TOOL_NAMES` that `home-designation.integration.test.ts`
 * asserts. */

/**
 * The zoom arguments are plain numbers on purpose: every invalid address — a
 * fractional, negative or zero `id`/`n`, not only the ones a bound could express —
 * must reach the memory and answer `No line id+n.`, instead of failing schema
 * validation where the model can only see a validation error.
 */
const ZOOM_PARAMETERS = Type.Object({
  id: Type.Number({ description: "The first message id of the line, the id in the view's `id+n`." }),
  n: Type.Number({ description: "How many messages the line covers, the n in the view's `id+n`." }),
}, { additionalProperties: false });

const DATE_PARAMETERS = Type.Object({
  id: Type.Integer({ minimum: 0, description: "The message id, the id in the view line `id+1`." }),
}, { additionalProperties: false });

const SEARCH_PARAMETERS = Type.Object({
  query: Type.String({
    description: `The substring to find, matched case-insensitively, 1 to ${EPISODIC_SEARCH_QUERY_CHARS} characters.`,
  }),
  from: Type.Optional(Type.Integer({ minimum: 0, description: "First message id to search, inclusive. Default: the first message." })),
  to: Type.Optional(Type.Integer({ minimum: 0, description: "Message id to stop before, exclusive. Default: the end of the memory." })),
}, { additionalProperties: false });

/** The bound on one tool result's text: the recipe's `CAP`, the same head-and-tail
 * truncation the projection applies to a logged tool result. */
const RESULT_CHARS = EPISODIC_CAP_CHARS;
const RESULT_TAIL_CHARS = EPISODIC_CAP_TAIL_CHARS;

/** Tool-result details: small, typed and durable in the transcript, so a reader
 * can tell an answer from a refusal without parsing the text. */
export type HomeMemoryToolDetails =
  | { status: "ok" }
  | { status: "invalid-arguments" }
  | { status: "unavailable"; reason: HomeMemoryUnavailableReason };

/**
 * The three tool definitions, closed over the accessor that resolves the memory
 * for the session they run in. `undefined` from the accessor is the session that
 * is not the enabled Home.
 */
export function homeMemoryTools(memoryTools: () => HomeMemoryToolAccess | undefined): Array<ToolDefinition<TSchema, HomeMemoryToolDetails>> {
  const answer = (result: HomeMemoryToolResult) => ({
    content: [{ type: "text" as const, text: bounded(result.text) }],
    details: result.outcome === "unavailable" ? { status: "unavailable" as const, reason: result.reason } : { status: result.outcome },
  });
  const missing = () => answer(homeMemoryToolUnavailable("not-home-session"));

  return [
    {
      name: "zoom",
      label: "Zoom",
      description: "Open the line id+n of the view into the two lines of n/2 under it; n = 1 gives the message whole.",
      parameters: ZOOM_PARAMETERS,
      executionMode: "sequential",
      execute: async (_toolCallId, request: { id: number; n: number }) => {
        const memory = memoryTools();
        return memory ? answer(await memory.zoom(request.id, request.n)) : missing();
      },
    },
    {
      name: "date",
      label: "Date",
      description: "The date and time of message id.",
      parameters: DATE_PARAMETERS,
      executionMode: "sequential",
      execute: async (_toolCallId, request: { id: number }) => {
        const memory = memoryTools();
        return memory ? answer(await memory.date(request.id)) : missing();
      },
    },
    {
      name: "memory_search",
      label: "Memory search",
      description: "Find messages of this chat by case-insensitive substring, oldest first, at most 20 lines; each line is `id+0|kind: snippet`, and the header counts the range's matches, its [omitted] messages and its capped ones. Tron's addition to the view's tools.",
      parameters: SEARCH_PARAMETERS,
      executionMode: "sequential",
      execute: async (_toolCallId, request: { query: string; from?: number; to?: number }) => {
        const memory = memoryTools();
        return memory ? answer(await memory.search(request.query, request.from, request.to)) : missing();
      },
    },
  ];
}

/** One result's text, capped the way a logged tool result is: head and tail kept
 * with a marker naming what was removed, so a 128 KiB message cannot enter the
 * transcript whole. */
function bounded(text: string): string {
  return capText(text, RESULT_CHARS, RESULT_TAIL_CHARS).text;
}
