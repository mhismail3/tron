import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { adaptedExtensionEventHandler, adaptedToolDefinition, AUDITED_ASK_USER_PACKAGE } from "./extension-adapters.js";
import { TRON_FORM_REQUEST } from "../sessions/extension-adapter-contract.js";

const marker = "\0XYZ_ASK_USER";
const fixtureAgentRoot = mkdtempSync(join(tmpdir(), "tron-ask-user-audit-"));
const fixtureNpmRoot = join(fixtureAgentRoot, "npm");
const fixturePackageRoot = join(fixtureNpmRoot, "node_modules", "@zhushanwen", "pi-ask-user");
mkdirSync(fixturePackageRoot, { recursive: true });
writeFileSync(join(fixtureAgentRoot, "settings.json"), JSON.stringify({ packages: [AUDITED_ASK_USER_PACKAGE.source] }));
writeFileSync(join(fixturePackageRoot, "package.json"), JSON.stringify({
  name: AUDITED_ASK_USER_PACKAGE.name,
  version: AUDITED_ASK_USER_PACKAGE.version,
  dependencies: { [AUDITED_ASK_USER_PACKAGE.protocolPackage]: AUDITED_ASK_USER_PACKAGE.protocolVersion },
}));
writeFileSync(join(fixtureNpmRoot, "package-lock.json"), JSON.stringify({
  packages: {
    [`node_modules/${AUDITED_ASK_USER_PACKAGE.name}`]: {
      version: AUDITED_ASK_USER_PACKAGE.version,
      integrity: AUDITED_ASK_USER_PACKAGE.integrity,
    },
    [`node_modules/${AUDITED_ASK_USER_PACKAGE.protocolPackage}`]: {
      version: AUDITED_ASK_USER_PACKAGE.protocolVersion,
      integrity: AUDITED_ASK_USER_PACKAGE.protocolIntegrity,
    },
  },
}));
afterAll(() => rmSync(fixtureAgentRoot, { recursive: true, force: true }));
const definition = (execute: (...args: any[]) => unknown) => ({
  name: "ask_user",
  label: "Ask User",
  parameters: {
    type: "object",
    properties: {
      questions: {
        type: "array", minItems: 1, maxItems: 4,
        items: {
          type: "object",
          properties: {
            question: { type: "string" },
            header: { type: "string" },
            context: { type: "string" },
            options: {
              type: "array", minItems: 2, maxItems: 4,
              items: {
                anyOf: [
                  { type: "object", properties: { label: { type: "string" }, description: { type: "string" } }, required: ["label"] },
                  { type: "string" },
                ],
              },
            },
            multiSelect: { type: "boolean" },
          },
          required: ["question", "options"],
        },
      },
    },
    required: ["questions"],
  },
  execute,
} as any);
const extension = (source = AUDITED_ASK_USER_PACKAGE.source) => ({
  path: join(fixturePackageRoot, "index.ts"),
  resolvedPath: join(fixturePackageRoot, "index.ts"),
  sourceInfo: {
    path: join(fixturePackageRoot, "index.ts"),
    source,
    scope: "user",
    origin: "package",
  },
  tools: new Map(),
} as any);

function markerPayload(questions: unknown[], allowCancel = true): string {
  return JSON.stringify({ questions, allowCancel });
}
function context(answer: unknown, calls: any[] = []) {
  return {
    mode: "rpc", hasUI: true,
    ui: {
      [TRON_FORM_REQUEST]: async (input: any) => {
        calls.push(input);
        return answer;
      },
      async select(title: string, options: string[]) { calls.push({ primitive: { title, options } }); return options[0]; },
    },
  } as any;
}

const single = {
  question: "Which database?",
  context: "Need transactions.",
  options: [{ label: "Postgres", description: "Server" }, { label: "SQLite", description: "Embedded" }],
  multiSelect: false,
  allowOther: true,
};

