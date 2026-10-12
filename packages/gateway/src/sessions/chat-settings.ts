import { randomUUID } from "node:crypto";
import { getCurrentTools } from "@earendil-works/pi-ai";
import type { SessionEntry, SessionManager } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { FixedSetting } from "../admin/settings-resolver.js";
import { hasChatSettingsApplier, schemaKey } from "../admin/settings-schema.js";

export const CHAT_SETTINGS_ENTRY = "tron.settings.v1";

/** Rollover keeps policy, not conversation. Read only recognized canonical
 * state; audit receipts and old message/entry identities belong to the predecessor. */
export function appendChatSettingsSnapshot(entries: readonly SessionEntry[], manager: SessionManager): void {
  const model = entries.findLast(entry => entry.type === "model_change");
  if (model?.type === "model_change") manager.appendModelChange(model.provider, model.modelId);
  const thinking = entries.findLast(entry => entry.type === "thinking_level_change");
  if (thinking?.type === "thinking_level_change") manager.appendThinkingLevelChange(thinking.thinkingLevel);
  const fixed = readChatFixedSettings(entries);
  const choice = readChatToolChoice(entries);
  if (choice) fixed["tools.active"] = choice.fixed ?? { value: choice.tools, from: "delegate", at: new Date().toISOString(), ref: randomUUID() };
  manager.appendCustomEntry(CHAT_SETTINGS_ENTRY, {
    settings: readChatSettings(entries), fixed, requestPins: readChatRequestPins(entries),
  });
}

/** A choice after the last system frame wins; otherwise that frame is the
 * actual declared loadout, including changes made through the SDK itself. */
export function readChatToolChoice(entries: readonly SessionEntry[]): { tools: string[]; fixed?: FixedSetting } | undefined {
  const fixed = readChatFixedSettings(entries)["tools.active"];
  const fixedIndex = fixed ? entries.findIndex(entry => entry.type === "custom" && entry.customType === CHAT_SETTINGS_ENTRY
    && (entry.data as { fixed?: Record<string, FixedSetting> }).fixed?.["tools.active"]?.ref === fixed.ref) : -1;
  const declaredIndex = entries.findLastIndex(entry => entry.type === "message" && entry.message.role === "system");
  if (fixed && fixedIndex > declaredIndex && Array.isArray(fixed.value)) return { tools: fixed.value as string[], fixed };
  const declared = entries[declaredIndex];
  if (declared?.type !== "message" || declared.message.role !== "system") return undefined;
  const tools = getCurrentTools(entries.flatMap(entry => entry.type === "message" && entry.message.role === "system" ? [entry.message] : [])).map(tool => tool.name);
  return { tools, ...(fixed && JSON.stringify(fixed.value) === JSON.stringify(tools) ? { fixed } : {}) };
}

/** Branch-local truth. Fork/resume follows Pi's canonical branch; the audit
 * ledger is never used to restore a runtime override. */
export function readChatSettings(entries: readonly SessionEntry[]): Record<string, unknown> {
  const entry = entries.findLast(entry => entry.type === "custom" && entry.customType === CHAT_SETTINGS_ENTRY);
  if (!entry || entry.type !== "custom") return {};
  const data = entry.data as { settings?: unknown } | null;
  if (!data?.settings || typeof data.settings !== "object" || Array.isArray(data.settings)) {
    throw new GatewayError("conflict", "Canonical Chat settings are invalid");
  }
  return structuredClone(data.settings) as Record<string, unknown>;
}

/** Directional request values are branch-local timing snapshots, not explicit
 * overrides. A lower layer can narrow them live but cannot silently widen them. */
export function readChatRequestPins(entries: readonly SessionEntry[]): Record<string, FixedSetting> {
  return readChatSnapshots(entries, "requestPins");
}

export function readChatFixedSettings(entries: readonly SessionEntry[]): Record<string, FixedSetting> {
  return readChatSnapshots(entries, "fixed");
}

function readChatSnapshots(entries: readonly SessionEntry[], field: "fixed" | "requestPins"): Record<string, FixedSetting> {
  const entry = entries.findLast(entry => entry.type === "custom" && entry.customType === CHAT_SETTINGS_ENTRY);
  if (!entry || entry.type !== "custom") return {};
  const snapshots = (entry.data as Record<string, unknown> | null)?.[field];
  if (snapshots === undefined) return {};
  if (!snapshots || typeof snapshots !== "object" || Array.isArray(snapshots)) throw new GatewayError("conflict", "Canonical Chat snapshots are invalid");
  for (const value of Object.values(snapshots)) {
    if (!value || typeof value !== "object" || typeof value.at !== "string" || !Number.isFinite(Date.parse(value.at))
      || typeof value.ref !== "string" || !value.ref
      || !["builtin", "mac", "project", "profile", "chat", "delegate"].includes(value.from)
      || (value.via !== undefined && !["home-profile:sameAs:home", "home-profile", "home-explicit", "home-fallback"].includes(value.via))
      || (value.reason !== undefined && (typeof value.reason !== "string" || value.reason.length > 1024))) {
      throw new GatewayError("conflict", "Canonical Chat provenance is invalid");
    }
  }
  return structuredClone(snapshots) as Record<string, FixedSetting>;
}

/** The schema owns paths; callers cannot name an arbitrary SDK field. Undefined
 * deletes a Chat override, so the next request follows the resolver again. */
export function changeChatSetting(settings: Record<string, unknown>, id: string, value: unknown): Record<string, unknown> {
  const key = schemaKey(id);
  const binding = key.layers.chat;
  if (!hasChatSettingsApplier(key) || binding?.store !== "chat-settings") {
    throw new GatewayError("unsupported", "This setting has no live Chat applier");
  }
  const next = structuredClone(settings);
  let current = next;
  const parents: Array<{ value: Record<string, unknown>; field: string }> = [];
  for (const field of binding.path.slice(0, -1)) {
    parents.push({ value: current, field });
    const child = current[field];
    current = current[field] = child && typeof child === "object" && !Array.isArray(child)
      ? child as Record<string, unknown> : {};
  }
  const field = binding.path.at(-1)!;
  if (value === undefined) delete current[field]; else current[field] = value;
  for (const parent of parents.reverse()) {
    const child = parent.value[parent.field] as Record<string, unknown>;
    if (Object.keys(child).length === 0) delete parent.value[parent.field];
  }
  return next;
}
