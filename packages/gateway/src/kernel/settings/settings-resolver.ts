import { type SettingsTarget, type Badge, type LayerValue, type ResolvedKey, type Resolution, type Qualifiers } from "./tool-contract.js";
import { dirname, join } from "node:path";
import { keyForHome, keyDefault, type SettingsSchema, type Binding, type KeyDeclaration } from "./settings-schema.js";
import { LAYER_LABELS, type FormatContext, type StoreLayer, type SettingsStores, type ResolveOptions } from "./settings-types.js";
import { canonicalSettingsTarget, scopeAdmitted, scopeForStore, instanceId } from "./scope-resolution.js";
import { projectSettingPath, projectSettingsDiagnostics } from "./settings-project-diagnostics.js";















const BOTTOM_UP: readonly StoreLayer[] = ["default", "global", "home", "session", "project"];

export function readPath(document: unknown, path: readonly string[]): unknown {
  let current: unknown = document;
  for (const segment of path) {
    if (typeof current !== "object" || current === null || Array.isArray(current)) return undefined;
    if (!Object.prototype.hasOwnProperty.call(current, segment)) return undefined;
    current = (current as Record<string, unknown>)[segment];
  }
  return current;
}

function fill(path: readonly string[], qualifiers: Qualifiers): readonly string[] | undefined {
  if (path.includes("{model}") && !qualifiers.model) return undefined;
  return path.map(segment => segment === "{model}" ? qualifiers.model! : segment);
}

function piDocument(stores: SettingsStores, layer: StoreLayer): Record<string, unknown> | undefined {
  return layer === "global" ? stores.global : layer === "project" ? stores.project?.document : undefined;
}

/** Read one layer's raw value for a key instance from that layer's store. */
export function readBinding(stores: SettingsStores, layer: StoreLayer, binding: Binding, qualifiers: Qualifiers, qualifiedOnly: boolean, keyId?: string): unknown {
  switch (binding.store) {
    case "pi": {
      const document = piDocument(stores, layer);
      const path = fill(qualifiedOnly ? binding.qualified ?? [] : binding.path, qualifiers);
      if (!path || path.length === 0) return undefined;
      return readPath(document, path);
    }
    case "pi-model-ref": {
      if (qualifiedOnly) return undefined;
      const document = piDocument(stores, layer);
      const provider = document?.defaultProvider;
      const id = document?.defaultModel;
      return typeof provider === "string" && typeof id === "string" ? { provider, id } : undefined;
    }
    case "session": {
      const chat = stores.session;
      if (!chat) return undefined;
      if (binding.field === "model") return qualifiedOnly ? undefined : chat.model;
      if (binding.field === "thinking") return chat.thinking;
      if (binding.field === "tools") return qualifiedOnly ? undefined : chat.tools;
      return chat.contextWindow && chat.contextWindow.model === qualifiers.model ? chat.contextWindow.value : undefined;
    }
    case "session-settings":
      return qualifiedOnly ? undefined : (keyId && stores.session?.requestPins?.[keyId] !== undefined
        ? stores.session.requestPins[keyId].value : keyId && stores.session?.fixed?.[keyId] ? stores.session.fixed[keyId].value : readPath(stores.session?.settings, binding.path));
    case "session-launch":
      return qualifiedOnly || !keyId ? undefined : stores.session?.fixed?.[keyId]?.value;
    case "home":
      return qualifiedOnly ? undefined : readPath(stores.home, binding.path);
    case "trust":
      return qualifiers.project === undefined ? undefined : nearestTrustDecision(stores.trust, qualifiers.project);
    case "mac-terminal":
      return qualifiers.device === undefined ? undefined : stores.macTerminal[qualifiers.device];
    case "mac-terminal-service":
      return stores.macTerminalServerEnabled ?? false;
    case "gateway":
      return qualifiedOnly || layer !== "global" ? undefined : readPath(stores.gateway, binding.path);
  }
}

/** pi's trust rule (ProjectTrustStore): the nearest saved decision on the path
 * or one of its parents covers it, so the row shows what actually applies. */
