import { readSecureJson, SecureJsonFileError } from "../foundation/secure-json.js";
import { GatewayError } from "../errors.js";
import {
  CONNECTION_STATE_SCHEMA_VERSION,
  type ConnectionAccess,
  type ConnectionInstanceProjection,
  type ConnectionOwnerSnapshot,
  type ConnectionOwnerState,
} from "../modules/integrations/contract.js";
import { validateConnectionState } from "./connection-contract.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const STATE_MAX_BYTES = 4 * 1_048_576;

function initialState(): ConnectionOwnerState { return { schemaVersion: CONNECTION_STATE_SCHEMA_VERSION, stateRevision: 0, instances: {}, setupOperations: {}, receipts: {} }; }
function statePath(tronHome: string): string { return tronHomePath(tronHome, "state/integrations", "connections.json"); }
function copy<T>(value: T): T { return structuredClone(value); }

export class ConnectionOwner implements ConnectionAccess {
  constructor(private readonly tronHome: string) {}

  async snapshot(): Promise<ConnectionOwnerSnapshot> {
    return this.snapshotOf(await this.load());
  }

  private snapshotOf(state: ConnectionOwnerState): ConnectionOwnerSnapshot {
    const instances: ConnectionInstanceProjection[] = Object.values(state.instances).map(instance => {
      const { credentialRef: _credentialRef, ...projection } = copy(instance);
      return { ...projection, credentialConfigured: Boolean(instance.credentialRef), credentialAvailability: instance.credentialAvailability ?? "unknown", providerIdentity: instance.providerIdentity ?? "unknown" };
    });
    return { definitions: [], instances, setupOperations: Object.values(state.setupOperations).map(copy), capabilities: [], stateRevision: state.stateRevision };
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
