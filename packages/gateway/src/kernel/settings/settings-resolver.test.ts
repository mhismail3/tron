import { describe, expect, it } from "vitest";
import { TEST_SETTINGS_SCHEMA } from "../../../test-support/settings-schema.js";
import { keyForHome } from "./settings-schema.js";
import { composedBelow, resolveSettings, targetLayers } from "./settings-resolver.js";
import type { SettingsStores } from "./settings-types.js";

/**
 * What resolveSettings and composedBelow return around proof block settings/precedence, on the real schema. The
 * block decides which layer wins, which layers are shown and which is not applied, over tokens; these cases pin
 * that the resolver gives it the right facts (a layer's per-model and plain values, admission, trust) and turns
 * its answer back into the right values, rows and badges.
 */
const MODEL = "anthropic/claude-test";
const session = { kind: "session" as const, sessionId: "s" };
const global = { defaultProvider: "anthropic", defaultModel: "claude-test", defaultThinkingLevel: "low", defaultTools: ["read", "bash", "edit"] };
const options = { format: { modelName: () => undefined }, options: { clamp: (_source: string, _dependency: unknown, value: unknown) => value } };
const stores = (extra: Partial<SettingsStores>, project = true): SettingsStores =>
  ({ layers: targetLayers(session, { project }), gateway: {}, trust: {}, macTerminal: {}, global, ...extra });
const project = (applied: boolean) => ({ root: "/work/app", document: { modelThinkingLevels: { [MODEL]: "high" }, defaultTools: ["+grep"] }, applied });
const chat = { thinking: "minimal", tools: ["+web", "-bash"], settings: {} };
const row = (given: SettingsStores, key: string) => resolveSettings(TEST_SETTINGS_SCHEMA, session, given, options).keys.find(candidate => candidate.key === key)!;
const THINKING = "model.thinking[role=chat]";
const FOR_MODEL = { kind: "scope", label: `For ${MODEL}`, detail: MODEL };