function nearestTrustDecision(decisions: Record<string, boolean>, project: string): boolean | undefined {
  for (let current = project; ; current = dirname(current)) {
    if (Object.prototype.hasOwnProperty.call(decisions, current)) return decisions[current];
    if (dirname(current) === current) return undefined;
  }
}

/** A composing key's value from the layers below `layer`: what that layer's
 * entries are relative to. */
export function composedBelow(stores: SettingsStores, key: KeyDeclaration, qualifiers: Qualifiers, layer: StoreLayer): unknown {
  let value = keyDefault(key, qualifiers);
  for (const below of BOTTOM_UP.slice(1, BOTTOM_UP.indexOf(layer))) {
    const binding = key.layers[below as Exclude<StoreLayer, "default">];
    if (!binding || !scopeAdmitted(key, below) || !stores.layers.includes(below) || !layerApplied(stores, below).applied) continue;
    const entry = readBinding(stores, below, binding, qualifiers, false, key.id);
    if (entry !== undefined) value = key.type.compose ? key.type.compose(value, entry) : entry;
  }
  return value;
}

function layerApplied(stores: SettingsStores, layer: StoreLayer): { applied: boolean; reason?: "untrusted" } {
  if (layer === "project" && stores.project && !stores.project.applied) return { applied: false, reason: "untrusted" };
  return { applied: true };
}

/** Resolve every key (or the requested ones) for a target. */
export function resolveSettings(schema: SettingsSchema, target: SettingsTarget, stores: SettingsStores, options: ResolveOptions): Resolution {
  const diagnostics = stores.project
    ? projectSettingsDiagnostics(schema, stores.project.document, join(stores.project.root, ".pi", "settings.json")) : { diagnostics: [] };
  const applicable = schema.KEYS.map(key => keyForHome(key, stores.layers.includes("home")));
  const keys = options.keys ? applicable.filter(key => options.keys!.includes(key.id)) : applicable;
  const resolved: ResolvedKey[] = [];
  // Model-qualified keys resolve for the target's effective chat model, which
  // is itself an ordinary key; resolve it first.
  const chatModelKey = applicable.find(key => key.id === "model.ref[role=chat]")!;
  const noDependencies = () => undefined;
  const chatModel = resolveInstance(schema, chatModelKey, chatModelKey.fixed ?? {}, stores, options, noDependencies).value as { provider: string; id: string } | undefined;
  // Dependencies are ordinary keys resolved for the same target (doc 7.5).
  const dependencyValue = (id: string) => id === chatModelKey.id ? chatModel
    : resolveInstance(schema, keyForHome(schema.schemaKey(id), stores.layers.includes("home")), schema.schemaKey(id).fixed ?? {}, stores, options, noDependencies).value;
  const modelQualifier = chatModel ? `${chatModel.provider}/${chatModel.id}` : undefined;

  for (const key of keys) {
    // A key belongs to a target that has at least one of its allowed layers
    // (doc 3.3): Home-only profile keys never appear on an ordinary chat.
    if (target.kind === "session" && !stores.layers.includes("home") && key.layers.home && !key.layers.session) continue;
    if (!Object.keys(key.layers).some(layer => stores.layers.includes(layer as StoreLayer) && scopeAdmitted(key, layer as StoreLayer))) continue;
    for (const qualifiers of instances(schema, key, target, stores, modelQualifier)) {
      resolved.push(resolveInstance(schema, key, qualifiers, stores, options, dependencyValue));
    }
  }
  const projectNotice = stores.project && (stores.project.unreadable || (!stores.project.applied && Object.keys(stores.project.document).length))
    ? { file: join(stores.project.root, ".pi", "settings.json"), message: stores.project.unreadable
      ? "Project settings couldn't be read" : "Project settings aren't applied until this project is trusted" } : undefined;
  return { target: canonicalSettingsTarget(target, stores.layers.includes("home")), layers: [...new Set(stores.layers.map(scopeForStore))], ...(stores.project?.unreadable ? { projectUnreadable: true as const } : {}),
    ...(projectNotice ? { projectNotice } : {}), keys: resolved, ...diagnostics };
}

