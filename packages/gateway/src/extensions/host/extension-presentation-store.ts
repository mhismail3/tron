import { randomUUID } from "node:crypto";
import { visibleWidth } from "@earendil-works/pi-tui";
import { GatewayError } from "../../errors.js";
import type {
  ExtensionInputLease,
  ExtensionInteraction,
  ExtensionQuestionnaireDescriptor,
  ExtensionPresentationDiagnostic,
  ExtensionPresentationMutation,
  ExtensionPresentationState,
  ExtensionSemanticState,
  ExtensionSurface,
  JsonValue,
} from "../../protocol/types.js";
import {
  EXTENSION_FRAME_MAX_BYTES,
  EXTENSION_FRAME_MAX_COLUMNS,
  EXTENSION_FRAME_MAX_LINES,
  EXTENSION_FRAME_MAX_RUNS,
} from "./frame-parser.js";
import { stripTerminalControls } from "./terminal-sanitizer.js";

export const EXTENSION_PRESENTATION_MAX_SURFACES = 64;
// Gateway's complete WebSocket frame is capped at 1 MiB. Keeping presentation
// below 700 KiB leaves room for session identity, actionable lifecycle state,
// and a bounded transcript tail in authoritative snapshots.
export const EXTENSION_PRESENTATION_MAX_BYTES = 700 * 1_024;
const MAX_DIAGNOSTICS = 64;
const MAX_CAPABILITIES = 128;
export const EXTENSION_MAX_STATUSES = 32;
export const EXTENSION_MAX_WIDGETS = 24;
export const EXTENSION_MAX_INTERACTIONS = 8;
export const EXTENSION_MAX_SELECT_OPTIONS = 64;
export const EXTENSION_MAX_WIDGET_LINES = 12;
const MAX_ID_BYTES = 512;
const MAX_KEY_BYTES = 256;
const MAX_TITLE_BYTES = 4 * 1_024;
const MAX_MESSAGE_BYTES = 32 * 1_024;
const MAX_OPTION_BYTES = 2 * 1_024;
const MAX_QUESTIONNAIRE_OPTIONS = 64;
const MAX_QUESTIONNAIRE_PREVIEW_BYTES = 32 * 1_024;
const MAX_STATUS_BYTES = 4 * 1_024;
const MAX_WORKING_BYTES = 8 * 1_024;
const MAX_WIDGET_LINE_BYTES = 512;
const MAX_INDICATOR_FRAMES = 32;
const MAX_INDICATOR_FRAME_BYTES = 256;
const MAX_INTERACTION_BYTES = 192 * 1_024;
const MAX_EDITOR_DIRECTIVE_BYTES = 192 * 1_024;
const MAX_NOTIFICATION_BYTES = 32 * 1_024;
const MAX_OWNER_ID_BYTES = 512;
const MAX_OWNER_TITLE_BYTES = 256;
const MAX_OWNER_SOURCE_BYTES = 512;

type PresentationBroadcast = (topic: "session.extensionPresentation", payload: JsonValue) => void;

export interface ExtensionHostActivity {
  readonly hasPendingInteraction: boolean;
  readonly hasPendingComponentFactory: boolean;
  readonly hasMountedPresentation: boolean;
  readonly hasInputLease: boolean;
  readonly hasScheduledRender: boolean;
  /** Blocking custom surfaces keep the owning runtime operationally live. */
  readonly hasBlockingPresentation: boolean;
  readonly hasRetainedPresentation: boolean;
}

