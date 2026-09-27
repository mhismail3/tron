// Faux model for scripts/tron-profile-gateway. The profiler copies this file
// into the isolated fixture's agent extensions directory; it never loads into a
// user Gateway. Each response is derived from the latest user directive and the
// canonical context alone, so a reloaded or shared extension module cannot
// desynchronize the workload, and every iteration streams identical content.
import { fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall } from "@earendil-works/pi-ai";

const tokensPerSecond = Number(process.env.TRON_PROFILE_TOKENS_PER_SECOND ?? "80");
if (!Number.isFinite(tokensPerSecond) || tokensPerSecond <= 0) {
  throw new Error("TRON_PROFILE_TOKENS_PER_SECOND must be a positive number");
}

const faux = fauxProvider({
  provider: "tron-profile",
  models: [{
    id: "profile-model",
    name: "Tron Profile Model",
    reasoning: true,
    input: ["text", "image"],
    // Large enough that the seeded transcript never triggers compaction.
    contextWindow: 4_000_000,
    maxTokens: 64_000,
  }],
  tokensPerSecond,
  // Fixed chunk size keeps the delta cadence identical across iterations.
  tokenSize: { min: 4, max: 4 },
});

const WORDS = [
  "gateway", "session", "snapshot", "transcript", "stream", "render", "cursor", "window",
  "latency", "budget", "reply", "canonical", "projection", "socket", "frame", "payload",
  "phone", "runtime", "settle", "bounded", "tool", "result", "summary", "reconnect",
  "energy", "timer", "radio", "measure", "profile", "baseline", "change", "regression",
];

function generator(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function sentence(random: () => number): string {
  const count = 8 + Math.floor(random() * 10);
  const words = Array.from({ length: count }, () => WORDS[Math.floor(random() * WORDS.length)]);
  const text = words.join(" ");
  return `${text[0].toUpperCase()}${text.slice(1)}.`;
}

/** Deterministic Markdown of exactly `length` characters. */
function markdown(length: number, seed: number): string {
  const random = generator(seed);
  const blocks: string[] = [];
  let total = 0;
  let section = 1;
  while (total < length) {
    const kind = blocks.length === 0 ? 0 : Math.floor(random() * 4);
    let block: string;
    if (kind === 0) {
      block = `## Section ${section++}\n\n${sentence(random)} ${sentence(random)}`;
    } else if (kind === 1) {
      block = Array.from({ length: 3 + Math.floor(random() * 3) }, () => `- **${WORDS[Math.floor(random() * WORDS.length)]}**: ${sentence(random)}`).join("\n");
    } else if (kind === 2) {
      block = "```swift\n" + Array.from({ length: 4 }, (_, index) => `let value${index} = ${Math.floor(random() * 1000)} // ${WORDS[index * 3]}`).join("\n") + "\n```";
    } else {
      block = `${sentence(random)} ${sentence(random)} ${sentence(random)}`;
    }
    blocks.push(block);
    total += block.length + 2;
  }
  return blocks.join("\n\n").slice(0, length);
}

type Directive = { scenario: string; values: Record<string, number> };

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((block) => (block && typeof block === "object" && (block as { type?: unknown }).type === "text"
    ? String((block as { text?: unknown }).text ?? "") : "")).join("");
}

function latestDirective(messages: readonly { role: string; content?: unknown }[]): { directive: Directive; toolResults: number } {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.role !== "user") continue;
    const match = /^tron-profile ([a-z-]+)((?: [a-z]+=\d+)*)\s*$/.exec(textOf(message.content).trim());
    if (!match) throw new Error("The profile model only answers tron-profile directives");
    const values: Record<string, number> = {};
    for (const pair of match[2].trim().split(" ").filter(Boolean)) {
      const [key, value] = pair.split("=");
      values[key] = Number(value);
    }
    const toolResults = messages.slice(index + 1).filter((candidate) => candidate.role === "toolResult").length;
    return { directive: { scenario: match[1], values }, toolResults };
  }
  throw new Error("The profile model received no user directive");
}

function respond(context: { messages: readonly { role: string; content?: unknown }[] }) {
  const { directive, toolResults } = latestDirective(context.messages);
  const value = (key: string, fallback: number) => directive.values[key] ?? fallback;
  const seed = value("seed", 1);
  if (directive.scenario === "stream-reply") {
    return fauxAssistantMessage([
      fauxThinking(markdown(value("thinking", 800), seed + 1000).replace(/[#`*-]/g, " ")),
      fauxText(markdown(value("chars", 6000), seed)),
    ]);
  }
  if (directive.scenario === "tool-loop") {
    const tools = value("tools", 10);
    if (toolResults < tools) {
      const step = String(toolResults + 1).padStart(2, "0");
      return fauxAssistantMessage([
        fauxThinking(markdown(160, seed * 100 + toolResults).replace(/[#`*-]/g, " ")),
        fauxText(`Step ${step}: ${sentence(generator(seed * 100 + toolResults))}`),
        fauxToolCall("bash", {
          command: `sleep 0.3; seq -f 'profile step ${step} line %03g: deterministic tool output for wire accounting' 1 ${value("lines", 24)}`,
        }, { id: `profile_call_${step}` }),
      ], { stopReason: "toolUse" });
    }
    return fauxAssistantMessage(markdown(value("chars", 1500), seed));
  }
  throw new Error(`Unknown tron-profile scenario: ${directive.scenario}`);
}

// Re-arm on every call: the queue never drains however many turns a run takes.
function step(context: { messages: readonly { role: string; content?: unknown }[] }) {
  faux.appendResponses([step]);
  return respond(context);
}
faux.setResponses([step]);

export default function (pi: { registerProvider(provider: unknown): void }) {
  pi.registerProvider(faux.provider);
}
