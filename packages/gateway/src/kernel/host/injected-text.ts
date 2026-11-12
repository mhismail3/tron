import type { AgentMessage } from "../pi/agent-core.js";
import type { ImageContent, TextContent } from "../pi/ai.js";

export const INJECTED_TEXT_BODY_BYTES = 8192;
type Content = string | Array<TextContent | ImageContent>;
type Author = "tron-home" | "maintainer" | "gateway" | "automation" | "pi-subagents" | "worker";
type Kind = "brief" | "checkin" | "task-result" | "trigger" | "steer" | "reminder" | "settings" | "subagent-notice" | "automation" | "pending";
type Authority = "none" | "task";
const ENVELOPE = /^\[from: (tron-home|maintainer|gateway|automation|pi-subagents|worker); kind: (brief|checkin|task-result|trigger|steer|reminder|settings|subagent-notice|automation|pending); authority: (none|task)\]\n/;

export function injectedText<T extends Content>(body: T, from: Author, kind: Kind, authority: Authority, fullTextReference?: string): T {
  const envelope = `[from: ${from}; kind: ${kind}; authority: ${authority}]\n`;
  const content = (typeof body === "string" ? `${envelope}${body}` : [{ type: "text", text: envelope }, ...body]) as T;
  return fullTextReference === undefined ? content : boundedContent(content, () => fullTextReference);
}

function boundedContent<T extends Content>(value: T, fullTextReference: () => string): T {
  const parts: Array<TextContent | ImageContent> = typeof value === "string" ? [{ type: "text", text: value }] : value as Array<TextContent | ImageContent>;
  const first = parts.findIndex(part => part.type === "text");
  const head = parts[first];
  const envelope = head?.type === "text" ? ENVELOPE.exec(head.text)?.[0] : undefined;
  if (!envelope) return value;
  const bytes = parts.reduce((total, part) => total + (part.type === "text" ? Buffer.byteLength(part.text) : 0), 0) - Buffer.byteLength(envelope);
  if (bytes <= INJECTED_TEXT_BODY_BYTES) return value;
  const reference = `\n[Full text: ${fullTextReference()}.]`;
  let remaining = INJECTED_TEXT_BODY_BYTES - Buffer.byteLength(reference);
  if (remaining < 0) throw new Error("Injected text reference exceeds the body budget");
  let cut = false;
  const content = parts.flatMap<TextContent | ImageContent>((part, index) => {
    if (part.type !== "text") return [part];
    if (cut) return [];
    const body = index === first ? part.text.slice(envelope.length) : part.text;
    let prefix = "";
    for (const character of body) {
      const size = Buffer.byteLength(character);
      if (size > remaining) { cut = true; break; }
      prefix += character; remaining -= size;
    }
    return [{ ...part, text: `${index === first ? envelope : ""}${prefix}${cut ? reference : ""}` }];
  });
  return (typeof value === "string" ? (content[0] as TextContent).text : content) as T;
}

export function projectInjectedMessages(messages: AgentMessage[], sessionFile: string | undefined): AgentMessage[] {
  return messages.map(message => {
    if (message.role !== "user" && message.role !== "custom") return message;
    const details = message.role === "custom" ? message.details : undefined;
    const reference = details && typeof details === "object" && "fullTextReference" in details ? details.fullTextReference : undefined;
    const content = boundedContent(message.content, () => {
      if (typeof reference === "string") return reference;
      if (!sessionFile) throw new Error("Injected text has no canonical full-text reference");
      return `read ${JSON.stringify(sessionFile)}; message timestamp ${message.timestamp} (${new Date(message.timestamp).toISOString()})`;
    });
    return content === message.content ? message : { ...message, content };
  });
}