function instances(schema: SettingsSchema, key: KeyDeclaration, target: SettingsTarget, stores: SettingsStores, model: string | undefined): Qualifiers[] {
  const fixed = { ...(key.fixed ?? {}) } as Qualifiers;
  if (key.qualifier === "model") {
    const onlyQualified = Object.values(key.layers).some(binding => binding.store === "pi" && binding.path.includes("{model}"));
    if (target.kind === "project" || target.kind === "global") {
      // Repository inspection includes non-default models, not an inherited snapshot.
      const models = new Set<string>();
      if (target.kind === "global" && model) models.add(model);
      const layer = target.kind === "project" ? "project" : "global";
      const binding = key.layers[layer];
      if (binding?.store === "pi") {
        const path = binding.qualified ?? binding.path;
        const position = path.indexOf("{model}");
        const container = position < 0 ? undefined : readPath(piDocument(stores, layer), path.slice(0, position));
        if (container && typeof container === "object" && !Array.isArray(container)) {
          for (const name of Object.keys(container)) if (name.includes("/")) models.add(name);
        }
      }
      return [...(onlyQualified ? [] : [fixed]), ...[...models].sort().map(model => ({ ...fixed, model }))];
    }
    return model ? [{ ...fixed, model }] : onlyQualified ? [] : [fixed];
  }
  if (key.qualifier === "device") {
    // Global policy: the enrolled iPhones appear on the Mac target only.
    return target.kind === "global" ? Object.keys(stores.macTerminal).sort().map(device => ({ ...fixed, device })) : [];
  }
  if (key.qualifier === "project") {
    if (target.kind === "project" || target.kind === "session") return stores.project ? [{ ...fixed, project: stores.project.root }] : [];
    return Object.keys(stores.trust).sort().map(project => ({ ...fixed, project }));
  }
  return [fixed];
}

