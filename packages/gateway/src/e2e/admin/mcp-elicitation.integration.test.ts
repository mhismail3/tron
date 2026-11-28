import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import type { RuntimeSlot } from "../../kernel/run/runtime-slot.js";
import { waitFor } from "../../../test-support/wait-for.js";

const roots: string[] = [];
const servers: Array<ReturnType<typeof createServer>> = [];
const registries: RuntimeRegistry[] = [];
afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(registries.splice(0).map(registry => registry.dispose()));
  for (const server of servers.splice(0)) await new Promise<void>(resolve => server.close(() => resolve()));
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

const MESSAGE = "**Use 3 threads?**  \nFrom the inbox";
const QUESTION = "Allow Tron to use search for this data?";
const STATE = "{\"elicitationId\":\"e1\",\"requestBinding\":\"b1\"}";

function reply(res: ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}
async function body(req: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.from(chunk));
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function fixture(discovers = true) {
  const calls: any[] = [];
  const server = createServer(async (req, res) => {
    if (req.method !== "POST") { res.writeHead(405); res.end(); return; }
    const rpc = await body(req);
    const result = (value: unknown) => reply(res, 200, { jsonrpc: "2.0", id: rpc.id, result: value });
    if (rpc.method === "initialize") return result({ protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } });
    if (rpc.method === "notifications/initialized") { res.writeHead(202); res.end(); return; }
    if (rpc.method === "server/discover" && discovers) return result({ resultType: "complete", supportedVersions: ["2025-11-25", "2026-07-28"], capabilities: { tools: {} } });
    if (rpc.method === "tools/list") return result({ tools: [{ name: "search", inputSchema: { type: "object", properties: { query: { type: "string" } } } }] });
    if (rpc.method !== "tools/call") return reply(res, 404, {});
    const meta = rpc.params._meta ?? {};
    const stateless = meta["io.modelcontextprotocol/protocolVersion"] === "2026-07-28";
    calls.push({ params: rpc.params, headers: { version: req.headers["mcp-protocol-version"], method: req.headers["mcp-method"], name: req.headers["mcp-name"] } });
    if (stateless && (req.headers["mcp-protocol-version"] !== "2026-07-28" || req.headers["mcp-method"] !== "tools/call" || req.headers["mcp-name"] !== rpc.params.name)) {
      return reply(res, 400, { jsonrpc: "2.0", id: rpc.id, error: { code: -32020, message: "Header mismatch" } });
    }
    if (!meta["io.modelcontextprotocol/clientCapabilities"]?.elicitation && rpc.params.arguments.query !== "needs-input") return result({ content: [{ type: "text", text: "omitted:DATA_PROTECTION_POLICY" }] });
    const answer = rpc.params.inputResponses?.approval_choice;
    if (!answer) {
      return result({ resultType: "input_required", requestState: STATE, inputRequests: { approval_choice: { method: "elicitation/create", params: { mode: "form", message: MESSAGE,
        requestedSchema: { type: "object", required: ["approval_choice"], properties: { approval_choice: { type: "string", title: QUESTION,
          enum: ["ALLOW_ONCE", "ALLOW_TOOL_ALWAYS", "DENY_ONCE"], enumNames: ["Allow once", "Always allow this tool", "Don't allow"] } } } } } } });
    }
    if (rpc.params.requestState !== STATE) return reply(res, 200, { jsonrpc: "2.0", id: rpc.id, error: { code: -32602, message: "unbound requestState" } });
    if (answer.action === "accept" && answer.content?.approval_choice?.startsWith("ALLOW")) {
      return result({ resultType: "complete", content: [{ type: "text", text: `threads:3 for ${rpc.params.arguments.query}` }] });
    }
    return result({ resultType: "complete", isError: true, content: [{ type: "text", text: "Action canceled. The user declined the confirmation request." }] });
  });
  servers.push(server);
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("fixture bind failed");
  const root = await mkdtemp(join(tmpdir(), "tron-mcp-elicitation-")); roots.push(root);
  const agentDir = join(root, "agent"), cwd = join(root, "workspace");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
  await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { url: `http://127.0.0.1:${address.port}/mcp`, exposure: "direct" } } }));
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] }));
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  const faux = fauxProvider({ provider: "mcp-elicitation", tokensPerSecond: 100_000 });
  const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
  runtime.registerNativeProvider(faux.provider);
  const registry = await createTestRegistry({ agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust: new TrustService(agentDir),
    modelRuntimeFactory: async () => runtime, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  registries.push(registry); await registry.initialize();
  const slot = await registry.create(cwd);
  const model = faux.getModel(); await slot.setModel(model.provider, model.id);
  return { calls, faux, slot };
}

function toolText(slot: RuntimeSlot, id: string): string {
  const entry = slot.snapshot().transcript.find((item: any) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === id) as any;
  return JSON.stringify(entry?.content ?? null);
}

async function pendingForm(slot: RuntimeSlot) {
  const form = await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.find(item => item.method === "form"), "the elicitation card");
  if (form.method !== "form") throw new Error("not a form");
  return form;
}

