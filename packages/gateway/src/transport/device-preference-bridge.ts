import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";

export const DEVICE_PREFERENCE_REQUEST_TOPIC = "device.preference.request";
export const DEVICE_PREFERENCE_DEADLINE_MS = 10_000;
export const DEVICE_PREFERENCE_CAPABILITY = "device-preference";

export type DevicePreferenceRead = { status: "value"; value: unknown } | { status: "unavailable" } | { status: "unknown" };
export type DevicePreferenceWrite = { status: "applied" } | { status: "conflict"; current: unknown } | { status: "unavailable" } | { status: "unknown" };
type Outcome = DevicePreferenceRead | DevicePreferenceWrite;

export interface DevicePreferenceBridgeOptions {
  pairedDevices(): Promise<readonly string[]>;
  newestReadyConnection(deviceId: string, capability: string): string | undefined;
  send(connectionId: string, topic: string, payload: JsonValue): boolean;
  deadlineMs?: number;
}

interface Pending {
  action: "read" | "set";
  deviceId: string;
  connectionId: string;
  resolve(outcome: Outcome): void;
  timer: ReturnType<typeof setTimeout>;
}

export interface DevicePreferenceCaller { id: string; identity: string; isLocal: boolean }

export class DevicePreferenceBridge {
  private readonly pending = new Map<string, Pending>();
  private readonly deadlineMs: number;
  private disposed = false;

  constructor(private readonly options: DevicePreferenceBridgeOptions) {
    this.deadlineMs = options.deadlineMs ?? DEVICE_PREFERENCE_DEADLINE_MS;
  }

  async devices(): Promise<readonly string[]> {
    return this.options.pairedDevices();
  }

  read(deviceId: string, keyId: string): Promise<DevicePreferenceRead> {
    return this.request(deviceId, "read", { key: keyId }) as Promise<DevicePreferenceRead>;
  }

  compareAndSet(deviceId: string, keyId: string, expected: unknown, value: unknown): Promise<DevicePreferenceWrite> {
    return this.request(deviceId, "set", { key: keyId, expected: expected as JsonValue, value: value as JsonValue }) as Promise<DevicePreferenceWrite>;
  }

  reply(caller: DevicePreferenceCaller, requestId: string, body: { status: string; value?: unknown; current?: unknown }): void {
    if (caller.isLocal) throw new GatewayError("auth_required", "Only a paired iPhone can answer a device preference request");
    const entry = this.pending.get(requestId);
    if (!entry || entry.connectionId !== caller.id || entry.deviceId !== caller.identity) {
      throw new GatewayError("not_found", "Device preference request is no longer pending");
    }
    if (entry.action === "read" && this.options.newestReadyConnection(entry.deviceId, DEVICE_PREFERENCE_CAPABILITY) !== entry.connectionId) {
      this.settle(requestId, undefined);
      throw new GatewayError("conflict", "Device preference read was superseded by a newer connection; no value was published");
    }
    this.settle(requestId, parseOutcome(entry.action, body));
  }

  detachConnection(connectionId: string): void {
    for (const [requestId, entry] of this.pending) if (entry.connectionId === connectionId) this.settle(requestId, undefined);
  }

  dispose(): void {
    this.disposed = true;
    for (const requestId of [...this.pending.keys()]) this.settle(requestId, undefined);
  }

  private request(deviceId: string, action: "read" | "set", fields: Record<string, JsonValue>): Promise<Outcome> {
    const connectionId = this.disposed ? undefined : this.options.newestReadyConnection(deviceId, DEVICE_PREFERENCE_CAPABILITY);
    if (connectionId === undefined) return Promise.resolve({ status: "unavailable" });
    const requestId = randomUUID();
    return new Promise<Outcome>((resolve) => {
      const timer = setTimeout(() => this.settle(requestId, undefined), this.deadlineMs);
      this.pending.set(requestId, { action, deviceId, connectionId, resolve, timer });
      let sent = false;
      try {
        sent = this.options.send(connectionId, DEVICE_PREFERENCE_REQUEST_TOPIC, { requestId, action, ...fields });
      } catch {
        sent = false;
      }
      if (!sent) this.settle(requestId, { status: "unavailable" });
    });
  }

  private settle(requestId: string, outcome: Outcome | undefined): void {
    const entry = this.pending.get(requestId);
    if (!entry) return;
    this.pending.delete(requestId);
    clearTimeout(entry.timer);
    entry.resolve(outcome ?? (entry.action === "read" ? { status: "unavailable" } : { status: "unknown" }));
  }
}

function parseOutcome(action: "read" | "set", body: { status: string; value?: unknown; current?: unknown }): Outcome {
  if (action === "read" && body.status === "value" && typeof body.value === "boolean") return { status: "value", value: body.value };
  if (action === "set" && body.status === "applied") return { status: "applied" };
  if (action === "set" && body.status === "conflict" && typeof body.current === "boolean") return { status: "conflict", current: body.current };
  throw new GatewayError("invalid_request", "Device preference reply does not match its request");
}
