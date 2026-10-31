import { Type, StringEnum } from "../../kernel/pi/ai.js";
import type { SessionEntry, ToolDefinition } from "../../kernel/pi/coding-agent.js";
import { GatewayError } from "../../errors.js";

/** Canonical Home entries are the ledger. Summaries and Profile never write it. */
export const HOME_OBLIGATION = "tron.home-obligation.v1";
const ACTIONS = ["list", "request", "reported-done", "verified", "reopened"] as const;
type State = Exclude<typeof ACTIONS[number], "list">;
export interface ObligationSource { sessionId: string; entryId: string; quote: string }
export interface ObligationEvent {
  receiptId: string;
  id: string;
  action: State;
  source: ObligationSource;
  evidence?: ObligationSource;
  text?: string;
  issue?: string;
}
export interface ObligationItem {
  id: string;
  text: string;
  issue?: string;
  state: State;
  request: ObligationSource;
  latest: ObligationEvent;
}
export interface ObligationRequest {
  action: typeof ACTIONS[number];
  id?: string;
  text?: string;
  issue?: string;
  quote?: string;
  evidenceEntryId?: string;
  evidenceQuote?: string;
}
const refuse = (message: string): never => { throw new GatewayError("invalid_request", `obligation: ${message}`); };

/** Fail closed on corrupt/contradictory events, never turn an unreadable ledger into empty. */
export function replayObligations(entries: readonly SessionEntry[], sessionId: string, items = new Map<string, ObligationItem>()): Map<string, ObligationItem> {
  const prior = new Map<string, SessionEntry>();
  for (const entry of entries) {
    if (entry.type === "message") prior.set(entry.id, entry);
    if (entry.type !== "custom" || entry.customType !== HOME_OBLIGATION) continue;
    const event = entry.data as ObligationEvent;
    if (!event || !event.receiptId || !event.id || !event.source?.entryId || !event.source.sessionId || !event.source.quote
      || !ACTIONS.includes(event.action) || event.action === ("list" as string)) refuse("canonical event is invalid");
    if (event.source.sessionId !== sessionId || (event.evidence && event.evidence.sessionId !== sessionId)) refuse("event source names a different chapter");
    admitObligation({ action: event.action, id: event.id, quote: event.source.quote, ...(event.text === undefined ? {} : { text: event.text }),
      ...(event.issue === undefined ? {} : { issue: event.issue }), ...(event.evidence ? { evidenceEntryId: event.evidence.entryId, evidenceQuote: event.evidence.quote } : {}) });
    const source = prior.get(event.source.entryId);
    if (source?.type !== "message" || source.message.role !== "user" || !messageText(source).includes(event.source.quote)) refuse("maintainer source is unavailable");
    if (event.evidence) {
      const evidence = prior.get(event.evidence.entryId);
      if (evidence?.type !== "message" || evidence.message.role !== "toolResult" || evidence.message.isError || !messageText(evidence).includes(event.evidence.quote)) refuse("verification source is unavailable");
    }
    const before = items.get(event.id);
    if (event.action === "request") {
      if (before || !event.text) refuse("canonical request is contradictory");
      items.set(event.id, { id: event.id, text: event.text!, ...(event.issue ? { issue: event.issue } : {}), state: event.action, request: event.source, latest: event });
    } else {
      if (!before || (event.action === "reopened" ? owed(before) : !owed(before) && !(event.action === "verified" && before.state === "reported-done"))) refuse("canonical transition is contradictory");
      if (event.action === "verified" && !event.evidence) refuse("verification evidence is missing");
      items.set(event.id, { ...before!, state: event.action, latest: event });
    }
    if (items.size > 1000) refuse("ledger exceeds 1000 items; no partial owed list is available");
  }
  return items;
}
function messageText(entry: SessionEntry): string {
  if (entry.type !== "message" || (entry.message.role !== "user" && entry.message.role !== "toolResult")) return "";
  const content = entry.message.content;
  return typeof content === "string" ? content : content.filter(block => block.type === "text").map(block => block.text).join("\n");
}
export const owed = (item: ObligationItem): boolean => item.state === "request" || item.state === "reopened";

export function admitObligation(input: ObligationRequest): void {
  if (!ACTIONS.includes(input.action)) refuse("unknown action");
  const fields = input.action === "list" ? ["action"] : input.action === "request"
    ? ["action", "id", "text", "issue", "quote"] : input.action === "verified"
      ? ["action", "id", "quote", "evidenceEntryId", "evidenceQuote"] : ["action", "id", "quote"];
  for (const key of Object.keys(input)) if (!fields.includes(key)) refuse(`field ${key} is not used by ${input.action}`);
  if (input.action === "list") return;
  if (!input.id || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,159}$/.test(input.id)) refuse("id must be a stable identifier (up to 160 characters)");
  for (const key of ["quote", ...(input.action === "request" ? ["text"] : []), ...(input.action === "verified" ? ["evidenceEntryId", "evidenceQuote"] : [])] as const) {
    const value = input[key as keyof ObligationRequest];
    if (typeof value !== "string" || !value.trim() || value.length > 2000) refuse(`${key} must be nonempty and at most 2000 characters`);
  }
  if (input.issue !== undefined && !/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/issues\/\d+$/.test(input.issue)) refuse("issue must be an exact GitHub issue URL");
}

export function obligationTool(run: (callId: string, request: ObligationRequest) => Promise<unknown>): ToolDefinition {
  return {
    name: "obligation", label: "Maintainer obligations", executionMode: "sequential",
    description: "Canonical Home maintainer-obligation ledger, not summary memory. list returns only owed items (request/reopened). request opens a stable id once, with text and a verbatim quote of this maintainer message; optional issue URL links engineering work. reported-done closes the human action on his confirmation, even without independent proof. verified closes with a successful tool-result entryId and verbatim evidenceQuote from this activation. reopened requires a NEW explicit maintainer request, never an old summary or missing verification. All writes require the current maintainer turn and its verbatim quote. Closing grants no approval, task, key revocation or other effect. Never request an already completed action under another id. For an issue-linked item, record verified closure when its issue closes with evidence.",
    parameters: Type.Object({ action: StringEnum(ACTIONS), id: Type.Optional(Type.String({ maxLength: 160 })),
      text: Type.Optional(Type.String({ maxLength: 2000 })), issue: Type.Optional(Type.String({ maxLength: 2000 })),
      quote: Type.Optional(Type.String({ maxLength: 2000 })), evidenceEntryId: Type.Optional(Type.String({ maxLength: 2000 })), evidenceQuote: Type.Optional(Type.String({ maxLength: 2000 })) }, { additionalProperties: false }),
    execute: async (callId, request) => {
      const result = await run(callId, request as ObligationRequest);
      return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
    },
  };
}
