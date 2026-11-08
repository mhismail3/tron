import { readSecureJson, SecureJsonFileError } from "../foundation/secure-json.js";
import { GatewayError } from "../errors.js";
import {
  CONNECTION_STATE_SCHEMA_VERSION, CONNECTOR_CREDENTIAL_SERVICE,
  type ConnectionAccess,
  type ConnectionCapabilityStatus,
  type ConnectionInstanceProjection,
  type ConnectionOwnerSnapshot,
  type ConnectionOwnerState,
  type IntegrationDefinition,
} from "../modules/integrations/contract.js";
import { validateConnectionState, validateIntegrationDefinition } from "./connection-contract.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const STATE_MAX_BYTES = 4 * 1_048_576;

function initialState(): ConnectionOwnerState { return { schemaVersion: CONNECTION_STATE_SCHEMA_VERSION, stateRevision: 0, instances: {}, setupOperations: {}, receipts: {} }; }
function statePath(tronHome: string): string { return tronHomePath(tronHome, "gateway/integrations", "connections.json"); }
function copy<T>(value: T): T { return structuredClone(value); }

/** The presentation projection omits credential references, so an unadmitted
 * prerequisite names the Keychain service that owns the item instead of the
 * exact account; the agent-facing connector error carries the account.
 * `unavailable` is recorded both for a missing item and for a token the
 * provider rejected, so the text covers both. */
function prerequisiteDetail(instance: ConnectionInstanceProjection): string {
  return instance.credentialAvailability === "unavailable"
    ? `Credential missing or rejected. Check the Mac Keychain item (service '${CONNECTOR_CREDENTIAL_SERVICE}'); ask the agent for the exact account.`
    : "Connection prerequisites are not admitted";
}

function capabilityAvailability(
  capability: IntegrationDefinition["capabilities"][number],
  instance: ConnectionInstanceProjection
): { availability: ConnectionCapabilityStatus["availability"]; detail?: string } {
  if (!capability.supported) return { availability: "unsupported", detail: "Capability is not implemented by this adapter" };
  if (instance.health === "disconnected") return { availability: "unavailable", detail: "Connection is disconnected" };
  if (!instance.policy.enabled) return { availability: "disabled", detail: "Connection is disabled by policy" };
  const providerPrerequisitesAdmitted = instance.credentialAvailability === "available" && instance.providerIdentity === "admitted";
  if (instance.health !== "ready" || !providerPrerequisitesAdmitted) {
    return { availability: "unavailable", detail: instance.lastError ?? prerequisiteDetail(instance) };
  }
  if (capability.effects.includes("write") && !instance.policy.allowWrites) {
    return { availability: "unavailable", detail: "Write approval is required for this capability" };
  }
  if (capability.effects.includes("paid") && !instance.policy.paidAccessApproved) {
    return { availability: "unavailable", detail: "Paid access approval is required for this capability" };
  }
  if (capability.effects.includes("paid") && instance.policy.paidBudgetCents <= 0) {
    return { availability: "unavailable", detail: "A positive paid-access budget is required for this capability" };
  }
  return { availability: "available" };
}

export class ConnectionOwner implements ConnectionAccess {
  private readonly definitions: IntegrationDefinition[];
  constructor(
    private readonly tronHome: string,
    definitions: readonly IntegrationDefinition[] = [],
  ) {
    this.definitions = definitions.map(definition => { validateIntegrationDefinition(definition); return copy(definition); });
    if (new Set(this.definitions.map(definition => definition.id)).size !== this.definitions.length) throw new Error("Integration definition IDs must be unique");
  }

  /** Read-only: this owner never initializes, migrates or writes state. A
   * missing file is an empty projection. */
  async snapshot(): Promise<ConnectionOwnerSnapshot> {
    return this.snapshotOf(await this.load());
  }

  private snapshotOf(state: ConnectionOwnerState): ConnectionOwnerSnapshot {
    const instances: ConnectionInstanceProjection[] = Object.values(state.instances).map(instance => {
      const { credentialRef: _credentialRef, ...projection } = copy(instance);
      return { ...projection, credentialConfigured: Boolean(instance.credentialRef), credentialAvailability: instance.credentialAvailability ?? "unknown", providerIdentity: instance.providerIdentity ?? "unknown" };
    });
    const capabilities: ConnectionCapabilityStatus[] = [];
    for (const definition of this.definitions) for (const capability of definition.capabilities) {
      const matching = instances.filter(instance => instance.definitionId === definition.id);
      if (matching.length === 0) {
        capabilities.push({ id: capability.id, availability: capability.supported ? "requires-setup" : "unsupported", effects: [...capability.effects], definitionId: definition.id, provenance: { owner: "connection", definitionId: definition.id }, ...(capability.supported ? {} : { detail: "Capability is not implemented by this adapter" }) });
      } else for (const instance of matching) {
        const status = capabilityAvailability(capability, instance);
        capabilities.push({ id: capability.id, availability: status.availability, effects: [...capability.effects], definitionId: definition.id, connectionId: instance.id, provenance: { owner: "connection", definitionId: definition.id, connectionId: instance.id }, ...(status.detail ? { detail: status.detail } : {}) });
      }
    }
    return { definitions: this.definitions.map(copy), instances, setupOperations: Object.values(state.setupOperations).map(copy), capabilities, stateRevision: state.stateRevision };
  }

  private async load(): Promise<ConnectionOwnerState> {
    const path = statePath(this.tronHome);
    let read;
    try { read = await readSecureJson<unknown>(path, STATE_MAX_BYTES); }
    catch (error) { if (error instanceof SecureJsonFileError) throw new GatewayError("conflict", `Connection state is unavailable: ${error.message}`); throw error; }
    if (!read.present) return initialState();
    try {
      const persisted = read.value as ConnectionOwnerState;
      const loaded = copy(persisted);
      validateConnectionState(loaded);
      return loaded;
    } catch (error) { throw new GatewayError("conflict", error instanceof Error ? `Connection state is unavailable: ${error.message}` : "Connection state is unavailable"); }
  }
}
