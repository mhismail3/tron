import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { clampThinkingLevel, getSupportedThinkingLevels, type Model, type ThinkingLevel } from "@earendil-works/pi-ai";
import { SettingsManager, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { TrustService } from "./trust-service.js";
import { resolveSettings, targetLayers, type ChatStore, type OptionSources, type Resolution, type SettingsStores, type SettingsTarget } from "./settings-resolver.js";
import type { FormatContext } from "./settings-types.js";

/** What a session target contributes: its Chat layer and whether it is Home's chat. */
export interface SessionSettingsSource {
  cwd: string;
  home: boolean;
  chat: ChatStore;
  modelRuntime: ModelRuntime;
}

export interface SettingsModelDependencies {
  agentDir: string;
  tronHome: string;
  trust: Pick<TrustService, "inspect" | "canonicalDirectory">;
  modelRuntime: ModelRuntime;
  /** The Home record's memory model; Home owns it (doc 6.1). */
  homeMemoryModel?: () => Promise<{ provider: string; id: string } | undefined>;
}

/**
 * The settings model's read side: loads each store a target's layers read,
 * from its owner, and resolves (docs/settings-model.md section 3).
 * Reading an untrusted project's `.pi/settings.json` is pure JSON parsing.
 */
export class SettingsModel {
  constructor(private readonly dependencies: SettingsModelDependencies) {}

  get profilePath(): string {
    return join(this.dependencies.tronHome, "gateway", "home", "profile.json");
  }

  async resolve(target: SettingsTarget, session?: SessionSettingsSource, keys?: readonly string[]): Promise<Resolution> {
    const stores = await this.stores(target, session);
    const runtime = session?.modelRuntime ?? this.dependencies.modelRuntime;
    return resolveSettings(target, stores, { format: formatContext(runtime), options: optionSources(runtime), ...(keys ? { keys } : {}) });
  }

  async stores(target: SettingsTarget, session?: SessionSettingsSource): Promise<SettingsStores> {
    if (target.kind === "session" && !session) throw new GatewayError("invalid_request", "A session target needs its session");
    const mac = this.piDocuments(this.dependencies.agentDir).global;
    const trust = await this.trustDecisions();
    let project: SettingsStores["project"];
    const cwd = target.kind === "project" ? target.cwd : target.kind === "session" && !session!.home ? session!.cwd : undefined;
    if (cwd !== undefined) {
      // The Project store is `.pi/` at the cwd Tron gives pi, which is where pi
      // reads it (pi settings-manager has no upward search).
      const inspection = await this.dependencies.trust.inspect(cwd);
      project = {
        root: inspection.cwd,
        document: this.piDocuments(inspection.cwd).project,
        applied: inspection.effectiveDecision === true,
        ...(inspection.effectiveDecision === true ? {} : { reason: "untrusted" as const }),
      };
    }
    const home = target.kind === "home" || (target.kind === "session" && session!.home);
    const layers = targetLayers(target, { home, project: project !== undefined });
    return {
      layers,
      mac,
      trust,
      ...(project ? { project } : {}),
      ...(session ? { chat: session.chat } : {}),
      ...(home ? { profile: await readJsonObject(this.profilePath) } : {}),
      ...(home && this.dependencies.homeMemoryModel ? await this.homeMemory() : {}),
    };
  }

  private async homeMemory(): Promise<{ homeMemory?: { provider: string; id: string } }> {
    const model = await this.dependencies.homeMemoryModel!();
    return model ? { homeMemory: model } : {};
  }

  /** pi's own reader, so migrations and parse rules match the runtime exactly. */
  private piDocuments(cwd: string): { global: Record<string, unknown>; project: Record<string, unknown> } {
    const manager = SettingsManager.create(cwd, this.dependencies.agentDir, { projectTrusted: true });
    if (manager.drainErrors().length) throw new GatewayError("conflict", "Canonical settings could not be loaded");
    return {
      global: manager.getGlobalSettings() as Record<string, unknown>,
      project: cwd === this.dependencies.agentDir ? {} : manager.getProjectSettings() as Record<string, unknown>,
    };
  }

  private async trustDecisions(): Promise<Record<string, boolean>> {
    const document = await readJsonObject(join(this.dependencies.agentDir, "trust.json"));
    const result: Record<string, boolean> = {};
    for (const [path, decision] of Object.entries(document)) {
      if (typeof decision === "boolean") result[path] = decision;
    }
    return result;
  }
}

async function readJsonObject(path: string): Promise<Record<string, unknown>> {
  let raw: string;
  try {
    raw = await readFile(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw error;
  }
  try {
    const value = JSON.parse(raw.replace(/^\uFEFF/u, "")) as unknown;
    return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {};
  } catch {
    throw new GatewayError("conflict", "A settings store could not be parsed");
  }
}

export function formatContext(runtime: ModelRuntime): FormatContext {
  return { modelName: (ref) => runtime.getModel(ref.provider, ref.id)?.name };
}

/** Named option sources (doc 4.1 `optionsSource`). Capability clamping uses
 * pi's own `clampThinkingLevel`, so this names existing behaviour (doc 3.6). */
export function optionSources(runtime: ModelRuntime): OptionSources {
  return {
    clamp(source, dependency, value) {
      if (source !== "catalog.thinkingLevels") return value;
      const ref = dependency as { provider: string; id: string } | undefined;
      const model = ref && runtime.getModel(ref.provider, ref.id) as Model<any> | undefined;
      if (!model || typeof value !== "string") return value;
      return getSupportedThinkingLevels(model).includes(value as ThinkingLevel) ? value : clampThinkingLevel(model, value as ThinkingLevel);
    },
  };
}
