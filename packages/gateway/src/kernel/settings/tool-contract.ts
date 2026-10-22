/** The settings model's vocabulary (docs/settings-model.md section 4).
 * Every key's behaviour is data here; nothing outside the schema names a key. */
export const LAYERS = ["project", "session", "global"] as const;

export type LayerId = typeof LAYERS[number];

/** Scope names #1634 retired, as old session entries recorded them. Session JSONL
 * is never rewritten (#1649), so this reader is where they become current names;
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
  /** The request's tier: the highest of its changes (doc 5.4). */
  tier: Tier;
  changes: ChangeOutcome[];
  /** A pending request: what the maintainer decides and the exact diff it binds to. */
  approval?: { requestId: string; digest: string; expiresAt: string };
  /** A Home task worker target's signal for its applied Session-scope changes (#1336). */
  signal?: SettingsSignal;
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

/** What the session runtime gives the tool: its own target and identity, or Home's worker target. */
export interface SettingsToolAccess {
  resolve(keys?: string[], taskId?: string): Promise<Resolution & { worker?: TaskWorkerSettingsView }>;
  change(changes: ChangeRequest[], input: { reason: string; dryRun?: boolean; toolCallId: string; web: boolean; taskId?: string }): Promise<ChangeResult & { worker?: TaskWorkerSettingsView }>;
  /** Declined, expired or superseded changes this chat asked for, not yet told (Q22). */
  takeOutcomes(): Promise<string[]>;
}
