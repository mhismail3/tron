#!/usr/bin/env bash
# Sourced by ios-gateway-e2e-test; uses its resolved gateway_dir.
write_fixture_extension() {
  local agent_dir="$1" pi_ai_url
  pi_ai_url="file://$gateway_dir/node_modules/@earendil-works/pi-ai/dist/index.js"
  mkdir -p "$agent_dir/extensions"
  cat >"$agent_dir/extensions/tron-e2e.ts" <<EOF
import { fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall } from "$pi_ai_url";
const faux = fauxProvider({
  provider: "tron-e2e",
  models: [{ id: "e2e-model", name: "Tron E2E Model", reasoning: true, input: ["text", "image"], contextWindow: 32768, maxTokens: 4096 }],
  tokensPerSecond: 8,
});
// A prompt carrying the codemode journey marker asks its question from inside codemode
// (#929); its turns are decided by what the model sees, not by a script position.
const CODEMODE_MARKER = "CODEMODE-ASK-USER-JOURNEY";
const textOf = (message) => typeof message?.content === "string" ? message.content
  : (message?.content ?? []).map((part) => part.type === "text" ? part.text : "").join("");
const codemodeTurn = (context) => {
  const last = context.messages.at(-1);
  if (last?.role === "toolResult" && last.toolName === "codemode") {
    const output = textOf(last);
    const choice = ["Approve it", "Hold it"].find((label) => output.includes('"' + label + '"'));
    return fauxAssistantMessage("Codemode question answered: " + (choice ?? "no answer in: " + output.replace(/[ \n\t]+/g, " ").slice(-200)));
  }
  if (last?.role === "user" && textOf(last).includes(CODEMODE_MARKER)) {
    return fauxAssistantMessage([fauxToolCall("codemode", { code: 'text(await tools.ask_user({ title: "Codemode approval", questions: [{ header: "Approve", question: "Approve the codemode step?", options: [{ label: "Approve it" }, { label: "Hold it" }] }] }));' }, { id: "e2e-codemode-ask" })], { stopReason: "toolUse" });
  }
  return undefined;
};
// Ordinary prompts consume this script in order. A prompt carrying the ask
// journey marker consumes its own script instead, so the real-UI ask journey
// (#935) cannot shift the responses every other journey and boundary case expects.
const ordinary = [
  async () => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    return fauxAssistantMessage("Streaming response starts now and remains active until the phone disconnects. Detached response complete");
  },
  fauxAssistantMessage([
    fauxThinking("Preparing portable parallel tool interactions"),
    fauxText("Checking the commands before running them."),
    fauxToolCall("bash", { command: "sleep 2; printf first-output" }, { id: "e2e-tool-1" }),
    fauxToolCall("bash", { command: "sleep 1; printf second-output" }, { id: "e2e-tool-2" }),
    fauxToolCall("bash", { command: "printf third-output" }, { id: "e2e-tool-3" }),
  ], { stopReason: "toolUse" }),
  fauxAssistantMessage("Tool response complete after all three tools."),
];
const askJourneyMarker = "Fixture ask journey";
const askJourney = [
  fauxAssistantMessage([
    fauxText("One decision is needed before continuing."),
    fauxToolCall("ask_user", {
      title: "Fixture deployment",
      questions: [{
        header: "Target",
        question: "Where should the fixture deploy?",
        options: [{ label: "Staging" }, { label: "Production" }, { label: "Canary" }],
        multiSelect: true,
      }],
    }, { id: "e2e-ask-1" }),
  ], { stopReason: "toolUse" }),
  fauxAssistantMessage("Ask journey answered: the fixture received the form answer."),
];
// A prompt carrying the steer journey marker holds its turn until the phone
// has queued a message, then ends it, so Pi delivers the queued steer (#974).
// The steered photo has no text; its turn is recognised by its image.
const steerJourneyMarker = "Fixture steer journey";
let steerContext;
const holdUntilSteerQueued = async () => {
  const deadline = Date.now() + 180000;
  while (!steerContext?.hasPendingMessages() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  // Keep the run going briefly so the phone presents the queued steer.
  await new Promise((resolve) => setTimeout(resolve, 4000));
  return fauxAssistantMessage("Steer journey turn finished.");
};
const lastUserHasImage = (context) => {
  const last = context.messages.at(-1);
  return last?.role === "user" && Array.isArray(last.content) && last.content.some((part) => part.type === "image");
};
const latestUserText = (context) => {
  for (let index = context.messages.length - 1; index >= 0; index -= 1) {
    const message = context.messages[index];
    if (message.role !== "user") continue;
    if (typeof message.content === "string") return message.content;
    return message.content.filter((block) => block.type === "text").map((block) => block.text).join("\n");
  }
  return "";
};
const scripted = (context, options, state, model) => {
  if (latestUserText(context).includes(CODEMODE_MARKER)) return codemodeTurn(context) ?? fauxAssistantMessage("", { stopReason: "error", errorMessage: "Unexpected codemode journey turn" });
  if (latestUserText(context).includes("historical sheet replay") && context.messages.at(-1)?.role === "toolResult"
      && context.messages.at(-1)?.toolName === "ask_user") {
    // The cold replay journey alternates a custom answer sheet with an
    // ordinary file tool, whose native detent belongs to each presentation.
    return fauxAssistantMessage([fauxText("Reading the durable project rules."),
      fauxToolCall("read", { path: "AGENTS.md" }, { id: "e2e-replay-read" })], { stopReason: "toolUse" });
  }
  if (lastUserHasImage(context)) return fauxAssistantMessage("Steer journey saw the photo.");
  if (latestUserText(context).includes(steerJourneyMarker)) return holdUntilSteerQueued();
  const step = (latestUserText(context).includes(askJourneyMarker) ? askJourney : ordinary).shift();
  if (step === undefined) {
    return fauxAssistantMessage("", { stopReason: "error", errorMessage: "No more faux responses queued" });
  }
  return typeof step === "function" ? step(context, options, state, model) : step;
};
faux.setResponses(Array.from({ length: 64 }, () => scripted));
export default function (pi) {
  pi.registerProvider(faux.provider);
  // Hermetic manual OAuth: no browser endpoint or real credential is used.
  // The real Pi session owns this callback/state across the phone's reconnect.
  pi.registerProvider("tron-e2e-oauth", {
    name: "Alpha Login Fixture", api: "openai-completions", baseUrl: "https://example.invalid/v1",
    models: [{ id: "oauth-fixture", name: "OAuth Fixture", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 1024 }],
    oauth: {
      name: "Alpha Login Fixture",
      async login(callbacks) {
        callbacks.onAuth({ url: "https://example.invalid/authorize?state=fixture-state" });
        const input = await callbacks.onPrompt({ message: "Paste the fixture callback code:", placeholder: "Fixture OAuth code" });
        if (input !== "fixture-code#fixture-state") throw new Error("Fixture OAuth state mismatch");
        return { refresh: "fixture-refresh", access: "fixture-access", expires: Date.now() + 3600000 };
      },
      async refreshToken(credentials) { return credentials; },
      getApiKey(credentials) { return credentials.access; }
    }
  });
  pi.on("agent_start", (_event, ctx) => { steerContext = ctx; });
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return undefined;
    const choice = await ctx.ui.select("Allow this test command?", ["Yes", "No"]);
    return choice === "Yes" ? undefined : { block: true, reason: "Denied" };
  });
}
EOF
  cat >"$agent_dir/settings.json" <<'EOF'
{
  "defaultProvider": "tron-e2e",
  "defaultModel": "e2e-model",
  "defaultThinkingLevel": "low",
  "defaultTools": ["+codemode"],
  "defaultProjectTrust": "never",
  "enableAnalytics": false,
  "enableInstallTelemetry": false
}
EOF
}

