import type { JsonValue } from "../../protocol/types.js";

export const CONNECTION_STATE_SCHEMA_VERSION = 1 as const;
export const CONNECTION_DEFINITION_SCHEMA_VERSION = 1 as const;

export type ConnectionSetupMethod = "oauth" | "token" | "browser";
export type ConnectionImplementationKind = "knowledge-connector";
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
  /** User-approved monthly paid-spend cap; consumers own usage ledgers separately. */
  paidBudgetCents: number;
  recurringApproved: boolean;
}

export interface RaindropCollectionMapping {
  collectionId: string;
  role: "research" | "personal" | "archive" | "triage";
}

export interface ConnectionInstance {
  id: string;
  definitionId: string;
  implementation: ConnectionImplementationKind;
  providerAccountId: string;
  scope?: string;
  credentialRef: string;
  /** Raindrop intake routing is connection-owned setup/policy, never connector progress state. */
  raindropCollections?: RaindropCollectionMapping[];
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

export type ConnectionInstanceProjection = Omit<ConnectionInstance, "credentialRef"> & { credentialConfigured: boolean };

export interface ConnectionCapabilityStatus {
  id: string;
  availability: ConnectionCapabilityAvailability;
  effects: ConnectionEffect[];
  definitionId: string;
  connectionId?: string;
  provenance: { owner: "connection"; definitionId: string; connectionId?: string };
  detail?: string;
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
  | { kind: "setup.complete"; commandId: string; operationId: string; instanceId: string; providerAccountId: string; scope?: string; credentialRef: string; policy: ConnectionPolicy; raindropCollections?: RaindropCollectionMapping[] }
  | { kind: "setup.cancel"; commandId: string; operationId: string; instanceId: string }
  | { kind: "policy.update"; commandId: string; instanceId: string; expectedSetupRevision: number; policy: ConnectionPolicy; raindropCollections?: RaindropCollectionMapping[] }
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

/** Shared identifier only; credential bytes remain with the Mac adapter. */
export const CONNECTOR_CREDENTIAL_SERVICE = "Tron Connector Credentials";

/** Existing owner operations consumed by tools, RPCs and connector adapters. */
export interface ConnectionAccess {
  snapshot(): Promise<ConnectionOwnerSnapshot>;
  invoke(action: ConnectionAction): Promise<unknown>;
  execute(command: ConnectionCommand): Promise<unknown>;
  resolveInstance(instanceId: string): Promise<ConnectionInstance>;
  recordProviderObservation(instanceId: string, setupRevision: number, observation: ProviderAdmissionObservation): Promise<void>;
}
