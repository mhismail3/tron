import type { AgentSession, SettingsManager } from "../kernel/pi/coding-agent.js";
import type { CompactionConfiguration } from "../protocol/types.js";
import { resolveSettings } from "../kernel/settings/settings-resolver.js";
import { type SettingsSchema } from "../kernel/settings/settings-schema.js";
import type { Resolution } from "../kernel/settings/tool-contract.js";
import { clampThinkingLevel, type Model, type ThinkingLevel } from "../kernel/pi/ai.js";
import { GatewayError } from "../errors.js";
import type { SettingsReadOwner } from "../kernel/settings/settings-model.js";

/** The compaction owner supplies its boundary snapshot; settings owns all
 * precedence/qualification, including the operation's model instance. */
export function compactionAdmission(schema: SettingsSchema, settings: SettingsManager, session: Record<string, unknown>, model?: string): CompactionConfiguration {
  const slash = model?.indexOf("/") ?? -1;
  const ref = model && slash > 0 ? { provider: model.slice(0, slash), id: model.slice(slash + 1) } : undefined;
  const fields = { enabled: "context.compaction.enabled", reserveTokens: "context.compaction.reserveTokens",
    keepRecentTokens: "context.compaction.keepRecentTokens", instructions: "context.compaction.instructions", thinkingLevel: "model.thinking[role=summarizer]" } as const;
  const result = resolveSettings(schema, { kind: "session", sessionId: "compaction" }, {
    layers: ["project", "session", "global", "default"], session: { settings: session, ...(ref ? { model: ref } : {}) },
    project: { root: "", document: settings.getProjectSettings() as Record<string, unknown>, applied: settings.isProjectTrusted() },
    global: settings.getGlobalSettings() as Record<string, unknown>, gateway: {}, floors: {}, trust: {}, macTerminal: {},
  }, { keys: Object.values(fields), format: { modelName: () => undefined }, options: { clamp: (_source, _dependency, value) => value } });
  const configuration: Record<string, unknown> = {}, source: Record<string, string> = {};
  for (const [field, key] of Object.entries(fields)) {
    const row = result.keys.find(row => row.key === key)!;
    try {
      const value = schema.schemaKey(key).type.validate(row.value, key);
      if (value instanceof Promise) throw new Error("Compaction validation must finish at its synchronous operation boundary");
      configuration[field] = value;
    } catch {
      throw new GatewayError("conflict", "Canonical compaction settings contain an invalid value");
    }
    source[field] = row.layer;
  }
  return { ...configuration, source } as unknown as CompactionConfiguration;
}

/** An admitted effective selection is not an edit to the stored override. The
 * SDK records the operational model; canonical fixed choice evidence continues
 * to own the inactive Session/delegated choice while Project masks it. */
export async function applyModelAdmission(session: AgentSession, rows: Resolution["keys"], physical: boolean,
  admitModelChoice: SettingsReadOwner["admitModelChoice"]): Promise<void> {
  const row = rows.find(row => row.key === "model.ref[role=chat]");
  const ref = row?.value as { provider: string; id: string } | undefined;
  const model = ref && (physical ? session.modelRuntime.getPhysicalModel(ref.provider, ref.id) : session.modelRuntime.getModel(ref.provider, ref.id));
  // A Session choice this runtime cannot serve stays the SDK's; a required
  // physical (Home, worker) or Project selection refuses rather than substitute.
  if (ref && !model && (physical || row?.layer === "project")) {
    throw new GatewayError("conflict", `${row?.layer === "project" ? "Project" : "Selected"} model ${ref.provider}/${ref.id} is unavailable for this session`);
  }
  if (ref && model) {
    if (row?.layer === "project") {
      await admitModelChoice(session.modelRuntime, ref.provider, ref.id);
      if (!(await session.modelRuntime.getAvailable()).some(candidate => candidate.provider === ref.provider && candidate.id === ref.id)) {
        throw new GatewayError("conflict", `Project model ${ref.provider}/${ref.id} is not available for this account`);
      }
    }
    if (session.model?.provider !== model.provider || session.model.id !== model.id) await session.setModel(model as Model<never>);
  }
  const thinking = rows.find(row => row.key === "model.thinking[role=chat]")?.value as ThinkingLevel | undefined;
  if (thinking && session.model) {
    const admitted = clampThinkingLevel(session.model, thinking);
    if (session.thinkingLevel !== admitted) session.setThinkingLevel(admitted);
  }
}
