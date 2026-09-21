import { createHash } from "node:crypto";
import type { JsonValue } from "../protocol/types.js";

export const CONNECTION_STATE_SCHEMA_VERSION = 1 as const;
export const CONNECTION_DEFINITION_SCHEMA_VERSION = 1 as const;
export const RUNTIME_BINDING_SCHEMA_VERSION = 1 as const;

export type ConnectionSetupMethod = "oauth" | "token" | "local-command" | "endpoint" | "browser";
export type ConnectionImplementationKind = "knowledge-connector" | "mcp";
export type ConnectionHealth = "unconfigured" | "setup-required" | "ready" | "disabled" | "auth-error" | "error" | "disconnected";
export type ConnectionCapabilityAvailability = "available" | "unavailable" | "requires-setup" | "disabled" | "unsupported";
export type CredentialAvailability = "available" | "unavailable" | "unknown";
export type ProviderIdentityAdmission = "admitted" | "mismatch" | "unknown";
export type ConnectionEffect = "read" | "write" | "paid" | "disclosure";

/** A supplier-level identity. Definitions are composed from built-in/package
 * discovery and are never a second package manifest or credential authority. */
export interface IntegrationDefinition {
  schemaVersion: typeof CONNECTION_DEFINITION_SCHEMA_VERSION;
  id: string;
  implementation: ConnectionImplementationKind;
  displayName: string;
  setupMethods: ConnectionSetupMethod[];
  capabilities: IntegrationCapabilityDefinition[];
}

export interface IntegrationCapabilityDefinition {
  id: string;
  displayName: string;
  effects: ConnectionEffect[];
  supported: boolean;
}

export interface ConnectionPolicy {
  enabled: boolean;
  allowWrites: boolean;
  paidAccessApproved: boolean;
  paidBudgetCents: number;
  recurringApproved: boolean;
}

/** Generic account envelope only. Provider checkpoints, evidence, cohorts and
 * remote-effect receipts remain with the provider/Knowledge adapter. */
export interface McpConnectionConfiguration {
  transport: "http" | "stdio";
  endpoint?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  /** Environment names/values explicitly supplied for the trusted stdio child. */
  env?: Record<string, string>;
}

export interface ConnectionInstance {
  id: string;
  definitionId: string;
  implementation: ConnectionImplementationKind;
  providerAccountId: string;
  scope?: string;
  credentialRef: string;
  configuration?: McpConnectionConfiguration;
  policy: ConnectionPolicy;
  health: ConnectionHealth;
  createdAt: string;
  updatedAt: string;
  setupRevision: number;
  /** Bounded owner observations; absent legacy values are treated as unknown. */
  credentialAvailability?: CredentialAvailability;
  providerIdentity?: ProviderIdentityAdmission;
  /** Verified provider metadata for display; never an account authority. */
  providerDisplayName?: string;
  lastError?: string;
}

export type ConnectionInstanceProjection = Omit<ConnectionInstance, "credentialRef" | "configuration"> & { credentialConfigured: boolean };

export interface ConnectionCapabilityStatus {
  id: string;
  availability: ConnectionCapabilityAvailability;
  effects: ConnectionEffect[];
  definitionId: string;
  connectionId?: string;
  provenance: { owner: "connection"; definitionId: string; connectionId?: string };
  detail?: string;
}

/** Runtime admission is an ephemeral projection checked by the runtime owner;
 * the connection owner does not persist bindings or grant child inheritance. */
export interface RuntimeBinding {
  schemaVersion: typeof RUNTIME_BINDING_SCHEMA_VERSION;
  integrationId: string;
  connectionId?: string;
  capabilityId: string;
  sessionId: string;
  runtimeGeneration: number;
  provider: { owner: "connection"; definitionId: string; connectionId?: string };
}

export interface ConnectionSetupOperation {
  operationId: string;
  instanceId: string;
  definitionId: string;
  method: ConnectionSetupMethod;
  status: "pending" | "completed" | "cancelled";
  createdAt: string;
  updatedAt: string;
}