export function resolveInstance(
  schema: SettingsSchema,
  key: KeyDeclaration,
  qualifiers: Qualifiers,
  stores: SettingsStores,
  options: ResolveOptions,
  dependencyValue: (id: string) => unknown,
): ResolvedKey {
  const format = (value: unknown) => key.redacted ? (value === undefined || value === "" ? "Not set" : "Set")
    : value === undefined ? "Not set" : key.type.format(value, options.format);
  const layerValues: LayerValue[] = [];
  const read = (qualifiedOnly: boolean) => {
    const found: Array<{ layer: StoreLayer; value: unknown; applied: boolean; reason?: "untrusted" }> = [];
    for (const layer of BOTTOM_UP) {
      if (layer === "default" || !stores.layers.includes(layer)) continue;
      const binding = key.layers[layer as Exclude<StoreLayer, "default">];
      if (!binding || !scopeAdmitted(key, layer)) continue;
      const value = readBinding(stores, layer, binding, qualifiers, qualifiedOnly, key.id);
      if (value === undefined) continue;
      found.push({ layer, value, ...layerApplied(stores, layer) });
    }
    return found;
  };
  const qualified = read(true);
  const unqualified = read(false);
  // Scope outranks specificity. A model override wins only over the plain
  // value in its own scope, never over a higher Session/Project/Home value.
  const shown = BOTTOM_UP.flatMap(layerId => {
    const entry = qualified.find(candidate => candidate.layer === layerId) ?? unqualified.find(candidate => candidate.layer === layerId);
    return entry ? [entry] : [];
  });
  const present = shown;

  const defaultValue = keyDefault(key, qualifiers);
  let value: unknown = defaultValue;
  let layer: StoreLayer = "default";
  for (const entry of present) {
    if (!entry.applied) continue;
    value = key.type.compose ? key.type.compose(value, entry.value) : entry.value;
    layer = entry.layer;
  }
  const top = shown[shown.length - 1];
  const notApplied = top && !top.applied ? top : undefined;

  for (const layerId of [...BOTTOM_UP].reverse()) {
    if (!stores.layers.includes(layerId) && layerId !== "default") continue;
    if (layerId === "default") continue;
    if (!key.layers[layerId] || !scopeAdmitted(key, layerId)) continue;
    // Only the Home chat has the Home recipe (doc 3.3); it has no Chat compaction layer.
    const entry = shown.find(candidate => candidate.layer === layerId);
    layerValues.push(entry
      ? { layer: scopeForStore(layerId), value: entry.value, display: format(entry.value), applied: entry.applied, ...(entry.reason ? { reason: entry.reason } : {}) }
      : { layer: scopeForStore(layerId), applied: true });
  }

  const badges: Badge[] = [];
  // A per-model value is the one for this chat's model, named as the picker names it.
  if (qualifiers.model && key.qualifier === "model") badges.push({ kind: "scope", label: `For ${modelDisplayName(qualifiers.model, options.format)}`, detail: qualifiers.model });
  if (qualifiers.project && key.qualifier === "project") badges.push({ kind: "scope", label: qualifiers.project });
  if (notApplied) {
    badges.push({ kind: "state", label: "Not applied (untrusted)", detail: `${LAYER_LABELS[scopeForStore(notApplied.layer)]}: ${format(notApplied.value)}`,
      action: { kind: "reviewTrust", label: "Review trust" } });
  }
  badges.push(...storeStateBadges(key, qualifiers, stores, format));
  // Capability clamping (doc 3.6): a value its dependency does not support
  // resolves to the closest supported one, named by a Clamped badge.
  if (key.optionsSource && value !== undefined && layer !== "session") {
    const dependency = key.optionsSource.dependsOn.length ? dependencyValue(key.optionsSource.dependsOn[0]!) : undefined;
    if (dependency !== undefined) {
      const selectedDependency = qualifiers.model && key.optionsSource.dependsOn[0] === "model.ref[role=chat]"
        ? { provider: qualifiers.model.slice(0, qualifiers.model.indexOf("/")), id: qualifiers.model.slice(qualifiers.model.indexOf("/") + 1) } : dependency;
      const clamped = options.options.clamp(key.optionsSource.name, selectedDependency, value);
      if (clamped !== value) {
        badges.push({ kind: "state", label: "Clamped", detail: `${format(value)} is not supported; using ${format(clamped)}` });
        value = clamped;
      }
    }
  }
  if (key.redacted) badges.push({ kind: "state", label: "Not undoable" });
  const candidate = stores.session?.fixed?.[key.id] ?? stores.session?.requestPins?.[key.id];
  const fixedAt = layer === "session" && candidate && JSON.stringify(candidate.value) === JSON.stringify(value)
    && (!candidate.qualifiers?.model || candidate.qualifiers.model === qualifiers.model) ? candidate : undefined;
  if (fixedAt) {
    const binding = key.layers.session;
    const requested = binding?.store === "session-settings" ? readPath(stores.session?.settings, binding.path) : undefined;
    if (requested !== undefined && JSON.stringify(requested) !== JSON.stringify(value)) {
      badges.push({ kind: "state", label: "Applies to a new chat", detail: `Requested: ${format(requested)}` });
    }
  }

  const localLayer = stores.layers.includes("home") ? "home" : stores.layers.includes("session") ? "session" : "global";
  const localBinding = key.layers[localLayer];
  const localValue = !scopeAdmitted(key, localLayer) ? undefined : localBinding?.store === "session-settings" ? readPath(stores.session?.settings, localBinding.path)
    : localBinding ? readBinding(stores, localLayer, localBinding, qualifiers, localBinding.store === "pi" && !!localBinding.qualified && !!qualifiers.model, key.id) : undefined;
  const projectValue = shown.find(entry => entry.layer === "project" && entry.applied);
  const binding = key.layers.project;
  const projectPath = binding?.store === "pi-model-ref" ? "defaultProvider + defaultModel" : binding?.store === "pi"
    ? projectSettingPath((qualified.some(entry => entry.layer === "project") ? binding.qualified! : binding.path)
      .map(segment => segment === "{model}" ? qualifiers.model! : segment)) : undefined;
  return {
    key: key.id,
    ...(Object.keys(qualifiers).length ? { qualifiers } : {}),
    group: key.group,
    ...(key.subgroup ? { subgroup: key.subgroup } : {}),
    value: key.redacted ? undefined : value,
    display: value !== undefined && key.type.summary ? key.type.summary(value) : format(value),
    layer: scopeForStore(layer),
    applied: !notApplied,
    ...(notApplied ? { reason: notApplied.reason } : {}),
    badges,
    ...(fixedAt ? { fixedAt } : {}),
    overridden: localValue !== undefined,
    ...(projectValue && projectPath && stores.project ? { projectSetting: { file: join(stores.project.root, ".pi", "settings.json"), path: projectPath } } : {}),
    layers: key.redacted ? layerValues.map(({ value: _value, ...rest }) => rest) : layerValues,
  };
}

