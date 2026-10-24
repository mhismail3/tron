import { randomUUID } from "node:crypto";
import type { ModelRuntime, SettingsManager } from "../pi/coding-agent.js";
import type { FixedSetting, Resolution, SettingsTarget, Qualifiers } from "./tool-contract.js";
import { resolveSettings } from "./settings-resolver.js";
import { hasRuntimeRequestApplier, timingFor, type SettingsSchema, type Binding } from "./settings-schema.js";
import type { SessionStore, SettingsStores, ResolveOptions } from "./settings-types.js";

/** What a session target contributes: its Session scope and whether it is Home's chat. */
export interface SessionSettingsSource {
  cwd: string;
  home: boolean;
  session: SessionStore;
  modelRuntime: ModelRuntime;
}

export interface SettingsOptionsRequest {
  key: string;
  qualifiers?: Qualifiers;
  query?: string;
  cursor?: string;
  limit?: number;
}

export interface SettingsOption { value: unknown; label: string; detail?: string; disabledReason?: string; resource?: Record<string, unknown> }

export interface SettingsOptionsResult {
  key: string;
  /** The key's option source, or `static` for its declared choices. */
  source: string;
  dependsOn: string[];
  options: SettingsOption[];
  range?: { min: number; max: number; unit: "tokens" };
  /** An opaque cursor for the next page of a catalog. */
  nextCursor?: string;
}


/** Store/catalog I/O stays with its adapter; precedence and request pins belong here. */
export interface SettingsReadOwner {
  readonly schema: SettingsSchema;
  readonly modelRuntime: ModelRuntime;
  /** Admission uses the active SDK runtime, not the adapter’s catalog runtime. */
  readonly admitModelChoice: (runtime: ModelRuntime, provider: string, id: string) => Promise<void>;
  stores(target: SettingsTarget, session?: SessionSettingsSource, options?: { storeState?: boolean }): Promise<SettingsStores>;
  resolveOptions(runtime: ModelRuntime): Pick<ResolveOptions, "format" | "options">;
  options(target: SettingsTarget, session: SessionSettingsSource | undefined, request: SettingsOptionsRequest, resolve: (keys: readonly string[]) => Promise<Resolution>): Promise<SettingsOptionsResult>;
}

export class SettingsModel<Owner extends SettingsReadOwner = SettingsReadOwner> {
  constructor(readonly owner: Owner) {}
  get schema(): SettingsSchema { return this.owner.schema; }

  async resolve(target: SettingsTarget, session?: SessionSettingsSource, keys?: readonly string[], options: { storeState?: boolean } = {}): Promise<Resolution> {
    const stores = await this.owner.stores(target, session, options);
    const runtime = session?.modelRuntime ?? this.owner.modelRuntime;
    return resolveSettings(this.schema, target, stores, { ...this.owner.resolveOptions(runtime), ...(keys ? { keys } : {}) });
  }

  /** Resolve operational defaults at a request boundary, never by reloading the
   * whole SDK manager (which would also change fixed resource/shell settings).
   * Absence is meaningful for optional provider fields: the request boundary
   * replaces them after the SDK has composed its initial defaults. */
  async requestSettings(sessionId: string, session: SessionSettingsSource, previousPins: Record<string, FixedSetting>): Promise<{
    settings: ReturnType<SettingsManager["getSettings"]>; requestPins: Record<string, FixedSetting>; admission: Resolution["keys"];
  }> {
    const keys = this.schema.KEYS.filter(hasRuntimeRequestApplier);
    // The provider-request boundary reads values only: outside comparison and git
    // state belong to settings reads and file events, not to every model request.
    const resolved = await this.resolve({ kind: "session", sessionId }, session, [...keys.map(key => key.id), "model.ref[role=chat]", "model.thinking[role=chat]"], { storeState: false });
    const settings: Record<string, unknown> = {};
    const requestPins = structuredClone(previousPins);
    for (const row of resolved.keys) {
      const key = this.schema.schemaKey(row.key);
      const binding = key.layers.session;
      if (binding?.store !== "session-settings") continue;
      let value = row.value;
      if (typeof key.timing !== "string") {
        const previous = previousPins[key.id];
        if (previous && key.direction && timingFor(key, key.direction(previous.value, value)) === "fixed") value = previous.value;
        if (!previous || !deepEqual(previous.value, value)) requestPins[key.id] = {
          value, from: row.layer, at: new Date().toISOString(), ref: randomUUID(), ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}),
        };
      }
      if (value !== undefined) setPath(settings, binding.path, await key.type.validate(value, key.id));
    }
    return { settings, requestPins, admission: resolved.keys.filter(row => row.key === "model.ref[role=chat]" || row.key === "model.thinking[role=chat]") };
  }

  options(target: SettingsTarget, session: SessionSettingsSource | undefined, request: SettingsOptionsRequest): Promise<SettingsOptionsResult> {
    return this.owner.options(target, session, request, keys => this.resolve(target, session, keys));
  }
}

export const deepEqual = (left: unknown, right: unknown) => JSON.stringify(left ?? null) === JSON.stringify(right ?? null);

/** A change qualified by model writes the binding's per-model path when it has one. */
export function qualifiedWrite(binding: Binding, qualifiers: Qualifiers): boolean {
  return binding.store === "pi" && binding.qualified !== undefined && qualifiers.model !== undefined;
}

export function fillPath(path: readonly string[], qualifiers: Qualifiers): string[] {
  return path.map(segment => segment === "{model}" ? qualifiers.model! : segment);
}


export function setPath(document: Record<string, unknown>, path: readonly string[], value: unknown): void {
  let current = document;
  for (const segment of path.slice(0, -1)) {
    const child = current[segment];
    current = current[segment] = child && typeof child === "object" && !Array.isArray(child) ? child as Record<string, unknown> : {};
  }
  current[path[path.length - 1]!] = value;
}

/** Unset a value and drop parents it leaves empty. */
export function unsetPath(document: Record<string, unknown>, path: readonly string[]): void {
  const parents: Array<Record<string, unknown>> = [];
  let current: unknown = document;
  for (const segment of path.slice(0, -1)) {
    if (!current || typeof current !== "object") return;
    parents.push(current as Record<string, unknown>);
    current = (current as Record<string, unknown>)[segment];
  }
  if (!current || typeof current !== "object") return;
  delete (current as Record<string, unknown>)[path[path.length - 1]!];
  for (let index = parents.length - 1; index >= 0; index -= 1) {
    const child = parents[index]![path[index]!];
    if (child && typeof child === "object" && Object.keys(child).length === 0) delete parents[index]![path[index]!];
  }
}