export interface ProviderAdmissionObservation {
  credentialAvailability: CredentialAvailability;
  providerIdentity: ProviderIdentityAdmission;
  /** Accepted only alongside an admitted identity and exact setup revision. */
  providerDisplayName?: string;
}

export type ConnectionCommand =
  | { kind: "setup.begin"; commandId: string; instanceId: string; definitionId: string; method: ConnectionSetupMethod }
  | { kind: "setup.complete"; commandId: string; operationId: string; instanceId: string; providerAccountId: string; scope?: string; credentialRef: string; policy: ConnectionPolicy; configuration?: McpConnectionConfiguration }
  | { kind: "setup.cancel"; commandId: string; operationId: string; instanceId: string }
  | { kind: "policy.update"; commandId: string; instanceId: string; expectedSetupRevision: number; policy: ConnectionPolicy }
  | { kind: "disconnect"; commandId: string; instanceId: string };

export type ConnectionAction =
  | { operation: "connections.list"; request: Record<string, never> }
  | { operation: "connections.setup.begin"; request: Omit<Extract<ConnectionCommand, { kind: "setup.begin" }>, "kind"> }
  | { operation: "connections.setup.complete"; request: Omit<Extract<ConnectionCommand, { kind: "setup.complete" }>, "kind"> }
  | { operation: "connections.setup.cancel"; request: Omit<Extract<ConnectionCommand, { kind: "setup.cancel" }>, "kind"> }
  | { operation: "connections.policy.update"; request: Omit<Extract<ConnectionCommand, { kind: "policy.update" }>, "kind"> }
  | { operation: "connections.disconnect"; request: Omit<Extract<ConnectionCommand, { kind: "disconnect" }>, "kind"> };

export interface ConnectionOwnerSnapshot {
  definitions: IntegrationDefinition[];
  /** Presentation projection: credential refs never leave the owner. */
  instances: ConnectionInstanceProjection[];
  setupOperations: ConnectionSetupOperation[];
  capabilities: ConnectionCapabilityStatus[];
  stateRevision: number;
}

export interface ConnectionOwnerReceipt {
  operation: string;
  requestHash: string;
  createdAt: string;
  result: JsonValue;
}

export interface ConnectionOwnerState {
  schemaVersion: typeof CONNECTION_STATE_SCHEMA_VERSION;
  stateRevision: number;
  instances: Record<string, ConnectionInstance>;
  setupOperations: Record<string, ConnectionSetupOperation>;
  receipts: Record<string, ConnectionOwnerReceipt>;
}

const ID = /^[A-Za-z0-9._:-]{1,160}$/;
const CREDENTIAL_REF = /^connector:[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._:-]{1,256}$/;

export function assertConnectionId(value: unknown, label = "connection id"): asserts value is string {
  if (typeof value !== "string" || !ID.test(value) || value === "." || value === "..") throw new Error(`Invalid ${label}`);
}

export function assertCredentialReference(value: unknown): asserts value is string {
  if (typeof value !== "string" || !CREDENTIAL_REF.test(value)) throw new Error("Credential reference is invalid");
}

export function assertDefinitionId(value: unknown): asserts value is string {
  if (typeof value !== "string" || !ID.test(value)) throw new Error("Definition ID is invalid");
}

export function connectionRequestHash(operation: string, request: unknown): string {
  return createHash("sha256").update(operation).update("\0").update(JSON.stringify(request)).digest("hex");
}

function bounded(value: unknown, label: string, maximum: number): asserts value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > maximum || /[\u0000-\u001f\u007f]/.test(value)) throw new Error(`${label} is invalid`);
}

/** Optional provider metadata never participates in account authorization. */
export function normalizeProviderDisplayName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const label = value.trim();
  return label.length > 0 && label.length <= 320 && !/[\u0000-\u001f\u007f]/.test(label) ? label : undefined;
}

export function validateConnectionPolicy(value: unknown): asserts value is ConnectionPolicy {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Connection policy is invalid");
  const policy = value as Record<string, unknown>;
  if (typeof policy.enabled !== "boolean" || typeof policy.allowWrites !== "boolean" || typeof policy.paidAccessApproved !== "boolean" || typeof policy.recurringApproved !== "boolean"
    || !Number.isSafeInteger(policy.paidBudgetCents) || (policy.paidBudgetCents as number) < 0 || (policy.paidBudgetCents as number) > 1_000_000) throw new Error("Connection policy is invalid");
}