describe("exact @zhushanwen/pi-ask-user semantic form adapter", () => {
  it("fails closed for wrong source, unpinned versions, paths, and incomplete schemas", () => {
    const original = definition(async () => "original");
    const provisional = extension("local");
    provisional.sourceInfo.scope = "temporary";
    provisional.sourceInfo.origin = "top-level";
    expect(adaptedToolDefinition(provisional, "ask_user", original)).not.toBe(original);
    const provisionalHandler = (() => undefined) as any;
    expect(adaptedExtensionEventHandler(provisional, provisionalHandler)).not.toBe(provisionalHandler);
    expect(adaptedToolDefinition(extension("npm:@zhushanwen/pi-ask-user@7.0.14"), "ask_user", original)).toBe(original);
    expect(adaptedToolDefinition(extension("project"), "ask_user", original)).toBe(original);
    const wrongPath = extension(); wrongPath.path = wrongPath.resolvedPath = "/project/ask-user.ts"; wrongPath.sourceInfo.path = wrongPath.path;
    expect(adaptedToolDefinition(wrongPath, "ask_user", original)).toBe(original);
    writeFileSync(join(fixtureAgentRoot, "settings.json"), JSON.stringify({ packages: [] }));
    expect(adaptedToolDefinition(provisional, "ask_user", original)).toBe(original);
    writeFileSync(join(fixtureAgentRoot, "settings.json"), JSON.stringify({ packages: [AUDITED_ASK_USER_PACKAGE.source] }));
    const unverifiable = extension();
    writeFileSync(join(fixtureNpmRoot, "package-lock.json"), JSON.stringify({ packages: {} }));
    expect(adaptedToolDefinition(unverifiable, "ask_user", original)).toBe(original);
    writeFileSync(join(fixtureNpmRoot, "package-lock.json"), JSON.stringify({
      packages: {
        [`node_modules/${AUDITED_ASK_USER_PACKAGE.name}`]: {
          version: AUDITED_ASK_USER_PACKAGE.version,
          integrity: AUDITED_ASK_USER_PACKAGE.integrity,
        },
        [`node_modules/${AUDITED_ASK_USER_PACKAGE.protocolPackage}`]: {
          version: AUDITED_ASK_USER_PACKAGE.protocolVersion,
          integrity: AUDITED_ASK_USER_PACKAGE.protocolIntegrity,
        },
      },
    }));
    const malformed = definition(async () => "original");
    malformed.parameters.properties.questions.maxItems = 8;
    expect(adaptedToolDefinition(extension(), "ask_user", malformed)).toBe(malformed);
    const driftedOptionSchema = definition(async () => "original");
    driftedOptionSchema.parameters.properties.questions.items.properties.options.items.anyOf[0].properties.value = { type: "string" };
    expect(adaptedToolDefinition(extension(), "ask_user", driftedOptionSchema)).toBe(driftedOptionSchema);
  });

  it("preserves original execution/result and encodes one atomic form answer", async () => {
    const calls: any[] = [];
    const original = definition(async (_id: string, _params: unknown, signal: AbortSignal, _update: unknown, ctx: any) => {
      const payload = markerPayload([single]);
      const raw = await ctx.ui.select(marker, [payload], { signal });
      return { content: [{ type: "text", text: "original result" }], details: JSON.parse(raw) };
    });
    const adapted = adaptedToolDefinition(extension(), "ask_user", original);
    expect(adapted.executionMode).toBe("sequential");
    const result = await adapted.execute("call-1", { questions: [single] }, new AbortController().signal, undefined, context({
      version: 1,
      answers: [{ questionId: "question-0", optionIds: ["question-0-option-1"] }],
    }, calls));
    expect(result).toEqual({
      content: [{ type: "text", text: "original result" }],
      details: { "Which database?": "SQLite" },
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].form).toMatchObject({
      version: 1, allowCancel: true, title: "Question",
      questions: [{ id: "question-0", question: "Which database?", multiSelect: false, allowOther: true }],
    });
  });

  it("encodes batched single, multiple, and Other answers by audited protocol keys", async () => {
    const questions = [
      { ...single, header: "DB" },
      { header: "Region", question: "Which regions?", options: [{ label: "US" }, { label: "EU" }, { label: "APAC" }], multiSelect: true, allowOther: true },
    ];
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) =>
      JSON.parse(await ctx.ui.select(marker, [markerPayload(questions)])));
    const adapted = adaptedToolDefinition(extension(), "ask_user", original);
    await expect(adapted.execute("call", { questions }, undefined, undefined, context({
      version: 1,
      answers: [
        { questionId: "question-0", optionIds: [], other: "CockroachDB" },
        { questionId: "question-1", optionIds: ["question-1-option-2", "question-1-option-0"], other: "LATAM" },
      ],
    }))).resolves.toEqual({ DB__other: "CockroachDB", Region: "[\"APAC\",\"US\"]", Region__other: "LATAM" });
  });

  it("returns undefined on cancellation and never delegates the marker to primitive select", async () => {
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) =>
      ctx.ui.select(marker, [markerPayload([single])]));
    const calls: any[] = [];
    await expect(adaptedToolDefinition(extension(), "ask_user", original).execute(
      "call", { questions: [single] }, undefined, undefined, context(undefined, calls),
    )).resolves.toBeUndefined();
    expect(calls).toHaveLength(1);
    expect(calls[0].primitive).toBeUndefined();
  });

  it("rejects malformed, oversized, and answer-key-colliding marker payloads instead of falling back", async () => {
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) =>
      ctx.ui.select(marker, [JSON.stringify({ questions: [single], allowCancel: true, extra: true })]));
    await expect(adaptedToolDefinition(extension(), "ask_user", original).execute(
      "call", {}, undefined, undefined, context(undefined),
    )).rejects.toThrow(/Unsupported .* RPC form contract/);

    const oversized = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) =>
      ctx.ui.select(marker, ["x".repeat(192 * 1_024 + 1)]));
    await expect(adaptedToolDefinition(extension(), "ask_user", oversized).execute(
      "call", {}, undefined, undefined, context(undefined),
    )).rejects.toThrow(/Unsupported .* RPC form contract/);

    const colliding = [{ ...single, header: "DB" }, { ...single, question: "Other?", header: "DB__other" }];
    const collision = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) =>
      ctx.ui.select(marker, [markerPayload(colliding)]));
    await expect(adaptedToolDefinition(extension(), "ask_user", collision).execute(
      "call", {}, undefined, undefined, context(undefined),
    )).rejects.toThrow(/Unsupported .* RPC form contract/);

    const reserved = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) =>
      ctx.ui.select(marker, [markerPayload([{ ...single, question: "__proto__" }])]));
    await expect(adaptedToolDefinition(extension(), "ask_user", reserved).execute(
      "call", {}, undefined, undefined, context(undefined),
    )).rejects.toThrow(/Unsupported .* RPC form contract/);
  });

  it("adapts the session_start context captured by the package channel handler", async () => {
    let captured: any;
    const handler = adaptedExtensionEventHandler(extension(), (_event: unknown, ctx: any) => { captured = ctx; });
    const calls: any[] = [];
    handler({}, context({ version: 1, answers: [{ questionId: "question-0", optionIds: ["question-0-option-0"] }] }, calls));
    await expect(captured.ui.select(marker, [markerPayload([single])])).resolves.toBe(JSON.stringify({ "Which database?": "Postgres" }));
    expect(calls[0].form.questions).toHaveLength(1);
  });

  it("honors pre-aborted and dialog abort signals", async () => {
    const controller = new AbortController(); controller.abort();
    let admitted = false;
    const ctx = context(undefined);
    ctx.ui[TRON_FORM_REQUEST] = async () => { admitted = true; return undefined; };
    const original = definition(async (_id: string, _params: unknown, signal: AbortSignal, _update: unknown, adaptedContext: any) =>
      adaptedContext.ui.select(marker, [markerPayload([single])], { signal }));
    await expect(adaptedToolDefinition(extension(), "ask_user", original).execute("call", {}, controller.signal, undefined, ctx)).resolves.toBeUndefined();
    expect(admitted).toBe(false);
  });
});
