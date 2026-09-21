import { randomUUID } from "node:crypto";
import { lstat, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import { GatewayError } from "../errors.js";
import {
  CONNECTION_STATE_SCHEMA_VERSION,
  type ConnectionAction,
  type ConnectionCapabilityStatus,
  type ConnectionCommand,
  type ConnectionInstance,
  type ConnectionInstanceProjection,
  type ConnectionOwnerReceipt,
  type ConnectionOwnerSnapshot,
  type ConnectionOwnerState,
  type ConnectionPolicy,
  type ConnectionSetupOperation,
  type ProviderAdmissionObservation,
  type IntegrationDefinition,
  type RuntimeBinding,
  assertConnectionId,
  assertDefinitionId,
  assertCredentialReference,
  connectionRequestHash,
  validateConnectionInstance,
  validateConnectionPolicy,
  validateConnectionState,
  validateMcpConnectionConfiguration,
  validateIntegrationDefinition,
  validateRuntimeBinding,
} from "./connection-contract.js";

const MAX_RECEIPTS = 256;
const STATE_MAX_BYTES = 4 * 1_048_576;
const CONNECTION_STATE_RELATIVE_PATH = ["state", "integrations", "connections.json"] as const;

export const BUILTIN_INTEGRATION_DEFINITIONS: readonly IntegrationDefinition[] = [
  {
    schemaVersion: 1,
    id: "knowledge.raindrop",
    implementation: "knowledge-connector",
    displayName: "Raindrop",
    setupMethods: ["token"],
    capabilities: [
      { id: "read", displayName: "Read bookmarks", effects: ["read"], supported: true },
      { id: "intake", displayName: "Capture bookmarks", effects: ["read", "disclosure"], supported: true },
      { id: "move", displayName: "Move bookmarks", effects: ["write"], supported: true },
      { id: "assess", displayName: "Assess sources", effects: ["paid"], supported: true },
    ],
  },
  {
    schemaVersion: 1,
    id: "knowledge.x",
    implementation: "knowledge-connector",
    displayName: "X bookmarks",
    setupMethods: ["token"],
    capabilities: [{ id: "read", displayName: "Read bookmarks", effects: ["read"], supported: true }],
  },
  {
    schemaVersion: 1,
    id: "mcp.remote-http",
    implementation: "mcp",
    displayName: "MCP server",
    setupMethods: ["endpoint", "token", "local-command"],
    capabilities: [{ id: "tools", displayName: "Tools", effects: ["read", "write", "disclosure"], supported: true }],
  },
];

function invalid(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function conflict(message: string): GatewayError { return new GatewayError("conflict", message); }
function unsupported(message: string): GatewayError { return new GatewayError("unsupported", message); }
function now(): string { return new Date().toISOString(); }
function initialState(): ConnectionOwnerState { return { schemaVersion: CONNECTION_STATE_SCHEMA_VERSION, stateRevision: 0, instances: {}, setupOperations: {}, receipts: {} }; }
function statePath(tronHome: string): string { return join(tronHome, ...CONNECTION_STATE_RELATIVE_PATH); }
function copy<T>(value: T): T { return structuredClone(value); }

function validateCommand(command: ConnectionCommand): void {
  if (!command || typeof command !== "object") throw invalid("Connection command is invalid");
  if (typeof command.commandId !== "string" || command.commandId.length < 8 || command.commandId.length > 160) throw invalid("Connection commandId is invalid");
  if (command.kind === "setup.begin") { assertConnectionId(command.instanceId); assertDefinitionId(command.definitionId); if (!["oauth", "token", "local-command", "endpoint", "browser"].includes(command.method)) throw invalid("Connection setup method is invalid"); return; }
  if (command.kind === "setup.complete") {
    assertConnectionId(command.operationId, "setup operation id"); assertConnectionId(command.instanceId); if (typeof command.providerAccountId !== "string" || command.providerAccountId.length < 1 || command.providerAccountId.length > 256) throw invalid("Provider account is invalid");
    if (command.scope !== undefined && (typeof command.scope !== "string" || command.scope.length < 1 || command.scope.length > 512)) throw invalid("Connection scope is invalid");
    assertCredentialReference(command.credentialRef); validateConnectionPolicy(command.policy);
    if (command.configuration !== undefined) validateMcpConnectionConfiguration(command.configuration);
    return;
  }
  if (command.kind === "setup.cancel") { assertConnectionId(command.operationId, "setup operation id"); assertConnectionId(command.instanceId); return; }
  assertConnectionId(command.instanceId); if (command.kind === "policy.update") validateConnectionPolicy(command.policy);
}

function resultForInstance(instance: ConnectionInstance): Record<string, unknown> {
  return { id: instance.id, definitionId: instance.definitionId, implementation: instance.implementation, providerAccountId: instance.providerAccountId, ...(instance.scope ? { scope: instance.scope } : {}), policy: instance.policy, health: instance.health, createdAt: instance.createdAt, updatedAt: instance.updatedAt, setupRevision: instance.setupRevision, ...(instance.lastError ? { lastError: instance.lastError } : {}) };
}

export class ConnectionOwner {
  private readonly mutex = new AsyncMutex();
  private readonly definitions: IntegrationDefinition[];
  constructor(private readonly tronHome: string, definitions: readonly IntegrationDefinition[] = BUILTIN_INTEGRATION_DEFINITIONS) {
    this.definitions = definitions.map(definition => { validateIntegrationDefinition(definition); return copy(definition); });
    if (new Set(this.definitions.map(definition => definition.id)).size !== this.definitions.length) throw new Error("Integration definition IDs must be unique");
  }

  /** This owner does not initialize or migrate state at Gateway startup. A
   * missing file is an empty projection; publication only follows an explicit
   * accepted setup/policy/disconnect command. */
  async snapshot(): Promise<ConnectionOwnerSnapshot> {
    return this.mutex.run(async () => {
      const state = await this.load(false);
      return this.snapshotOf(state);
    });
  }

  async invoke(action: ConnectionAction): Promise<unknown> {
    if (action.operation === "connections.list") return this.snapshot();
    // The wire operation names are explicit; do not accept a generic enable or
    // disable alias that could bypass setup/policy/disconnect ownership.
    const expected: Record<string, ConnectionCommand["kind"]> = {
      "connections.setup.begin": "setup.begin", "connections.setup.complete": "setup.complete", "connections.setup.cancel": "setup.cancel",
      "connections.policy.update": "policy.update", "connections.disconnect": "disconnect",
    };
    const kind = expected[action.operation];
    if (!kind) throw unsupported("Unsupported connection operation");
    return this.execute({ kind, ...action.request } as ConnectionCommand);
  }

  async execute(command: ConnectionCommand): Promise<unknown> {
    try { validateCommand(command); } catch (error) { if (error instanceof GatewayError) throw error; throw invalid(error instanceof Error ? error.message : "Connection command is invalid"); }
    return this.mutex.run(async () => {
      const state = await this.load(true);
      const operation = command.kind;
      const hash = connectionRequestHash(operation, command);
      const prior = state.receipts[command.commandId];
      if (prior) {
        if (prior.operation !== operation || prior.requestHash !== hash) throw conflict("Connection commandId was already used for a different request");
        return copy(prior.result);
      }
      const value = this.apply(state, command);
      const receipt: ConnectionOwnerReceipt = { operation, requestHash: hash, createdAt: now(), result: value as ConnectionOwnerReceipt["result"] };
      state.receipts[command.commandId] = receipt;
      const entries = Object.entries(state.receipts).sort(([, left], [, right]) => left.createdAt.localeCompare(right.createdAt));
      for (const [id] of entries.slice(0, Math.max(0, entries.length - MAX_RECEIPTS))) delete state.receipts[id];
      state.stateRevision += 1;
      validateConnectionState(state);
      await this.save(state);
      return copy(value);
    });
  }

  /** Adapter-owned admission observations are bounded and revision-fenced. They
   * are never inferred from setup intent and are not polled during projection. */
  async recordProviderObservation(instanceId: string, setupRevision: number, observation: ProviderAdmissionObservation): Promise<void> {
    assertConnectionId(instanceId);
    return this.mutex.run(async () => {
      const state = await this.load(true);
      const instance = state.instances[instanceId];
      if (!instance || instance.setupRevision !== setupRevision || !instance.policy.enabled || instance.health === "disconnected") throw conflict("Connection instance is no longer admitted");
      if (!["available", "unavailable", "unknown"].includes(observation.credentialAvailability) || !["admitted", "mismatch", "unknown"].includes(observation.providerIdentity)) throw invalid("Provider admission observation is invalid");
      instance.credentialAvailability = observation.credentialAvailability;
      instance.providerIdentity = observation.providerIdentity;
      instance.health = observation.credentialAvailability === "available" && observation.providerIdentity === "admitted" ? "ready" : observation.credentialAvailability === "unavailable" || observation.providerIdentity === "mismatch" ? "auth-error" : "setup-required";
      instance.updatedAt = now();
      state.stateRevision += 1;
      validateConnectionState(state);
      await this.save(state);
    });
  }

  /** Adapter owners may resolve the private envelope internally. Callers must
   * never serialize the returned credential reference. */
  async resolveInstance(instanceId: string): Promise<ConnectionInstance> {
    assertConnectionId(instanceId);
    return this.mutex.run(async () => {
      const state = await this.load(false);
      const instance = state.instances[instanceId];
      if (!instance) throw conflict("Connection instance is unknown");
      return copy(instance);
    });
  }

  /** A transport adapter calls this only after successful handshake and tool
   * discovery. Setup alone must not project an MCP endpoint as available. */
  async markRuntimeReady(instanceId: string, setupRevision: number): Promise<void> {
    assertConnectionId(instanceId);
    return this.mutex.run(async () => {
      const state = await this.load(true);
      const instance = state.instances[instanceId];
      if (!instance || instance.setupRevision !== setupRevision || !instance.policy.enabled || instance.health === "disabled" || instance.health === "disconnected") throw conflict("Connection instance is no longer admitted");
      if (instance.health === "ready") return;
      if (instance.health !== "setup-required") throw conflict("Connection instance is not awaiting runtime admission");
      instance.health = "ready";
      instance.updatedAt = now();
      state.stateRevision += 1;
      validateConnectionState(state);
      await this.save(state);
    });
  }

  /** Runtime owners call this during admission; no binding is persisted and a
   * disabled/disconnected account cannot be inherited by a child runtime. */
  async admitRuntimeBinding(binding: RuntimeBinding): Promise<RuntimeBinding> {
    validateRuntimeBinding(binding);
    const snapshot = await this.snapshot();
    const definition = snapshot.definitions.find(item => item.id === binding.integrationId);
    if (!definition) throw unsupported("Integration definition is unavailable");
    const capability = definition.capabilities.find(item => item.id === binding.capabilityId);
    if (!capability || !capability.supported) throw unsupported("Integration capability is unavailable");
    if (binding.connectionId === undefined) {
      if (definition.implementation !== "knowledge-connector") throw conflict("This capability requires a connection instance");
      return copy(binding);
    }
    const instance = snapshot.instances.find(item => item.id === binding.connectionId);
    if (!instance || instance.definitionId !== binding.integrationId || instance.health !== "ready" || !instance.policy.enabled) throw conflict("Connection instance is not admitted for this runtime");
    return copy(binding);
  }

  private snapshotOf(state: ConnectionOwnerState): ConnectionOwnerSnapshot {
    const instances: ConnectionInstanceProjection[] = Object.values(state.instances).map(instance => {
      const { credentialRef: _credentialRef, configuration: _configuration, ...projection } = copy(instance);
      return { ...projection, credentialConfigured: Boolean(instance.credentialRef), credentialAvailability: instance.credentialAvailability ?? "unknown", providerIdentity: instance.providerIdentity ?? "unknown" };
    });
    const capabilities: ConnectionCapabilityStatus[] = [];
    for (const definition of this.definitions) for (const capability of definition.capabilities) {
      const matching = instances.filter(instance => instance.definitionId === definition.id);
      if (matching.length === 0) {
        capabilities.push({ id: capability.id, availability: capability.supported ? "requires-setup" : "unsupported", effects: [...capability.effects], definitionId: definition.id, provenance: { owner: "connection", definitionId: definition.id }, ...(capability.supported ? {} : { detail: "Capability is not implemented by this adapter" }) });
      } else for (const instance of matching) capabilities.push({ id: capability.id, availability: !capability.supported ? "unsupported" : instance.health === "ready" && instance.policy.enabled && (instance.credentialAvailability ?? "unknown") === "available" && (instance.providerIdentity ?? "unknown") === "admitted" ? "available" : instance.health === "disconnected" ? "unavailable" : instance.policy.enabled ? "unavailable" : "disabled", effects: [...capability.effects], definitionId: definition.id, connectionId: instance.id, provenance: { owner: "connection", definitionId: definition.id, connectionId: instance.id }, ...(instance.lastError ? { detail: instance.lastError } : {}) });
    }
    return { definitions: this.definitions.map(copy), instances, setupOperations: Object.values(state.setupOperations).map(copy), capabilities, stateRevision: state.stateRevision };
  }

  private apply(state: ConnectionOwnerState, command: ConnectionCommand): unknown {
    const timestamp = now();
    if (command.kind === "setup.begin") {
      const definition = this.definitions.find(item => item.id === command.definitionId);
      if (!definition || !definition.setupMethods.includes(command.method)) throw unsupported("Setup method is not supported by this integration");
      const existing = state.instances[command.instanceId]; if (existing && existing.health !== "disconnected") throw conflict("Connection instance already exists; use a new instance ID");
      const active = Object.values(state.setupOperations).find(item => item.instanceId === command.instanceId && item.status === "pending");
      if (active) return { operationId: active.operationId, instanceId: active.instanceId, status: active.status };
      const operation: ConnectionSetupOperation = { operationId: randomUUID(), instanceId: command.instanceId, definitionId: command.definitionId, method: command.method, status: "pending", createdAt: timestamp, updatedAt: timestamp };
      state.setupOperations[operation.operationId] = operation;
      return { operationId: operation.operationId, instanceId: operation.instanceId, definitionId: operation.definitionId, method: operation.method, status: operation.status };
    }
    if (command.kind === "setup.complete") {
      const operation = state.setupOperations[command.operationId];
      if (!operation || operation.instanceId !== command.instanceId) throw conflict("Setup operation is unknown or belongs to another instance");
      if (operation.status !== "pending") throw conflict("Setup operation is no longer pending");
      const definition = this.definitions.find(item => item.id === operation.definitionId); if (!definition) throw unsupported("Integration definition is unavailable");
      if (definition.implementation === "knowledge-connector" && !command.credentialRef.startsWith(`connector:${definition.id.slice("knowledge.".length)}:`)) throw invalid("Credential reference does not belong to this integration");
      const existing = state.instances[command.instanceId]; if (existing && existing.health !== "disconnected") throw conflict("Connection instance already exists");
      if (definition.implementation === "mcp" && command.configuration === undefined) throw invalid("MCP setup requires transport configuration");
      if (definition.implementation === "mcp" && operation.method === "endpoint" && command.configuration?.transport !== "http") throw invalid("Endpoint setup requires HTTP MCP configuration");
      if (definition.implementation === "mcp" && operation.method === "local-command" && command.configuration?.transport !== "stdio") throw invalid("Local command setup requires stdio MCP configuration");
      if (definition.implementation !== "mcp" && command.configuration !== undefined) throw invalid("Only MCP connections accept transport configuration");
      const instance: ConnectionInstance = { id: command.instanceId, definitionId: definition.id, implementation: definition.implementation, providerAccountId: command.providerAccountId, ...(command.scope ? { scope: command.scope } : {}), credentialRef: command.credentialRef, ...(command.configuration ? { configuration: copy(command.configuration) } : {}), policy: copy(command.policy), health: command.policy.enabled ? "setup-required" : "disabled", createdAt: existing?.createdAt ?? timestamp, updatedAt: timestamp, setupRevision: (existing?.setupRevision ?? 0) + 1, credentialAvailability: "unknown", providerIdentity: "unknown" };
      state.instances[instance.id] = instance; operation.status = "completed"; operation.updatedAt = timestamp;
      return resultForInstance(instance);
    }
    const operation = command.kind === "setup.cancel" ? state.setupOperations[command.operationId] : undefined;
    if (command.kind === "setup.cancel") {
      if (!operation || operation.instanceId !== command.instanceId) throw conflict("Setup operation is unknown or belongs to another instance");
      if (operation.status !== "pending") throw conflict("Setup operation is no longer pending"); operation.status = "cancelled"; operation.updatedAt = timestamp;
      return { operationId: operation.operationId, instanceId: operation.instanceId, status: operation.status };
    }
    const instance = state.instances[command.instanceId]; if (!instance) throw conflict("Connection instance is unknown");
    if (instance.health === "disconnected") throw conflict("Connection instance is disconnected");
    if (command.kind === "policy.update") {
      instance.policy = copy(command.policy); instance.health = command.policy.enabled ? "setup-required" : "disabled"; instance.credentialAvailability = "unknown"; instance.providerIdentity = "unknown"; instance.updatedAt = timestamp; instance.setupRevision += 1; delete instance.lastError;
      return resultForInstance(instance);
    }
    instance.health = "disconnected"; instance.policy = { ...instance.policy, enabled: false }; instance.updatedAt = timestamp; instance.setupRevision += 1;
    return resultForInstance(instance);
  }

  private async load(writable: boolean): Promise<ConnectionOwnerState> {
    const path = statePath(this.tronHome);
    let read;
    try { read = await readSecureJson<unknown>(path, STATE_MAX_BYTES); }
    catch (error) { if (error instanceof SecureJsonFileError) throw new GatewayError("conflict", `Connection state is unavailable: ${error.message}`); throw error; }
    if (!read.present) return initialState();
    try { validateConnectionState(read.value); return copy(read.value); }
    catch (error) { throw new GatewayError("conflict", error instanceof Error ? `Connection state is unavailable: ${error.message}` : "Connection state is unavailable"); }
  }

  private async save(state: ConnectionOwnerState): Promise<void> {
    const stateRoot = join(this.tronHome, "state");
    const root = join(stateRoot, "integrations");
    for (const path of [stateRoot, root]) {
      try {
        const info = await lstat(path);
        if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) throw new GatewayError("conflict", "Connection state directory must be owner-only");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        await mkdir(path, { mode: 0o700 });
      }
    }
    await durableAtomicWriteJson(statePath(this.tronHome), state, 0o600);
  }
}

export function connectionStatePath(tronHome: string): string { return statePath(tronHome); }