function bytes(value: unknown): number { return Buffer.byteLength(JSON.stringify(value), "utf8"); }
function clone<T>(value: T): T { return structuredClone(value); }
function equal(left: unknown, right: unknown): boolean { return JSON.stringify(left) === JSON.stringify(right); }
function requireId(value: string, label: string): void {
  if (typeof value !== "string" || value.length === 0 || bytes(value) > MAX_ID_BYTES) {
    throw new GatewayError("conflict", `Extension presentation ${label} is invalid`);
  }
}
function frameRunCount(surface: ExtensionSurface): number {
  return surface.frame.lines.reduce((count, line) => count + line.runs.length, 0);
}
function hasUnsafeControl(value: string, preserveNewlines = false): boolean {
  return stripTerminalControls(value, preserveNewlines) !== value;
}
function boundedSafe(value: unknown, maximum: number, preserveNewlines = false): boolean {
  return typeof value === "string" && bytes(value) <= maximum && !hasUnsafeControl(value, preserveNewlines);
}
function validQuestionnaire(value: unknown): value is ExtensionQuestionnaireDescriptor {
  if (!value || typeof value !== "object") return false;
  const q = value as ExtensionQuestionnaireDescriptor;
  if (q.version !== 1 || typeof q.question !== "string" || q.question.length === 0 || !boundedSafe(q.question, MAX_MESSAGE_BYTES, true)
    || (q.context !== undefined && !boundedSafe(q.context, MAX_MESSAGE_BYTES, true))
    || !Array.isArray(q.options) || q.options.length === 0 || q.options.length > MAX_QUESTIONNAIRE_OPTIONS
    || typeof q.allowMultiple !== "boolean" || typeof q.allowFreeform !== "boolean") return false;
  const labels = new Set<string>();
  return q.options.every((option) => {
    if (!option || typeof option !== "object") return false;
    const item = option as ExtensionQuestionnaireDescriptor["options"][number];
    if (!boundedSafe(item.label, MAX_OPTION_BYTES) || item.label.length === 0 || !labels.add(item.label)
      || (item.description !== undefined && !boundedSafe(item.description, MAX_OPTION_BYTES, true))
      || (item.preview !== undefined && !boundedSafe(item.preview, MAX_QUESTIONNAIRE_PREVIEW_BYTES, true))) return false;
    return true;
  });
}
function validLink(value: string): boolean {
  if (value.length > 2_048 || hasUnsafeControl(value)) return false;
  try { return ["http:", "https:", "mailto:"].includes(new URL(value).protocol); } catch { return false; }
}
function validateSurface(surface: ExtensionSurface): void {
  if (typeof surface !== "object" || surface === null || typeof surface.frame !== "object" || surface.frame === null) {
    throw new GatewayError("conflict", "Extension presentation surface is malformed");
  }
  requireId(surface.id, "surface ID");
  if (surface.provenance && ((!surface.provenance.source || !boundedSafe(surface.provenance.source, MAX_OWNER_SOURCE_BYTES))
    || (surface.provenance.path !== undefined && !boundedSafe(surface.provenance.path, MAX_OWNER_SOURCE_BYTES)))) {
    throw new GatewayError("conflict", "Extension surface provenance is invalid");
  }
  const kinds = new Set(["header", "footer", "widget", "custom", "overlay", "editor", "toolRenderer", "messageRenderer", "entryRenderer", "markdown", "unknown"]);
  const placements = new Set(["header", "footer", "aboveEditor", "belowEditor", "transcript", "overlay", "fullscreen"]);
  if (!kinds.has(surface.kind) || !placements.has(surface.placement)
    || !new Set(["retained", "blocking", "transient", "restored"]).has(surface.lifecycle)
    || !new Set(["none", "keys", "textAndKeys"]).has(surface.inputMode)) {
    throw new GatewayError("conflict", "Extension presentation surface metadata is invalid");
  }
  if (!Number.isSafeInteger(surface.revision) || surface.revision < 1) throw new GatewayError("conflict", "Extension presentation surface revision is invalid");
  const frame = surface.frame;
  if (!Array.isArray(frame.lines) || frame.lines.some((line) => typeof line !== "object" || line === null || !Array.isArray(line.runs))) {
    throw new GatewayError("conflict", "Extension presentation surface frame is malformed");
  }
  if (!Number.isSafeInteger(frame.width) || frame.width < 1 || frame.width > EXTENSION_FRAME_MAX_COLUMNS
    || !Number.isSafeInteger(frame.height) || frame.height < 0 || frame.height > EXTENSION_FRAME_MAX_LINES
    || frame.lines.length !== frame.height || frameRunCount(surface) > EXTENSION_FRAME_MAX_RUNS
    || bytes(frame) > EXTENSION_FRAME_MAX_BYTES) {
    throw new GatewayError("conflict", "Extension presentation surface frame is invalid");
  }
  for (const line of frame.lines) {
    if (typeof line.plainText !== "string" || hasUnsafeControl(line.plainText) || visibleWidth(line.plainText) > frame.width || !Array.isArray(line.runs)
      || line.runs.map((run) => run.text).join("") !== line.plainText
      || line.runs.some((run) => {
        if (typeof run.text !== "string" || hasUnsafeControl(run.text) || typeof run.style !== "object" || run.style === null) return true;
        const style = run.style;
        const flags = [style.bold, style.dim, style.italic, style.underline, style.inverse, style.strike];
        return flags.some((value) => value !== undefined && value !== true)
          || [style.foreground, style.background].some((value) => value !== undefined && !/^#[0-9a-f]{6}$/iu.test(value))
          || (style.link !== undefined && !validLink(style.link));
      })) {
      throw new GatewayError("conflict", "Extension presentation surface frame is malformed");
    }
  }
  if (typeof frame.plainText !== "string" || hasUnsafeControl(frame.plainText.replaceAll("\n", ""))
    || frame.plainText !== frame.lines.map((line) => line.plainText).join("\n")
    || (surface.kind === "unknown" && frame.plainText.length === 0)
    || (frame.lines.length > 0 && frame.plainText.length === 0 && frame.lines.some((line) => line.plainText.length > 0))) {
    throw new GatewayError("conflict", "Extension presentation surface requires readable plain text");
  }
  if (frame.cursor && (!Number.isSafeInteger(frame.cursor.row) || !Number.isSafeInteger(frame.cursor.column)
    || frame.cursor.row < 0 || frame.cursor.row >= frame.height
    || frame.cursor.column < 0 || frame.cursor.column > frame.width)) {
    throw new GatewayError("conflict", "Extension presentation cursor is invalid");
  }
}

export interface ExtensionPresentationDraft {
  semanticState: ExtensionSemanticState;
  surfaces: ExtensionSurface[];
  pendingInteractions: ExtensionInteraction[];
  inputLease?: ExtensionInputLease;
  capabilities: string[];
  diagnostics: ExtensionPresentationDiagnostic[];
  notification?: { message: string; type: "info" | "warning" | "error" };
  editorDirective?: { action: "set" | "paste" | "native"; delta: string; operationId?: string };
}

const DEFAULT_SEMANTIC_STATE: ExtensionSemanticState = {
  statuses: {},
  statusOwners: {},
  working: { visible: true, indicator: { kind: "default", frames: [] } },
  widgets: [],
  toolsExpanded: false,
  editorRevision: 0,
  editorText: "",
};

/** Sole aggregate epoch/revision owner for semantic and rendered extension presentation. */
export class ExtensionPresentationStore implements ExtensionHostActivity {
  readonly hostEpoch = randomUUID();
  private revision = 0;
  private active = true;
  private semanticState = clone(DEFAULT_SEMANTIC_STATE);
  private surfaces: ExtensionSurface[] = [];
  private pendingInteractions: ExtensionInteraction[] = [];
  private inputLease: ExtensionInputLease | undefined;
  private capabilities: string[];
  private diagnostics: ExtensionPresentationDiagnostic[];
  private pendingComponentFactories = 0;
  private scheduledRenders = 0;

  constructor(
    private readonly broadcast: PresentationBroadcast,
    options: { capabilities?: string[]; diagnostics?: ExtensionPresentationDiagnostic[] } = {},
  ) {
    this.capabilities = [...(options.capabilities ?? [])];
    this.diagnostics = clone(options.diagnostics ?? []);
    this.validateState(this.draft());
  }

  get nextRevision(): number { return this.revision + 1; }
  get hasPendingInteraction(): boolean { return this.pendingInteractions.length > 0; }
  get hasPendingComponentFactory(): boolean { return this.pendingComponentFactories > 0; }
  get hasMountedPresentation(): boolean { return this.surfaces.length > 0; }
  get hasInputLease(): boolean { return this.inputLease !== undefined; }
  get hasScheduledRender(): boolean { return this.scheduledRenders > 0; }
  get hasBlockingPresentation(): boolean {
    return this.surfaces.some((surface) => surface.lifecycle === "blocking");
  }
  get hasRetainedPresentation(): boolean {
    const semantic = this.semanticState;
    return this.hasPendingInteraction || this.hasMountedPresentation || this.hasInputLease
      || Object.keys(semantic.statuses).length > 0 || semantic.widgets.length > 0
      || semantic.working.message !== undefined || !semantic.working.visible
      || semantic.working.indicator.kind !== "default" || semantic.hiddenThinkingLabel !== undefined
      || semantic.title !== undefined || semantic.editorText.length > 0 || semantic.toolsExpanded;
  }

  setPendingComponentFactories(count: number): void {
    this.assertActive();
    if (!Number.isSafeInteger(count) || count < 0) throw new GatewayError("conflict", "Extension component activity is invalid");
    this.pendingComponentFactories = count;
  }
  setScheduledRenders(count: number): void {
    this.assertActive();
    if (!Number.isSafeInteger(count) || count < 0) throw new GatewayError("conflict", "Extension render activity is invalid");
    this.scheduledRenders = count;
  }

  state(): ExtensionPresentationState {
    return {
      version: 2,
      hostEpoch: this.hostEpoch,
      revision: this.revision,
      capabilities: [...this.capabilities],
      diagnostics: clone(this.diagnostics),
      semanticState: clone(this.semanticState),
      surfaces: clone(this.surfaces),
      pendingInteractions: clone(this.pendingInteractions),
      ...(this.inputLease ? { inputLease: clone(this.inputLease) } : {}),
    };
  }

  transact(change: (draft: ExtensionPresentationDraft) => void): ExtensionPresentationMutation | undefined {
    this.assertActive();
    const before = this.draft();
    const callbackDraft = clone(before);
    change(callbackDraft);
    // Callback code may retain its draft or inserted objects. Only a private
    // post-callback clone can become committed state.
    const candidate = clone(callbackDraft);
    const nextRevision = this.revision + 1;
    // Interaction response scope is the revision which first admitted it.
    for (const interaction of candidate.pendingInteractions) {
      if (interaction.hostEpoch.length === 0) interaction.hostEpoch = this.hostEpoch;
      if (interaction.presentationRevision === 0) interaction.presentationRevision = nextRevision;
    }
    const beforeSurfaces = new Map(before.surfaces.map((surface) => [surface.id, surface]));
    for (const surface of candidate.surfaces) {
      const previous = beforeSurfaces.get(surface.id);
      if ((!previous && surface.revision !== 1)
        || (previous && !equal(previous, surface) && surface.revision !== previous.revision + 1)) {
        throw new GatewayError("conflict", "Extension surface revision is not the exact next revision");
      }
    }
    this.validateState(candidate);
    this.validateEditorChange(before, candidate);
    const mutation = this.mutation(before, candidate, nextRevision);
    if (Object.keys(mutation).length === 3) return undefined;
    this.semanticState = candidate.semanticState;
    this.surfaces = candidate.surfaces;
    this.pendingInteractions = candidate.pendingInteractions;
    this.inputLease = candidate.inputLease;
    this.capabilities = candidate.capabilities;
    this.diagnostics = candidate.diagnostics;
    this.revision = nextRevision;
    this.broadcast("session.extensionPresentation", mutation as unknown as JsonValue);
    return mutation;
  }

  notify(message: string, type: "info" | "warning" | "error"): void {
    this.transact((draft) => { draft.notification = { message: stripTerminalControls(message), type }; });
  }

  revokeInputLease(connectionId: string): boolean {
    this.assertActive();
    if (this.inputLease?.connectionId !== connectionId) return false;
    this.transact((draft) => { delete draft.inputLease; });
    return true;
  }

  retire(): void {
    // Retirement is an internal ownership boundary. Clear disposable
    // presentation state even when no broadcast can be delivered; stale
    // callbacks are rejected by `active` and cannot repopulate this epoch.
    this.surfaces = [];
    this.pendingInteractions = [];
    this.inputLease = undefined;
    this.pendingComponentFactories = 0;
    this.scheduledRenders = 0;
    this.active = false;
  }

  private draft(): ExtensionPresentationDraft {
    return {
      semanticState: clone(this.semanticState),
      surfaces: clone(this.surfaces),
      pendingInteractions: clone(this.pendingInteractions),
      ...(this.inputLease ? { inputLease: clone(this.inputLease) } : {}),
      capabilities: [...this.capabilities],
      diagnostics: clone(this.diagnostics),
    };
  }

  private mutation(before: ExtensionPresentationDraft, after: ExtensionPresentationDraft, revision: number): ExtensionPresentationMutation {
    const result: ExtensionPresentationMutation = { version: 2, hostEpoch: this.hostEpoch, revision };
    const semantic: ExtensionPresentationMutation["semantic"] = {};
    for (const key of Object.keys(after.semanticState) as (keyof ExtensionSemanticState)[]) {
      if (!equal(before.semanticState[key], after.semanticState[key])) {
        if (key === "hiddenThinkingLabel" || key === "title") {
          (semantic as Record<string, unknown>)[key] = after.semanticState[key] ?? null;
        } else {
          (semantic as Record<string, unknown>)[key] = clone(after.semanticState[key]);
        }
      }
    }
    if (after.editorDirective) {
      semantic.editorAction = after.editorDirective.action;
      semantic.editorDelta = after.editorDirective.delta;
      if (after.editorDirective.operationId) semantic.editorOperationId = after.editorDirective.operationId;
    }
    if (Object.keys(semantic).length > 0) result.semantic = semantic;
    if (!equal(before.pendingInteractions, after.pendingInteractions)) result.interactionList = clone(after.pendingInteractions);
    const beforeSurfaces = new Map(before.surfaces.map((surface) => [surface.id, surface]));
    const afterSurfaces = new Map(after.surfaces.map((surface) => [surface.id, surface]));
    const upserts = after.surfaces.filter((surface) => !equal(surface, beforeSurfaces.get(surface.id)));
    const removals = before.surfaces.filter((surface) => !afterSurfaces.has(surface.id)).map((surface) => surface.id);
    if (upserts.length > 0) result.surfaceUpserts = clone(upserts);
    if (removals.length > 0) result.surfaceRemovals = removals;
    if (!equal(before.inputLease, after.inputLease)) result.inputLease = after.inputLease ? clone(after.inputLease) : null;
    if (!equal(before.capabilities, after.capabilities)) result.capabilities = [...after.capabilities];
    if (!equal(before.diagnostics, after.diagnostics)) result.diagnostics = clone(after.diagnostics);
    if (after.notification) result.notification = clone(after.notification);
    return result;
  }

  private validateState(draft: ExtensionPresentationDraft): void {
    if (!Array.isArray(draft.surfaces) || !Array.isArray(draft.pendingInteractions)
      || !Array.isArray(draft.capabilities) || !Array.isArray(draft.diagnostics)
      || typeof draft.semanticState !== "object" || draft.semanticState === null) {
      throw new GatewayError("conflict", "Extension presentation draft is malformed");
    }
    if (draft.surfaces.length > EXTENSION_PRESENTATION_MAX_SURFACES) throw new GatewayError("busy", "Extension surfaces reached bounded capacity", true);
    const ids = new Set<string>();
    for (const surface of draft.surfaces) {
      validateSurface(surface);
      if (!ids.add(surface.id)) throw new GatewayError("conflict", "Extension surface identity is duplicated");
    }
    this.validateSemantic(draft.semanticState);
    if (draft.pendingInteractions.length > EXTENSION_MAX_INTERACTIONS
      || new Set(draft.pendingInteractions.map((item) => item.id)).size !== draft.pendingInteractions.length
      || draft.pendingInteractions.some((item) => typeof item !== "object" || item === null || item.id.length === 0 || item.hostEpoch !== this.hostEpoch || item.presentationRevision < 1
        || item.presentationRevision > this.revision + 1 || !boundedSafe(item.id, MAX_ID_BYTES)
        || !["select", "confirm", "input", "editor"].includes(item.method)
        || !boundedSafe(item.title, MAX_TITLE_BYTES, true) || (item.message !== undefined && !boundedSafe(item.message, MAX_MESSAGE_BYTES, true))
        || (item.placeholder !== undefined && !boundedSafe(item.placeholder, MAX_TITLE_BYTES))
        || (item.prefill !== undefined && !boundedSafe(item.prefill, MAX_EDITOR_DIRECTIVE_BYTES, true))
        || (item.expiresAt !== undefined && (!boundedSafe(item.expiresAt, MAX_ID_BYTES) || Number.isNaN(Date.parse(item.expiresAt))))
        || (item.method === "select" && (item.options === undefined || item.options.length === 0))
        || (item.options !== undefined && (item.method !== "select" || item.options.length > EXTENSION_MAX_SELECT_OPTIONS
          || new Set(item.options).size !== item.options.length
          || item.options.some((option) => !boundedSafe(option, MAX_OPTION_BYTES))))
        || (item.questionnaire !== undefined && (!validQuestionnaire(item.questionnaire)
          || (item.method !== "select" && item.method !== "input")
          || (item.method === "select" && item.options?.length !== item.questionnaire.options.length + (item.questionnaire.allowFreeform ? 1 : 0))
          || (item.method === "input" && item.options !== undefined)))
        || bytes(item) > MAX_INTERACTION_BYTES)) {
      throw new GatewayError("conflict", "Extension interactions are invalid");
    }
    if (draft.notification && (!boundedSafe(draft.notification.message, MAX_NOTIFICATION_BYTES, true)
      || !["info", "warning", "error"].includes(draft.notification.type))) {
      throw new GatewayError("conflict", "Extension presentation notification is invalid");
    }
    if (draft.editorDirective && (bytes(draft.editorDirective.delta) > MAX_EDITOR_DIRECTIVE_BYTES
      || (draft.editorDirective.operationId !== undefined && bytes(draft.editorDirective.operationId) > MAX_ID_BYTES))) {
      throw new GatewayError("conflict", "Extension presentation editor directive is invalid");
    }
    if (draft.capabilities.length > MAX_CAPABILITIES || draft.diagnostics.length > MAX_DIAGNOSTICS
      || draft.capabilities.some((value) => !boundedSafe(value, MAX_ID_BYTES))
      || draft.diagnostics.some((value) => !boundedSafe(value.code, MAX_ID_BYTES) || !boundedSafe(value.message, MAX_MESSAGE_BYTES, true))) {
      throw new GatewayError("conflict", "Extension presentation metadata is invalid");
    }
    if (draft.inputLease) {
      requireId(draft.inputLease.id, "lease ID");
      requireId(draft.inputLease.connectionId, "lease connection");
      requireId(draft.inputLease.surfaceId, "lease surface");
      if (!boundedSafe(draft.inputLease.acquiredAt, MAX_ID_BYTES) || Number.isNaN(Date.parse(draft.inputLease.acquiredAt))
        || !Number.isSafeInteger(draft.inputLease.surfaceRevision) || draft.inputLease.surfaceRevision < 1
        || !draft.surfaces.some((surface) => surface.id === draft.inputLease?.surfaceId && surface.revision === draft.inputLease?.surfaceRevision)) {
        throw new GatewayError("conflict", "Extension input lease revision is invalid");
      }
    }
    const projected = {
      version: 2, hostEpoch: this.hostEpoch, revision: this.revision + 1,
      capabilities: draft.capabilities, diagnostics: draft.diagnostics,
      semanticState: draft.semanticState, surfaces: draft.surfaces,
      pendingInteractions: draft.pendingInteractions, inputLease: draft.inputLease,
    };
    if (bytes(projected) > EXTENSION_PRESENTATION_MAX_BYTES) throw new GatewayError("busy", "Extension presentation reached bounded capacity", true);
  }

  private validateEditorChange(before: ExtensionPresentationDraft, after: ExtensionPresentationDraft): void {
    const changed = before.semanticState.editorRevision !== after.semanticState.editorRevision
      || before.semanticState.editorText !== after.semanticState.editorText;
    if (!changed && after.editorDirective) throw new GatewayError("conflict", "Extension editor directive has no state change");
    if (!changed) return;
    if (after.semanticState.editorRevision !== before.semanticState.editorRevision + 1) {
      throw new GatewayError("conflict", "Extension editor revision is not exact-next");
    }
    const directive = after.editorDirective;
    if (!directive || (directive.action === "paste"
      ? before.semanticState.editorText + directive.delta !== after.semanticState.editorText
      : directive.delta !== after.semanticState.editorText)
      || (directive.action === "native") !== (directive.operationId !== undefined)) {
      throw new GatewayError("conflict", "Extension editor directive is inconsistent");
    }
  }

  private validateOwner(owner: unknown): boolean {
    if (!owner || typeof owner !== "object") return false;
    const value = owner as { id?: unknown; title?: unknown; source?: unknown };
    return boundedSafe(value.id, MAX_OWNER_ID_BYTES)
      && boundedSafe(value.title, MAX_OWNER_TITLE_BYTES)
      && boundedSafe(value.source, MAX_OWNER_SOURCE_BYTES);
  }

  private validateSemantic(state: ExtensionSemanticState): void {
    if (typeof state.statuses !== "object" || state.statuses === null || Array.isArray(state.statuses)
      || typeof state.working !== "object" || state.working === null
      || typeof state.working.indicator !== "object" || state.working.indicator === null
      || !Array.isArray(state.working.indicator.frames) || !Array.isArray(state.widgets)
      || typeof state.statusOwners !== "object" || state.statusOwners === null || Array.isArray(state.statusOwners)) {
      throw new GatewayError("conflict", "Extension semantic presentation is malformed");
    }
    const statuses = Object.entries(state.statuses);
    const statusOwners = Object.entries(state.statusOwners);
    if (statusOwners.some(([key, owner]) => !(key in state.statuses) || !this.validateOwner(owner))) {
      throw new GatewayError("conflict", "Extension status owner metadata is invalid");
    }
    if (statuses.length > EXTENSION_MAX_STATUSES
      || statuses.some(([key, value]) => key.length === 0 || !boundedSafe(key, MAX_KEY_BYTES) || !boundedSafe(value, MAX_STATUS_BYTES, true))
      || typeof state.working.visible !== "boolean"
      || state.statusOwners === undefined || statusOwners.length > EXTENSION_MAX_STATUSES
      || (state.working.message !== undefined && !boundedSafe(state.working.message, MAX_WORKING_BYTES, true))
      || !["default", "hidden", "static", "animated"].includes(state.working.indicator.kind)
      || state.working.indicator.frames.length > MAX_INDICATOR_FRAMES
      || state.working.indicator.frames.some((frame) => !boundedSafe(frame, MAX_INDICATOR_FRAME_BYTES))
      || (state.working.indicator.intervalMs !== undefined && (!Number.isSafeInteger(state.working.indicator.intervalMs) || state.working.indicator.intervalMs < 1))
      || (state.hiddenThinkingLabel !== undefined && !boundedSafe(state.hiddenThinkingLabel, MAX_STATUS_BYTES, true))
      || (state.title !== undefined && !boundedSafe(state.title, MAX_TITLE_BYTES, true))
      || typeof state.toolsExpanded !== "boolean"
      || !Number.isSafeInteger(state.editorRevision) || state.editorRevision < 0
      || !boundedSafe(state.editorText, MAX_EDITOR_DIRECTIVE_BYTES, true)
      || state.widgets.length > EXTENSION_MAX_WIDGETS
      || new Set(state.widgets.map((widget) => widget.key)).size !== state.widgets.length
      || state.widgets.some((widget) => widget.key.length === 0 || !boundedSafe(widget.key, MAX_KEY_BYTES)
        || (widget.owner !== undefined && !this.validateOwner(widget.owner))
        || !Number.isSafeInteger(widget.revision) || widget.revision < 1
        || !["aboveEditor", "belowEditor"].includes(widget.placement)
        || widget.lines.length > EXTENSION_MAX_WIDGET_LINES
        || widget.lines.some((line) => !boundedSafe(line, MAX_WIDGET_LINE_BYTES)))) {
      throw new GatewayError("conflict", "Extension semantic presentation is invalid");
    }
  }

  private assertActive(): void {
    if (!this.active) throw new GatewayError("conflict", "Extension host epoch was retired", true);
  }
}
