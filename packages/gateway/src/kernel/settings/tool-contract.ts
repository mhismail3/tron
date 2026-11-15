import type { ChangeReview, NativeChangeAcceptance } from "../../protocol/types.js";
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

export const QUALIFIER_NAMES = ["role", "model", "provider", "tool", "project", "connection", "key", "direction", "server", "note", "device"] as const;

export type QualifierName = typeof QUALIFIER_NAMES[number];

export type Qualifiers = Partial<Record<QualifierName, string>>;

export type ChangeStatus = "started" | "applied" | "failed" | "outside" | "committed";

export interface GitResult {
  root: string | null;
  path: string;
  staged: boolean;
  reason?: string;
  blob?: string;
  warning?: string;
  head?: string;
  branch?: string;
}

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
  via?: "home-profile:sameAs:home" | "home-profile" | "home-explicit" | "home-fallback";
  reason?: string;
}

export interface Badge { kind: string; label: string; detail?: string; action?: { kind: string; label: string; changeId?: string } }

export interface LayerValue {
  layer: LayerId;
  value?: unknown;
  display?: string;
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
  applied: boolean;
  reason?: "untrusted";
  badges: Badge[];
  fixedAt?: FixedSetting;
  layers: LayerValue[];
  overridden?: boolean;
  projectSetting?: { file: string; path: string };
}

export interface Diagnostic { key: string; layer: LayerId; reason: "project-forbidden" | "unknown-key"; path: string; file: string }

export interface Resolution {
  target: SettingsTarget;
  layers: readonly LayerId[];
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
  expected?: unknown;
}

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
  revision?: number;
  git?: GitResult;
  confirm?: string;
  result?: unknown;
  error?: { code: string; message: string };
  before?: unknown;
  after?: unknown;
  undoable?: false;
}

export interface ChangeResult {
  dryRun?: true;
  status: ChangeStatus | "review" | "declined";
  changes: ChangeOutcome[];
  review?: ChangeReview;
  signal?: SettingsSignal;
  summary?: string;
  failure?: string;
}

export type ConfirmChange = <T>(review: ChangeReview, apply: (acceptance: NativeChangeAcceptance) => Promise<T>) => Promise<T | undefined>;

export interface TaskWorkerSettingsState {
  running: boolean;
  selected: { model: string | null; thinking: string };
  lastResponse: { model: string; thinking: string | null; at: string } | null;
}

export interface TaskWorkerSettingsView extends TaskWorkerSettingsState {
  taskId: string;
  sessionId: string;
  operationId: string | null;
  state: string;
  resolvedFrom?: string;
}

export interface SettingsHistoryQuery {
  key?: string;
  cursor?: string;
  limit?: number;
}

export interface SettingsInventory {
  hooks: {
    extensions: Array<{ name: string; scope: string; source: string; handlers: Array<{ event: string; count: number }> }>;
    events: Array<{ event: string; count: number; extensions: string[] }>;
    loadErrors: number;
  };
  packages: Array<{ source: string; scope: string; filtered: boolean; provides?: Record<string, string[]>; conflict?: string; nodeRequirement?: string }>;
  modules: Array<{ name: string; purpose: string; tools: string[]; commands: string[] }>;
  mcp: { servers: Array<{ name: string; scope: "global" | "project"; state: "configured" | "disabled" | "unknown"; enabled: boolean; exposure: string; transport: "stdio" | "http" | "unknown" }>; errors: number };
}

export interface SettingsInventorySource {
  read(cwd: string): Promise<SettingsInventory>;
}

export interface SettingsToolAccess {
  inventory(): Promise<SettingsInventory>;
  history(input: SettingsHistoryQuery, toolCallId: string): Promise<{ entries: unknown[]; nextCursor?: string }>;
  undo(changeId: string, input: { reason: string; toolCallId: string; confirm?: ConfirmChange }): Promise<ChangeResult>;
  resolve(keys?: string[], taskId?: string): Promise<Resolution & { worker?: TaskWorkerSettingsView }>;
  change(changes: ChangeRequest[], input: { reason: string; dryRun?: boolean; toolCallId: string; taskId?: string; confirm?: ConfirmChange }): Promise<ChangeResult & { worker?: TaskWorkerSettingsView }>;
}
