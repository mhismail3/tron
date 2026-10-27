import { Type } from "../pi/ai.js";
/** The settings model's vocabulary (docs/settings-model.md section 4).
 * Every key's behaviour is data here; nothing outside the schema names a key. */
export const LAYERS = ["project", "session", "global"] as const;

export type LayerId = typeof LAYERS[number];
export type Direction = "widen" | "narrow";

export type TaskModelQueues = Readonly<Record<"worker" | "subagent", readonly string[]>>;
export const MODEL_QUEUE_ROLES = ["worker", "subagent", "background"] as const;
export function modelQueueKey(role: typeof MODEL_QUEUE_ROLES[number]): string { return `model.queue[role=${role}]`; }

export function splitModelRef(value: string): { provider: string; id: string } | undefined {
  const separator = value.indexOf("/");
  return separator > 0 && separator < value.length - 1 ? { provider: value.slice(0, separator), id: value.slice(separator + 1) } : undefined;
}

/** Scope names #1634 retired, as old session entries recorded them. Session JSONL
 * is never rewritten (#1649), so session readers map them to current names;
 * the next settings write persists the current name. The startup migration of the
 * shared stores (approvals, audit) uses the same map. Exit condition: delete it
 * once no retained session predates #1634 (none carries one of these names). */
export const RETIRED_SCOPES: Readonly<Record<string, "global" | "session">> = Object.freeze({
  mac: "global", builtin: "global", chat: "session", profile: "session",
});

export const TIERS = ["quiet", "notify", "approve"] as const;

export type Tier = typeof TIERS[number];

export const QUALIFIER_NAMES = ["role", "model", "provider", "tool", "project", "connection", "key", "direction", "server", "note", "device"] as const;

export type QualifierName = typeof QUALIFIER_NAMES[number];

export type Qualifiers = Partial<Record<QualifierName, string>>;

export type ChangeStatus = "applied" | "pending" | "approved" | "declined" | "expired" | "superseded" | "failed" | "outside" | "committed";

export interface GitResult {
  root: string | null;
  path: string;
  staged: boolean;
  reason?: string;
  blob?: string;
  warning?: string;
  /** An outside change or commit fact: the repository's `HEAD` commit and branch then. */
  head?: string;
  branch?: string;
}

/**
 * The one resolver (docs/settings-model.md section 3, foundation F4).
 *
 * For a target and each key it takes the topmost layer that the target has,
 * that holds a value for the key, that the key allows, and that is applied.
 * It reads stores that were loaded by their owners; it never writes, caches or
 * consults the change record (F2).
 */

export type SettingsTarget =
  | { kind: "global" }
  | { kind: "project"; cwd: string }
  | { kind: "session"; sessionId: string }
  | { kind: "home" };

export interface FixedSetting {
  value: unknown;
  from: LayerId | "delegate";
  at: string;
  ref: string;
  qualifiers?: Qualifiers;
  /** Delegation-time source, kept with the fixed value rather than inferred from current Home. */
  via?: "home-profile:sameAs:home" | "home-profile" | "home-explicit" | "home-fallback";
  reason?: string;
}

export interface Badge { kind: string; label: string; detail?: string; action?: { kind: string; label: string; changeId?: string } }

export interface LayerValue {
  layer: LayerId;
  value?: unknown;
  display?: string;
  /** False when the target has the layer and it holds a value that does not apply. */
  applied: boolean;
  reason?: "untrusted";
}

export interface ResolvedKey {
  key: string;
  qualifiers?: Qualifiers;
  group: string;
  subgroup?: string;
  value: unknown;
  display: string;
  layer: LayerId;
  /** False when the topmost value present is not applied (an untrusted project). */
  applied: boolean;
  reason?: "untrusted";
  badges: Badge[];
  fixedAt?: FixedSetting;
  layers: LayerValue[];
  /** A stored Session/Home override, including one currently masked by Project. */
  overridden?: boolean;
  projectSetting?: { file: string; path: string };
}

export interface Diagnostic { key: string; layer: LayerId; reason: "project-forbidden" | "unknown-key"; path: string; file: string }

export interface Resolution {
  target: SettingsTarget;
  layers: readonly LayerId[];
  /** The Project store exists but cannot be parsed (for example merge markers). */
  projectUnreadable?: true;
  projectNotice?: { file: string; message: string };
  keys: ResolvedKey[];
  diagnostics: Diagnostic[];
  diagnosticsTruncated?: true;
}

export interface ChangeRequest {
  key: string;
  qualifiers?: Qualifiers;
  layer: LayerId;
  op: "set" | "unset";
  value?: unknown;
  /** The value the actor read at this layer; `null` means unset. Omitted skips the check. */
  expected?: unknown;
}

/**
 * The worker's signal after an applied change (#1336). `queued`: one Gateway steer joined
 * the task's ordered steering lane (`operationId` is that steer's own operation); the change
 * is already stored and the worker's next provider request uses it. `not-running`: no live
 * task operation, so the change takes effect when the worker next runs (resume). `failed`:
 * the change is applied and stored, but the steer was refused; the error says why.
 */
export type SettingsSignal =
  | { status: "queued"; taskId: string; operationId: string; appliesFrom: "next-request" }
  | { status: "not-running"; taskId: string; appliesFrom: "next-run" }
  | { status: "failed"; taskId: string; appliesFrom: "next-request"; error: { code: string; message: string } };

