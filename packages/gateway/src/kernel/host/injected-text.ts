import type { AgentMessage } from "../pi/agent-core.js";

export const INJECTED_TEXT_BODY_BYTES = 8192;
type Author = "tron-home" | "maintainer" | "gateway" | "automation" | "pi-subagents" | "worker";
type Kind = "brief" | "task-result" | "trigger" | "steer" | "reminder" | "settings" | "subagent-notice" | "automation" | "pending";
type Authority = "none" | "task";
const ENVELOPE = /^\[from: (tron-home|maintainer|gateway|automation|pi-subagents|worker); kind: (brief|task-result|trigger|steer|reminder|settings|subagent-notice|automation|pending); authority: (none|task)\]\n/;

export function injectedText(body: string, from: Author, kind: Kind, authority: Authority): string {
  return `[from: ${from}; kind: ${kind}; authority: ${authority}]\n${body}`;
}

export function projectInjectedMessages(messages: AgentMessage[], sessionFile: string | undefined): AgentMessage[] {
  return messages.map(message => {
    if (message.role !== "user" && message.role !== "custom") return message;
    const parts = typeof message.content === "string" ? [{ type: "text" as const, text: message.content }] : message.content;
    const bytes = parts.reduce((total, part) => {
      const envelope = part.type === "text" ? ENVELOPE.exec(part.text)?.[0] : undefined;
      return total + (envelope && part.type === "text" ? Buffer.byteLength(part.text.slice(envelope.length)) : 0);
    }, 0);
    if (bytes <= INJECTED_TEXT_BODY_BYTES) return message;
    if (!sessionFile) throw new Error("Injected text has no canonical full-text reference");
    const reference = `\n[Full text: read ${JSON.stringify(sessionFile)}; message timestamp ${message.timestamp} (${new Date(message.timestamp).toISOString()}).]`;
    let remaining = INJECTED_TEXT_BODY_BYTES - Buffer.byteLength(reference);
    if (remaining < 0) throw new Error("Injected text reference exceeds the body budget");
    let cut = false;
    const content = parts.flatMap(part => {
      const envelope = part.type === "text" ? ENVELOPE.exec(part.text)?.[0] : undefined;
      if (!envelope || part.type !== "text") return [part];
      if (cut) return [];
      const body = part.text.slice(envelope.length);
      let prefix = "";
      for (const character of body) {
        const size = Buffer.byteLength(character);
        if (size > remaining) { cut = true; break; }
        prefix += character; remaining -= size;
      }
      return [{ ...part, text: `${envelope}${prefix}${cut ? reference : ""}` }];
    });
    return { ...message, content: typeof message.content === "string" ? (content[0] as { text: string }).text : content };
  });
}