export function validateIntegrationDefinition(value: unknown): asserts value is IntegrationDefinition {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Integration definition is invalid");
  const item = value as Record<string, unknown>;
  if (item.schemaVersion !== CONNECTION_DEFINITION_SCHEMA_VERSION) throw new Error("Unsupported integration definition schema");
  assertDefinitionId(item.id); if (!["knowledge-connector", "mcp"].includes(item.implementation as string)) throw new Error("Integration implementation is invalid");
  bounded(item.displayName, "Integration display name", 160);
  if (!Array.isArray(item.setupMethods) || item.setupMethods.length < 1 || item.setupMethods.some(method => !["oauth", "token", "local-command", "endpoint", "browser"].includes(method as string))) throw new Error("Integration setup methods are invalid");
  if (!Array.isArray(item.capabilities) || item.capabilities.length > 64) throw new Error("Integration capabilities are invalid");
  for (const capability of item.capabilities) {
    if (!capability || typeof capability !== "object" || Array.isArray(capability)) throw new Error("Integration capability is invalid");
    const value = capability as Record<string, unknown>; assertConnectionId(value.id, "capability id"); bounded(value.displayName, "Capability display name", 160);
    if (typeof value.supported !== "boolean" || !Array.isArray(value.effects) || value.effects.length === 0 || value.effects.some(effect => !["read", "write", "paid", "disclosure"].includes(effect as string))) throw new Error("Integration capability effects are invalid");
  }
}

export function validateConnectionInstance(value: unknown): asserts value is ConnectionInstance {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Connection instance is invalid");
  const item = value as Record<string, unknown>; assertConnectionId(item.id); assertDefinitionId(item.definitionId);
  if (!["knowledge-connector", "mcp"].includes(item.implementation as string)) throw new Error("Connection implementation is invalid");
  bounded(item.providerAccountId, "Provider account", 256); if (item.scope !== undefined) bounded(item.scope, "Connection scope", 512);
  assertCredentialReference(item.credentialRef); validateConnectionPolicy(item.policy);
  if (item.credentialAvailability !== undefined && !["available", "unavailable", "unknown"].includes(item.credentialAvailability as string) || item.providerIdentity !== undefined && !["admitted", "mismatch", "unknown"].includes(item.providerIdentity as string)) throw new Error("Connection admission observation is invalid");
  if (item.providerDisplayName !== undefined && normalizeProviderDisplayName(item.providerDisplayName) !== item.providerDisplayName) throw new Error("Provider display name is invalid");
  if (item.configuration !== undefined) {
    if (item.implementation !== "mcp") throw new Error("Only MCP instances may contain transport configuration");
    validateMcpConnectionConfiguration(item.configuration);
  }
  if (!["unconfigured", "setup-required", "ready", "disabled", "auth-error", "error", "disconnected"].includes(item.health as string)) throw new Error("Connection health is invalid");
  for (const key of ["createdAt", "updatedAt"] as const) bounded(item[key], `Connection ${key}`, 64);
  if (!Number.isSafeInteger(item.setupRevision) || (item.setupRevision as number) < 0) throw new Error("Connection setup revision is invalid");
  if (item.lastError !== undefined) bounded(item.lastError, "Connection error", 4_096);
}

