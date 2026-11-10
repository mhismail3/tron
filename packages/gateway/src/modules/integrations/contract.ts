import type { JsonValue } from "../../protocol/types.js";

export const CONNECTION_STATE_SCHEMA_VERSION = 1 as const;
export type ConnectionSetupMethod = "oauth" | "token" | "browser";
export type ConnectionImplementationKind = "knowledge-connector";
export type ConnectionHealth = "unconfigured" | "setup-required" | "ready" | "disabled" | "auth-error" | "error" | "disconnected";
export type CredentialAvailability = "available" | "unavailable" | "unknown";
export type ProviderIdentityAdmission = "admitted" | "mismatch" | "unknown";

export interface ConnectionPolicy {
  enabled: boolean;
  allowWrites: boolean;
  paidAccessApproved: boolean;
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
  raindropCollections?: RaindropCollectionMapping[];
  policy: ConnectionPolicy;
  health: ConnectionHealth;
  createdAt: string;
  updatedAt: string;
  setupRevision: number;
  credentialAvailability?: CredentialAvailability;
  providerIdentity?: ProviderIdentityAdmission;
  providerDisplayName?: string;
  lastError?: string;
}

export type ConnectionInstanceProjection = Omit<ConnectionInstance, "credentialRef"> & { credentialConfigured: boolean };

export interface ConnectionSetupOperation {
  operationId: string;
  instanceId: string;
  definitionId: string;
  method: ConnectionSetupMethod;
  status: "pending" | "completed" | "cancelled";
  createdAt: string;
  updatedAt: string;
}

export interface ConnectionOwnerSnapshot {
  definitions: [];
  instances: ConnectionInstanceProjection[];
  setupOperations: ConnectionSetupOperation[];
  capabilities: [];
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

export interface ConnectionAccess {
  snapshot(): Promise<ConnectionOwnerSnapshot>;
}