/** A `provider/id` model qualifier's display name, or the qualifier itself. */
function modelDisplayName(qualifier: string, format: FormatContext): string {
  const slash = qualifier.indexOf("/");
  return (slash > 0 ? format.modelName({ provider: qualifier.slice(0, slash), id: qualifier.slice(slash + 1) }) : undefined) ?? qualifier;
}

/** Store-state badges (doc 5.6, 5.7): a Project value's git state, and a value
 * changed outside Tron with Apply again where it replaced a value Tron wrote. */
function storeStateBadges(key: KeyDeclaration, qualifiers: Qualifiers, stores: SettingsStores, format: (value: unknown) => string): Badge[] {
  const badges: Badge[] = [];
  const projectBinding = key.layers.project;
  const git = stores.project?.git;
  if (projectBinding && git && stores.layers.includes("project")) {
    const at = (document: Record<string, unknown>) => {
      const view = { ...stores, project: { ...stores.project!, document } };
      return readBinding(view, "project", projectBinding, qualifiers, true, key.id) ?? readBinding(view, "project", projectBinding, qualifiers, false, key.id);
    };
    const working = at(stores.project!.document);
    if (git.kind === "local") {
      if (working !== undefined) badges.push({ kind: "state", label: "Local only", detail: `Project: ${git.reason}` });
    } else {
      const committed = at(git.head ?? {});
      if (JSON.stringify(working ?? null) !== JSON.stringify(committed ?? null)) {
        const staged = JSON.stringify(at(git.index ?? {}) ?? null) === JSON.stringify(working ?? null);
        badges.push({ kind: "state", label: staged ? "Staged" : "Uncommitted", detail: `Project: ${format(working)}; committed: ${format(committed)}` });
      }
    }
  }
  for (const layer of ["project", "global"] as const) {
    if (!stores.layers.includes(layer) || !key.layers[layer]) continue;
    const marks = stores.outside?.[layer];
    const mark = marks?.[instanceId(key.id, qualifiers)] ?? marks?.[instanceId(key.id, key.fixed ?? {})];
    if (!mark) continue;
    badges.push({ kind: "state", label: "Changed outside Tron", detail: `${LAYER_LABELS[scopeForStore(layer)]}: ${mark.before} → ${mark.after}`,
      ...(mark.applyAgain ? { action: { kind: "applyAgain", label: "Apply again", changeId: mark.changeId } } : {}) });
  }
  return badges;
}

/** The layers a target has (doc 3.3): a target has a layer when it has its store. */
export function targetLayers(target: SettingsTarget, options: { home?: boolean; project?: boolean }): readonly StoreLayer[] {
  switch (target.kind) {
    case "global": return ["global", "default"];
    case "project": return ["project", "global", "default"];
    case "home": return ["home", "global", "default"];
    case "session": return options.home
      ? ["home", "global", "default"]
      : options.project === false ? ["session", "global", "default"] : ["project", "session", "global", "default"];
  }
}