export function validateMcpConnectionConfiguration(value: unknown): asserts value is McpConnectionConfiguration {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("MCP connection configuration is invalid");
  const config = value as Record<string, unknown>;
  if (config.transport !== "http" && config.transport !== "stdio") throw new Error("MCP transport is invalid");
  if (config.transport === "http") {
    bounded(config.endpoint, "MCP endpoint", 2_048);
    try { const url = new URL(config.endpoint as string); if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.hash) throw new Error("MCP endpoint is invalid"); }
    catch (error) { throw new Error(error instanceof Error && error.message === "MCP endpoint is invalid" ? error.message : "MCP endpoint is invalid"); }
    if (config.command !== undefined || config.args !== undefined || config.cwd !== undefined || config.env !== undefined) throw new Error("HTTP MCP configuration contains stdio fields");
    return;
  }
  bounded(config.command, "MCP executable", 1_024);
  if (config.endpoint !== undefined) throw new Error("stdio MCP configuration contains an endpoint");
  if (config.args !== undefined && (!Array.isArray(config.args) || config.args.length > 64 || config.args.some(arg => typeof arg !== "string" || arg.length > 2_048 || /[\u0000-\u001f\u007f]/.test(arg)))) throw new Error("MCP arguments are invalid");
  if (config.cwd !== undefined) bounded(config.cwd, "MCP working directory", 2_048);
  if (config.env !== undefined) {
    if (!config.env || typeof config.env !== "object" || Array.isArray(config.env) || Object.keys(config.env).length > 32) throw new Error("MCP environment is invalid");
    for (const [key, value] of Object.entries(config.env)) {
      if (!/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(key) || typeof value !== "string" || value.length > 8_192 || /[\u0000-\u001f\u007f]/.test(value)) throw new Error("MCP environment is invalid");
    }
  }
}

export function validateConnectionState(value: unknown): asserts value is ConnectionOwnerState {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Connection owner state is invalid");
  const state = value as Record<string, unknown>;
  if (state.schemaVersion !== CONNECTION_STATE_SCHEMA_VERSION || !Number.isSafeInteger(state.stateRevision) || (state.stateRevision as number) < 0) throw new Error("Unsupported connection owner state");
  if (!state.instances || typeof state.instances !== "object" || Array.isArray(state.instances) || !state.setupOperations || typeof state.setupOperations !== "object" || Array.isArray(state.setupOperations) || !state.receipts || typeof state.receipts !== "object" || Array.isArray(state.receipts)) throw new Error("Connection owner state maps are invalid");
  for (const [id, instance] of Object.entries(state.instances)) { assertConnectionId(id); validateConnectionInstance(instance); if ((instance as ConnectionInstance).id !== id) throw new Error("Connection instance map key does not match its ID"); }
  for (const [id, operation] of Object.entries(state.setupOperations)) {
    assertConnectionId(id, "setup operation id");
    if (!operation || typeof operation !== "object" || Array.isArray(operation)) throw new Error("Setup operation is invalid");
    const item = operation as Record<string, unknown>; assertConnectionId(item.operationId, "setup operation id"); assertConnectionId(item.instanceId); assertDefinitionId(item.definitionId); bounded(item.method, "Setup method", 32);
    if (!["oauth", "token", "local-command", "endpoint", "browser"].includes(item.method as string) || !["pending", "completed", "cancelled"].includes(item.status as string)) throw new Error("Setup operation is invalid");
    bounded(item.createdAt, "Setup createdAt", 64); bounded(item.updatedAt, "Setup updatedAt", 64);
    if (id !== item.operationId) throw new Error("Setup operation map key does not match its ID");
  }
  for (const receipt of Object.values(state.receipts)) {
    if (!receipt || typeof receipt !== "object" || Array.isArray(receipt) || typeof (receipt as ConnectionOwnerReceipt).operation !== "string" || typeof (receipt as ConnectionOwnerReceipt).requestHash !== "string" || typeof (receipt as ConnectionOwnerReceipt).createdAt !== "string" || !("result" in receipt)) throw new Error("Connection receipt is invalid");
  }
}

export function validateRuntimeBinding(value: unknown): asserts value is RuntimeBinding {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Runtime binding is invalid");
  const binding = value as Record<string, unknown>; if (binding.schemaVersion !== RUNTIME_BINDING_SCHEMA_VERSION) throw new Error("Unsupported runtime binding schema");
  assertDefinitionId(binding.integrationId); if (binding.connectionId !== undefined) assertConnectionId(binding.connectionId); assertConnectionId(binding.capabilityId, "capability id"); assertConnectionId(binding.sessionId, "session id");
  if (!Number.isSafeInteger(binding.runtimeGeneration) || (binding.runtimeGeneration as number) < 0) throw new Error("Runtime generation is invalid");
}
