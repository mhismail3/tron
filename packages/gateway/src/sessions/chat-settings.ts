import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { hasRuntimeRunApplier, schemaKey } from "../admin/settings-schema.js";

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

/** The schema owns paths; callers cannot name an arbitrary SDK field. Undefined
 * deletes a Chat override, so the next request follows the resolver again. */
export function changeChatSetting(settings: Record<string, unknown>, id: string, value: unknown): Record<string, unknown> {
  const key = schemaKey(id);
  const binding = key.layers.chat;
  if (!hasRuntimeRunApplier(key) || binding?.store !== "chat-settings") {
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
