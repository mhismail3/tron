import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DefaultResourceLoader, SettingsManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { attributeExtensions, attributedToolOwner } from "./owner-attribution.js";
import {
  createTronAskUserExtension,
  TRON_ASK_USER_INLINE_PATH,
  TRON_ASK_USER_SOURCE,
} from "./tron-ask-user-extension.js";
import { TRON_FORM_CAPABILITY } from "../sessions/extension-adapter-contract.js";
import { SemanticUIBroker } from "../sessions/semantic-ui-broker.js";
import { ExtensionPresentationStore } from "./host/extension-presentation-store.js";

function registeredTool() {
  let tool: any;
  createTronAskUserExtension()({ registerTool(value: any) { tool = value; } } as any);
  return tool;
}

const request = {
  title: "Choose a database",
  questions: [{
    question: "Which database?",
    context: "Transactions are required.",
    options: [{ label: "Postgres", description: "Server" }, { label: "SQLite" }],
    multiSelect: false,
    allowOther: true,
  }],
};

describe("Tron-owned ask_user extension", () => {
  it("loads the named first-party tool through the real Pi resource loader", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-ask-user-loader-"));
    try {
      const loader = new DefaultResourceLoader({
        cwd: root,
        agentDir: root,
        settingsManager: SettingsManager.inMemory(),
        noExtensions: true,
        noSkills: true,
        noPromptTemplates: true,
        noThemes: true,
        noContextFiles: true,
        extensionFactories: [{ name: "tron-ask-user", factory: createTronAskUserExtension() }],
        extensionsOverride(base) {
          return attributeExtensions(base, undefined, { requireTronAskUser: true });
        },
      });
      await loader.reload();
      const loaded = loader.getExtensions().extensions.filter((extension) => extension.tools.has("ask_user"));
      expect(loaded).toHaveLength(1);
      expect(loaded[0]!.path).toBe(TRON_ASK_USER_INLINE_PATH);
      expect(loaded[0]!.tools.get("ask_user")!.definition.executionMode).toBe("sequential");
      await loader.reload();
      expect(loader.getExtensions().extensions.filter((extension) => extension.tools.has("ask_user"))).toHaveLength(1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("requests one typed broker form and formats its canonical answer without markers", async () => {
    const tool = registeredTool();
    const calls: any[] = [];
    const answer = {
      version: 1 as const,
      answers: [{ questionId: "question-0", optionIds: ["question-0-option-1"], other: "Embedded" }],
    };
    const result = await tool.execute("call", request, undefined, undefined, {
      hasUI: true,
      ui: { [TRON_FORM_CAPABILITY]: async (input: any) => { calls.push(input); return answer; } },
    });
    expect(tool.executionMode).toBe("sequential");
    expect(calls).toHaveLength(1);
    expect(calls[0].form).toMatchObject({ version: 1, title: request.title, allowCancel: true });
    expect(calls[0].form.questions[0]).toMatchObject({
      id: "question-0",
      options: [
        { id: "question-0-option-0", label: "Postgres" },
        { id: "question-0-option-1", label: "SQLite" },
      ],
    });
    expect(JSON.stringify(calls[0])).not.toContain("XYZ_ASK_USER");
    expect(result.details).toEqual({
      title: request.title,
      questions: [{
        question: "Which database?",
        context: "Transactions are required.",
        options: [{ label: "Postgres", description: "Server" }, { label: "SQLite" }],
        multiSelect: false,
        allowOther: true,
      }],
      answers: { "Which database?": { selected: ["SQLite"], other: "Embedded" } },
      cancelled: false,
    });
    expect(JSON.stringify(result.details)).not.toContain('"id"');
    expect(result.content[0].text).toBe('"Which database?" = "SQLite, Embedded"');
  });

  it("retains explicit title and disallowed Other in canonical result details", async () => {
    const tool = registeredTool();
    const result = await tool.execute("call", {
      ...request,
      title: "Exact title",
      allowCancel: false,
      questions: [{ ...request.questions[0], allowOther: false }],
    }, undefined, undefined, {
      hasUI: true,
      ui: { [TRON_FORM_CAPABILITY]: async () => ({
        version: 1,
        answers: [{ questionId: "question-0", optionIds: ["question-0-option-0"] }],
      }) },
    });
    expect(result.details).toMatchObject({
      title: "Exact title",
      questions: [{ allowOther: false }],
      cancelled: false,
    });
  });

  it("qualifies through the real semantic broker answer boundary", async () => {
    const broker = new SemanticUIBroker(new ExtensionPresentationStore(() => {}));
    const tool = registeredTool();
    const execution = tool.execute("call", request, undefined, undefined, {
      ui: broker.context(),
      hasUI: true,
    });
    const pending = broker.presentation.state().pendingInteractions[0]!;
    expect(pending.method).toBe("form");
    broker.respond(pending.id, pending.hostEpoch, pending.presentationRevision, {
      version: 1,
      answers: [{ questionId: "question-0", optionIds: ["question-0-option-0"] }],
    }, false);
    await expect(execution).resolves.toMatchObject({ details: { cancelled: false } });
  });

  it("returns upstream cancellation guidance when the broker has no answer", async () => {
    const tool = registeredTool();
    const result = await tool.execute("call", { questions: request.questions, allowCancel: true }, undefined, undefined, {
      hasUI: true,
      ui: { [TRON_FORM_CAPABILITY]: async () => undefined },
    });
    expect(result.details).toMatchObject({ cancelled: true, answers: {}, title: "Question" });
    expect((result.details as any).questions[0]).not.toHaveProperty("id");
    expect(result.content[0].text).toContain("User cancelled.");
    expect(result.content[0].text).toContain("Do not assume an answer");
  });

  it("distinguishes an aborted agent from user cancellation", async () => {
    const tool = registeredTool();
    const controller = new AbortController();
    controller.abort();
    const result = await tool.execute("call", request, controller.signal, undefined, {
      hasUI: true,
      ui: { [TRON_FORM_CAPABILITY]: async () => undefined },
    });
    expect(result.details).toMatchObject({ cancelled: true, answers: {}, title: request.title });
    expect((result.details as any).questions[0]).not.toHaveProperty("id");
    expect(result.content[0].text).toContain("Agent aborted");
    expect(result.content[0].text).toContain("do not retry ask_user");
  });

  it("preserves an answer whose question text is __proto__", async () => {
    const tool = registeredTool();
    const protoRequest = { ...request, questions: [{ ...request.questions[0], question: "__proto__" }] };
    const result = await tool.execute("call", protoRequest, undefined, undefined, {
      hasUI: true,
      ui: { [TRON_FORM_CAPABILITY]: async () => ({ version: 1, answers: [{ questionId: "question-0", optionIds: ["question-0-option-0"] }] }) },
    });
    expect(JSON.stringify(result.details)).toContain("__proto__");
    expect((result.details as any).answers["__proto__"].selected).toEqual(["Postgres"]);
  });

  it("rejects explicit cancellation when the form disallows it", async () => {
    const broker = new SemanticUIBroker(new ExtensionPresentationStore(() => {}));
    const tool = registeredTool();
    const execution = tool.execute("call", { ...request, allowCancel: false }, undefined, undefined, {
      ui: broker.context(), hasUI: true,
    });
    const pending = broker.presentation.state().pendingInteractions[0]!;
    expect(() => broker.respond(pending.id, pending.hostEpoch, pending.presentationRevision, undefined, true))
      .toThrow(/does not allow user cancellation/);
    expect(broker.presentation.state().pendingInteractions).toHaveLength(1);
    broker.cancelAll("test cleanup");
    await expect(execution).rejects.toMatchObject({ code: "cancelled" });
  });

  it("renders undefined and malformed SDK call/result details without throwing", () => {
    const tool = registeredTool();
    const theme = { fg: (_color: string, text: string) => text, bold: (text: string) => text };
    expect(() => tool.renderCall(undefined, theme)).not.toThrow();
    expect(() => tool.renderCall({ questions: undefined }, theme)).not.toThrow();
    expect(() => tool.renderCall({ questions: [null, { question: 4 }] }, theme)).not.toThrow();
    expect(() => tool.renderResult(undefined, {}, theme)).not.toThrow();
    expect(() => tool.renderResult({ details: { error: "failed" } }, {}, theme)).not.toThrow();
    expect(() => tool.renderResult({ details: { cancelled: false, questions: undefined, answers: {} } }, {}, theme)).not.toThrow();
  });

  it("preserves constructor and toString answer keys without prototype mutation", async () => {
    const tool = registeredTool();
    const questions = ["__proto__", "constructor", "toString"].map((question) => ({
      question,
      options: [{ label: "Yes" }, { label: "No" }],
    }));
    const result = await tool.execute("call", { questions }, undefined, undefined, {
      hasUI: true,
      ui: { [TRON_FORM_CAPABILITY]: async () => ({
        version: 1,
        answers: questions.map((_, index) => ({ questionId: `question-${index}`, optionIds: [`question-${index}-option-0`] })),
      }) },
    });
    const answers = (result.details as any).answers;
    expect(answers["__proto__"].selected).toEqual(["Yes"]);
    expect(answers.constructor.selected).toEqual(["Yes"]);
    expect(answers.toString.selected).toEqual(["Yes"]);
    expect(Object.getPrototypeOf(answers)).toBeNull();
  });

  it("has an exact inline owner identity", () => {
    const firstParty = {
      path: TRON_ASK_USER_INLINE_PATH,
      resolvedPath: TRON_ASK_USER_INLINE_PATH,
      sourceInfo: { path: TRON_ASK_USER_INLINE_PATH, source: "local", scope: "temporary", origin: "top-level" },
      handlers: new Map(), tools: new Map([["ask_user", { definition: registeredTool() }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    const result = attributeExtensions({ extensions: [firstParty as any], errors: [], runtime: {} as any }, undefined, { requireTronAskUser: true });
    const tool = result.extensions[0]!.tools.get("ask_user")!;
    expect(attributedToolOwner(tool)?.source).toBe(TRON_ASK_USER_SOURCE);
  });

  it("keeps the foreign adapter available when the first-party capability is disabled", () => {
    const foreign = {
      path: "/project/ask-user.ts", resolvedPath: "/project/ask-user.ts",
      sourceInfo: { path: "/project/ask-user.ts", source: "project", scope: "project", origin: "top-level" },
      handlers: new Map(), tools: new Map([["ask_user", { definition: registeredTool() }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    expect(() => attributeExtensions({ extensions: [foreign as any], errors: [], runtime: {} as any })).not.toThrow();
  });

  it("identifies the superseded audited package in the actionable conflict", () => {
    const firstParty = {
      path: TRON_ASK_USER_INLINE_PATH, resolvedPath: TRON_ASK_USER_INLINE_PATH,
      sourceInfo: { path: TRON_ASK_USER_INLINE_PATH, source: "local", scope: "temporary", origin: "top-level" },
      handlers: new Map(), tools: new Map([["ask_user", { definition: registeredTool() }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    const foreign = {
      path: "/agent/node_modules/@zhushanwen/pi-ask-user/index.js", resolvedPath: "/agent/node_modules/@zhushanwen/pi-ask-user/index.js",
      sourceInfo: { path: "/agent/node_modules/@zhushanwen/pi-ask-user/index.js", source: "npm:@zhushanwen/pi-ask-user@7.0.15", scope: "user", origin: "package" },
      handlers: new Map(), tools: new Map([["ask_user", { definition: registeredTool() }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    expect(() => attributeExtensions({ extensions: [foreign as any, firstParty as any], errors: [], runtime: {} as any }, undefined, { requireTronAskUser: true }))
      .toThrow(/configured npm:@zhushanwen\/pi-ask-user@7\.0\.15.*disable only that extension/);
  });

  it("fails closed rather than selecting a foreign same-name registration", () => {
    const firstParty = {
      path: TRON_ASK_USER_INLINE_PATH, resolvedPath: TRON_ASK_USER_INLINE_PATH,
      sourceInfo: { path: TRON_ASK_USER_INLINE_PATH, source: "local", scope: "temporary", origin: "top-level" },
      handlers: new Map(), tools: new Map([["ask_user", { definition: registeredTool() }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    const foreign = {
      path: "/project/ask-user.ts", resolvedPath: "/project/ask-user.ts",
      sourceInfo: { path: "/project/ask-user.ts", source: "project", scope: "project", origin: "top-level" },
      handlers: new Map(), tools: new Map([["ask_user", { definition: registeredTool() }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    expect(() => attributeExtensions({ extensions: [foreign as any, firstParty as any], errors: [], runtime: {} as any }, undefined, { requireTronAskUser: true }))
      .toThrow("ask_user tool name is reserved");
  });
});