describe("MCP form elicitation", () => {
  it("asks the maintainer on the form card and retries the identical direct call with requestState and the chosen value", async () => {
    const { calls, faux, slot } = await fixture();
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("mcp__fixture__search", { query: "in:inbox" }, { id: "direct-call" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const prompting = slot.prompt("search");
    const form = await pendingForm(slot);
    expect(form.form.title).toBe("fixture/search");
    expect(form.form.questions).toEqual([{ id: "choice", question: QUESTION, context: MESSAGE, multiSelect: false, allowOther: false, options: [
      { id: "choice-0", label: "Allow once", description: "ALLOW_ONCE" },
      { id: "choice-1", label: "Always allow this tool", description: "ALLOW_TOOL_ALWAYS" },
      { id: "choice-2", label: "Don't allow", description: "DENY_ONCE" },
    ] }]);
    await slot.respondToInteraction(form.id, form.hostEpoch, form.presentationRevision, { version: 1, answers: [{ questionId: "choice", optionIds: ["choice-0"] }] }, false);
    await prompting;
    await waitFor(() => !slot.isBusy, "the turn to settle");
    expect(toolText(slot, "direct-call")).toContain("threads:3 for in:inbox");
    expect(calls).toHaveLength(2);
    expect(calls.map(call => call.headers)).toEqual([0, 1].map(() => ({ version: "2026-07-28", method: "tools/call", name: "search" })));
    expect(calls[0].params._meta["io.modelcontextprotocol/clientCapabilities"]).toEqual({ elicitation: { form: {} } });
    expect(calls[1].params).toMatchObject({ name: "search", arguments: calls[0].params.arguments, requestState: STATE,
      inputResponses: { approval_choice: { action: "accept", content: { approval_choice: "ALLOW_ONCE" } } } });
  });

  it("declines from codemode when the maintainer cancels the card, without caching the decision", async () => {
    const { calls, faux, slot } = await fixture();
    const script = "return text(await tools.mcp__fixture__search({ query: \"q\" }).catch(error => String(error)));";
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "codemode-call" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("mcp__fixture__search", { query: "again" }, { id: "second-call" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const prompting = slot.prompt("search");
    const first = await pendingForm(slot);
    await slot.respondToInteraction(first.id, first.hostEpoch, first.presentationRevision, undefined, true);
    const second = await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.find(item => item.method === "form" && item.id !== first.id), "the second card");
    await slot.respondToInteraction(second.id, second.hostEpoch, second.presentationRevision, { version: 1, answers: [{ questionId: "choice", optionIds: ["choice-2"] }] }, false);
    await prompting;
    await waitFor(() => !slot.isBusy, "the turn to settle");
    expect(toolText(slot, "codemode-call")).toContain("declined the confirmation request");
    expect(toolText(slot, "second-call")).toContain("declined the confirmation request");
    expect(calls.map(call => call.params.inputResponses?.approval_choice ?? null)).toEqual([
      null, { action: "cancel" }, null, { action: "accept", content: { approval_choice: "DENY_ONCE" } },
    ]);
  });

  it("fails without a card when a server not confirmed stateless asks for input", async () => {
    const { calls, faux, slot } = await fixture(false);
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("mcp__fixture__search", { query: "needs-input" }, { id: "unconfirmed-call" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    await slot.prompt("search");
    await waitFor(() => !slot.isBusy, "the turn to settle");
    expect(toolText(slot, "unconfirmed-call")).toContain("still requires input for search");
    expect(calls).toHaveLength(1);
    expect(calls[0].params._meta?.["io.modelcontextprotocol/clientCapabilities"]).toBeUndefined();
    expect(calls[0].headers.version).not.toBe("2026-07-28");
    expect(slot.snapshot().extensionPresentation.pendingInteractions).toHaveLength(0);
  });
});