describe("settings resolution around the precedence block", () => {
  it("an untrusted project's per-model value is shown as not applied and the chat's own value stands", () => {
    expect(row(stores({ project: project(false), session: chat }), THINKING)).toMatchObject({
      value: "minimal", display: "Minimal", layer: "session", applied: false, reason: "untrusted", overridden: true,
      qualifiers: { role: "chat", model: MODEL },
      badges: [FOR_MODEL, { kind: "state", label: "Not applied (untrusted)", detail: "Project: High", action: { kind: "reviewTrust", label: "Review trust" } }],
      layers: [
        { layer: "project", value: "high", display: "High", applied: false, reason: "untrusted" },
        { layer: "session", value: "minimal", display: "Minimal", applied: true },
        { layer: "global", value: "low", display: "Low", applied: true },
      ],
    });
    expect(row(stores({ project: project(false), session: chat }), THINKING)).not.toHaveProperty("projectSetting");
  });

  it("a trusted project's value beats the chat's, and its row names the per-model path it came from", () => {
    const resolved = row(stores({ project: project(true), session: chat }), THINKING);
    expect(resolved).toMatchObject({
      value: "high", layer: "project", applied: true, badges: [FOR_MODEL],
      projectSetting: { file: "/work/app/.pi/settings.json", path: `modelThinkingLevels["${MODEL}"]` },
      layers: [{ layer: "project", value: "high", applied: true }, { layer: "session", value: "minimal", applied: true }, { layer: "global", value: "low", applied: true }],
    });
    expect(resolved).not.toHaveProperty("reason");
  });

  it("scope outranks specificity: a Global per-model value loses to the chat's plain value, and wins over Global's plain one", () => {
    const perModel = { ...global, modelThinkingLevels: { [MODEL]: "high" } };
    expect(row(stores({ global: perModel, session: { thinking: "minimal", settings: {} } }, false), THINKING)).toMatchObject({
      value: "minimal", layer: "session", applied: true, overridden: true,
      layers: [{ layer: "session", value: "minimal", applied: true }, { layer: "global", value: "high", applied: true }],
    });
    expect(row(stores({ global: perModel, session: { settings: {} } }, false), THINKING)).toMatchObject({
      value: "high", layer: "global", applied: true, overridden: false,
      layers: [{ layer: "session", applied: true }, { layer: "global", value: "high", display: "High", applied: true }],
    });
  });

  it("with no layer set, a setting resolves to its default from Global, and every layer row is empty", () => {
    const bare = stores({ global: { defaultProvider: "anthropic", defaultModel: "claude-test" }, session: { settings: {} } }, false);
    expect(row(bare, THINKING)).toMatchObject({ value: "medium", layer: "global", applied: true, overridden: false, layers: [{ layer: "session", applied: true }, { layer: "global", applied: true }] });
    expect(row(bare, "tools.active")).toMatchObject({ value: ["read", "bash", "edit", "write"], layer: "global", applied: true });
  });

  it("a composing setting folds its applied layers lowest first, and a layer the setting does not admit takes no part", () => {
    // tools.active is not project-settable: the project's +grep never enters, trusted or not.
    for (const applied of [true, false]) {
      expect(row(stores({ project: project(applied), session: chat }), "tools.active")).toMatchObject({
        value: ["read", "edit", "web"], display: "3 tools", layer: "session", applied: true, badges: [],
        layers: [{ layer: "session", value: ["+web", "-bash"], applied: true }, { layer: "global", value: ["read", "bash", "edit"], applied: true }],
      });
    }
  });

  it("what lies below a layer is the plain values of the applied layers strictly below it, composed", () => {
    const tools = keyForHome(TEST_SETTINGS_SCHEMA.schemaKey("tools.active"), false);
    const given = stores({ project: project(true), session: chat });
    expect(composedBelow(given, tools, {}, "global")).toEqual(["read", "bash", "edit", "write"]);
    expect(composedBelow(given, tools, {}, "session")).toEqual(["read", "bash", "edit"]);
    expect(composedBelow(given, tools, {}, "project")).toEqual(["read", "edit", "web"]);
    // An ordinary setting does not compose: the plain value of the highest layer below, never a per-model one.
    const thinking = keyForHome(TEST_SETTINGS_SCHEMA.schemaKey(THINKING), false);
    const perModel = stores({ global: { ...global, modelThinkingLevels: { [MODEL]: "high" } }, project: project(true), session: chat });
    expect(composedBelow(perModel, thinking, { role: "chat", model: MODEL }, "global")).toBe("medium");
    expect(composedBelow(perModel, thinking, { role: "chat", model: MODEL }, "session")).toBe("low");
    expect(composedBelow(perModel, thinking, { role: "chat", model: MODEL }, "project")).toBe("minimal");
  });

  it("Home is the layer above Global for the Home chat: its value wins under the Session scope, and below it lies Global alone", () => {
    const home = { kind: "home" as const };
    const given: SettingsStores = { layers: targetLayers(home, {}), gateway: {}, trust: {}, macTerminal: {}, global, home: { thinking: { chat: "high" } }, session: { settings: {} } };
    const thinking = keyForHome(TEST_SETTINGS_SCHEMA.schemaKey(THINKING), true);
    expect(resolveSettings(TEST_SETTINGS_SCHEMA, home, given, options).keys.find(candidate => candidate.key === THINKING)).toMatchObject({
      value: "high", layer: "session", applied: true, overridden: true,
      layers: [{ layer: "session", value: "high", applied: true }, { layer: "global", value: "low", applied: true }],
    });
    expect(composedBelow(given, thinking, { role: "chat", model: MODEL }, "home")).toBe("low");
    expect(composedBelow(given, thinking, { role: "chat", model: MODEL }, "global")).toBe("medium");
    // Without a Home value the row falls to Global, and Home's empty layer is still listed.
    expect(resolveSettings(TEST_SETTINGS_SCHEMA, home, { ...given, home: {} }, options).keys.find(candidate => candidate.key === THINKING)).toMatchObject({
      value: "low", layer: "global", overridden: false, layers: [{ layer: "session", applied: true }, { layer: "global", value: "low", applied: true }],
    });
  });
});
