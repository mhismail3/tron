import {
  CONNECTION_STATE_SCHEMA_VERSION,
  type ConnectionPolicy, type ConnectionInstance,
  type RaindropCollectionMapping, type ConnectionOwnerState, type ConnectionOwnerReceipt,
} from "../modules/integrations/contract.js";

const ID = /^[A-Za-z0-9._:-]{1,160}$/;
const CREDENTIAL_REF = /^connector:[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._:-]{1,256}$/;

function assertConnectionId(value: unknown, label = "connection id"): asserts value is string {
  if (typeof value !== "string" || !ID.test(value) || value === "." || value === "..") throw new Error(`Invalid ${label}`);
}

function assertCredentialReference(value: unknown): asserts value is string {
  if (typeof value !== "string" || !CREDENTIAL_REF.test(value)) throw new Error("Credential reference is invalid");
}

function assertDefinitionId(value: unknown): asserts value is string {
  if (typeof value !== "string" || !ID.test(value)) throw new Error("Definition ID is invalid");
}

function bounded(value: unknown, label: string, maximum: number): asserts value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > maximum || /[\u0000-\u001f\u007f]/.test(value)) throw new Error(`${label} is invalid`);
}

function normalizeProviderDisplayName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const label = value.trim();
  return label.length > 0 && label.length <= 320 && !/[\u0000-\u001f\u007f]/.test(label) ? label : undefined;
}

function validateConnectionPolicy(value: unknown): asserts value is ConnectionPolicy {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Connection policy is invalid");
  const policy = value as Record<string, unknown>;
  if (typeof policy.enabled !== "boolean" || typeof policy.allowWrites !== "boolean" || typeof policy.paidAccessApproved !== "boolean" || typeof policy.recurringApproved !== "boolean"
    || !Number.isSafeInteger(policy.paidBudgetCents) || (policy.paidBudgetCents as number) < 0 || (policy.paidBudgetCents as number) > 1_000_000) throw new Error("Connection policy is invalid");
}

function validateConnectionInstance(value: unknown): asserts value is ConnectionInstance {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Connection instance is invalid");
  const item = value as Record<string, unknown>; assertConnectionId(item.id); assertDefinitionId(item.definitionId);
  if (item.implementation === "mcp") throw new Error(`MCP connection instance ${String(item.id)} is unsupported; configure MCP through Pi mcp.json`);
  if (item.implementation !== "knowledge-connector") throw new Error("Connection implementation is invalid");
  bounded(item.providerAccountId, "Provider account", 256); if (item.scope !== undefined) bounded(item.scope, "Connection scope", 512);
  assertCredentialReference(item.credentialRef); validateConnectionPolicy(item.policy);
  if (item.credentialAvailability !== undefined && !["available", "unavailable", "unknown"].includes(item.credentialAvailability as string) || item.providerIdentity !== undefined && !["admitted", "mismatch", "unknown"].includes(item.providerIdentity as string)) throw new Error("Connection admission observation is invalid");
  if (item.providerDisplayName !== undefined && normalizeProviderDisplayName(item.providerDisplayName) !== item.providerDisplayName) throw new Error("Provider display name is invalid");
  if (item.raindropCollections !== undefined) {
    if (item.definitionId !== "knowledge.raindrop") throw new Error("Only Raindrop connections may map collections");
    if (item.scope !== undefined) throw new Error("Raindrop collection mappings replace the single connector scope");
    validateRaindropCollectionMappings(item.raindropCollections);
  }
  if (item.configuration !== undefined) throw new Error(`MCP connection instance ${String(item.id)} is unsupported; configure MCP through Pi mcp.json`);
  if (!["unconfigured", "setup-required", "ready", "disabled", "auth-error", "error", "disconnected"].includes(item.health as string)) throw new Error("Connection health is invalid");
  for (const key of ["createdAt", "updatedAt"] as const) bounded(item[key], `Connection ${key}`, 64);
  if (!Number.isSafeInteger(item.setupRevision) || (item.setupRevision as number) < 0) throw new Error("Connection setup revision is invalid");
  if (item.lastError !== undefined) bounded(item.lastError, "Connection error", 4_096);
}

function validateRaindropCollectionMappings(value: unknown): asserts value is RaindropCollectionMapping[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 64) throw new Error("Raindrop collection mappings must contain 1..64 entries");
  const ids = new Set<string>();
  const homes = new Set<string>();
  for (const mapping of value) {
    if (!mapping || typeof mapping !== "object" || Array.isArray(mapping)) throw new Error("Raindrop collection mapping is invalid");
    const item = mapping as Record<string, unknown>;
    if (typeof item.collectionId !== "string" || !/^-?\d{1,18}$/.test(item.collectionId) || ids.has(item.collectionId)) throw new Error("Raindrop collection IDs must be unique numeric IDs");
    if (!["research", "personal", "archive", "triage"].includes(item.role as string)) throw new Error("Raindrop collection role is invalid");
    if (item.role !== "triage") {
      if (homes.has(item.role as string)) throw new Error(`Raindrop may have at most one ${item.role} home`);
      homes.add(item.role as string);
    }
    if ("scope" in item || "destination" in item) throw new Error("Raindrop collection mappings use roles only");
    ids.add(item.collectionId);
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
    if (!["oauth", "token", "browser"].includes(item.method as string) || !["pending", "completed", "cancelled"].includes(item.status as string)) throw new Error("Setup operation is invalid");
    bounded(item.createdAt, "Setup createdAt", 64); bounded(item.updatedAt, "Setup updatedAt", 64);
    if (id !== item.operationId) throw new Error("Setup operation map key does not match its ID");
  }
  for (const receipt of Object.values(state.receipts)) {
    if (!receipt || typeof receipt !== "object" || Array.isArray(receipt) || typeof (receipt as ConnectionOwnerReceipt).operation !== "string" || typeof (receipt as ConnectionOwnerReceipt).requestHash !== "string" || typeof (receipt as ConnectionOwnerReceipt).createdAt !== "string" || !("result" in receipt)) throw new Error("Connection receipt is invalid");
  }
}
