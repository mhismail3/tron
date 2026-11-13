import { Type, type TSchema } from "../../kernel/pi/ai.js";
import type { ToolDefinition } from "../../kernel/pi/coding-agent.js";
import { EPISODIC_CAP_CHARS, EPISODIC_CAP_TAIL_CHARS, EPISODIC_SEARCH_QUERY_CHARS } from "../../episodic/episodic-contract.js";
import { capText } from "../../episodic/episodic-tree.js";
import {
  homeMemoryToolUnavailable,
  type HomeMemoryToolAccess,
  type HomeMemoryToolFacts,
  type HomeMemoryToolResult,
  type HomeMemoryUnavailableReason,
} from "./home-memory.js";

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

const RESULT_CHARS = EPISODIC_CAP_CHARS;
const RESULT_TAIL_CHARS = EPISODIC_CAP_TAIL_CHARS;

export type HomeMemoryToolDetails =
  | ({ status: "ok" } & HomeMemoryToolFacts)
  | { status: "invalid-arguments" }
  | { status: "unavailable"; reason: HomeMemoryUnavailableReason };

export function homeMemoryTools(memoryTools: () => HomeMemoryToolAccess | undefined): Array<ToolDefinition<TSchema, HomeMemoryToolDetails>> {
  const answer = (result: HomeMemoryToolResult) => ({
    content: [{ type: "text" as const, text: bounded(result.text) }],
    details: result.outcome === "unavailable" ? { status: "unavailable" as const, reason: result.reason }
      : result.outcome === "ok" ? { status: "ok" as const, ...result.facts } : { status: result.outcome },
  });
  const missing = () => answer(homeMemoryToolUnavailable("not-home-session"));

  return [
    {
      name: "zoom",
      annotations: { openWorldHint: false },
      label: "Zoom",
      description: "Open the line id+n of the view into the two lines of n/2 under it; n = 1 gives the message whole. Nothing before this turn is replayed in full: zoom the lines you need. Say in your reply whatever you learned that will matter later: summaries keep little of tool output.",
      parameters: ZOOM_PARAMETERS,
      executionMode: "sequential",
      execute: async (_toolCallId, request: { id: number; n: number }, signal) => {
        const memory = memoryTools();
        return memory ? answer(await memory.zoom(request.id, request.n, signal)) : missing();
      },
    },
    {
      name: "date",
      annotations: { openWorldHint: false },
      label: "Date",
      description: "The date and time of message id.",
      parameters: DATE_PARAMETERS,
      executionMode: "sequential",
      execute: async (_toolCallId, request: { id: number }, signal) => {
        const memory = memoryTools();
        return memory ? answer(await memory.date(request.id, signal)) : missing();
      },
    },
    {
      name: "memory_search",
      annotations: { openWorldHint: false },
      label: "Memory search",
      description: "Find messages of this chat by case-insensitive substring, oldest first, at most 20 lines; each line is `id+0|kind: snippet`, and the header counts the range's matches, its [omitted] messages and its capped ones. Tron's addition to the view's tools.",
      parameters: SEARCH_PARAMETERS,
      executionMode: "sequential",
      execute: async (_toolCallId, request: { query: string; from?: number; to?: number }, signal) => {
        const memory = memoryTools();
        return memory ? answer(await memory.search(request.query, request.from, request.to, signal)) : missing();
      },
    },
  ];
}

function bounded(text: string): string {
  return capText(text, RESULT_CHARS, RESULT_TAIL_CHARS).text;
}
