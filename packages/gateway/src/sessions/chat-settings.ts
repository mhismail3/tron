import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { FixedSetting } from "../admin/settings-resolver.js";
import { hasRuntimeRequestApplier, schemaKey } from "../admin/settings-schema.js";

export const CHAT_SETTINGS_ENTRY = "tron.settings.v1";

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
      || !["builtin", "mac", "project", "profile", "chat", "delegate"].includes(value.from)) {
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
  if (!hasRuntimeRequestApplier(key) || binding?.store !== "chat-settings") {
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