export interface ChangeOutcome {
  changeId: string;
  key: string;
  qualifiers?: Qualifiers;
  layer: LayerId;
  status: ChangeStatus;
  tier: Tier;
  revision?: number;
  git?: GitResult;
  /** A dry run's: the key's `confirm` text when this change's tier is approve,
   * for the maintainer's row to show before he makes it. */
  confirm?: string;
  /** The store's resulting state when its applier reports one (trust's inspection). */
  result?: unknown;
  error?: { code: string; message: string };
  /** The value at this layer before and after the change, `null` when unset there. A
   * redacted key reports neither, only `redacted`, as its change record does. */
  before?: unknown;
  after?: unknown;
  redacted?: true;
}

export interface ChangeResult {
  dryRun?: true;
  status: ChangeStatus;
  /** Highest change tier; a refused dry run has no admitted plan and reports quiet. */
  tier: Tier;
  changes: ChangeOutcome[];
  /** A pending request: what the maintainer decides and the exact diff it binds to. */
  approval?: { requestId: string; digest: string; expiresAt: string };
  /** A Home task worker target's signal for its applied Session-scope changes (#1336). */
  signal?: SettingsSignal;
  /** A pending action request: the exact preview its digest binds (#1985). */
  action?: ApprovalActionPreview;
  /** A settled action's own account of what it did, or why it failed. */
  summary?: string;
  failure?: string;
}

/** A maintainer-gated operation that is not a stored setting value (a project
 * lifecycle step): its preview is display text the digest binds. `exact` is the
 * operation's exact identity, shown behind the sheet's technical disclosure. */
export interface ApprovalActionItem { label: string; value: string; detail?: string; exact?: string }
export interface ApprovalActionPreview { title: string; items: ApprovalActionItem[]; target: SettingsTarget }

export const SETTINGS_OUTCOME_MESSAGE = "tron.settings-outcome.v1";

/** One settled approval as its requester hears it (decision 4e6e8f54). Values are
 * display text; a redacted key carries none. `approved` means approved and applied. */
export interface SettingsOutcomeRequest {
  requestId: string;
  status: "approved" | "declined" | "expired" | "superseded" | "failed";
  requester: { kind: string; taskId?: string };
  target: SettingsTarget;
  createdAt: string;
  decidedAt?: string;
  reason?: string;
  failure?: string;
  items: Array<{ key: string; label: string; qualifiers?: Qualifiers; layer: LayerId; before?: string; after?: string; redacted?: true }>;
  action?: { subject: string; title: string; summary?: string };
}

/** The canonical message a requester hears its outcomes in: on its next turn, or
 * as the trigger of Home's own wake turn. `taskId` names the delivery for receipts. */
export interface SettingsOutcomeMessage {
  customType: typeof SETTINGS_OUTCOME_MESSAGE;
  content: string;
  display: true;
  details: { version: 1; eventId: string; taskId: string; requests: SettingsOutcomeRequest[] };
}

/** Delivery proof comes only from canonical custom entries, never model text or tool results. */
export function settingsOutcomeRequestIds(entries: Iterable<unknown>): string[] {
  const ids = new Set<string>();
  for (const value of entries) {
    if (!value || typeof value !== "object") continue;
    const entry = value as { type?: unknown; customType?: unknown; details?: unknown };
    if (entry.type !== "custom_message" || entry.customType !== SETTINGS_OUTCOME_MESSAGE || !entry.details || typeof entry.details !== "object") continue;
    const details = entry.details as { version?: unknown; requests?: unknown };
    if (details.version !== 1 || !Array.isArray(details.requests)) continue;
    for (const request of details.requests) {
      if (request && typeof request === "object" && typeof request.requestId === "string") ids.add(request.requestId);
    }
  }
  return [...ids];
}

/** A delegated worker's settings state beside its resolved keys (#1336). */
export interface TaskWorkerSettingsState {
  /** The worker's task operation is live: a change applies from its next provider request. */
  running: boolean;
  /** What the worker's next provider request uses. */
  selected: { model: string | null; thinking: string };
  /** What its latest assistant response ran on: the acknowledgment a change took effect. */
  lastResponse: { model: string; thinking: string | null; at: string } | null;
}

/** The task a `taskId` call resolved to: the worker's current task (a resume continues it). */
export interface TaskWorkerSettingsView extends TaskWorkerSettingsState {
  taskId: string;
  sessionId: string;
  operationId: string | null;
  state: string;
  resolvedFrom?: string;
}

/** Shows one request in the asking chat through the host's semantic form until
 * `signal` aborts. Never decides: decisions are `settings.decide` (#2050). */
export type ApprovalPresenter = (request: { requestId: string; title: string }, signal: AbortSignal) => Promise<unknown>;

/** The one `wait` parameter every approval-requesting tool takes (#2050). The
 * default is the tool's own: settings waits, profile and projects do not. */
export function approvalWaitParameter(waitsByDefault: boolean) {
  return Type.Optional(Type.Boolean({ description: `When the maintainer's approval is needed: true shows the request in this chat and waits for his decision (Stop cancels it); false returns pending at once and the outcome arrives later. Default ${waitsByDefault}.` }));
}

/** What the session runtime gives the tool: its own target and identity, or Home's worker target. */
export interface SettingsToolAccess {
  resolve(keys?: string[], taskId?: string): Promise<Resolution & { worker?: TaskWorkerSettingsView }>;
  change(changes: ChangeRequest[], input: { reason: string; dryRun?: boolean; request?: boolean; toolCallId: string; web: boolean; taskId?: string }): Promise<ChangeResult & { worker?: TaskWorkerSettingsView }>;
  /** Waits in this chat for the maintainer's decision on its own pending request. */
  wait(requestId: string, present: ApprovalPresenter, signal?: AbortSignal): Promise<ChangeResult>;
  /** Every settled request this chat asked for and has not heard yet (decision 4e6e8f54). */
  takeOutcomes(deliveredRequestIds?: readonly string[]): Promise<SettingsOutcomeMessage | undefined>;
}
