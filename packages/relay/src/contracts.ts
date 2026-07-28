export interface Env {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  TRON_RELAY_SECRET: string;
  RELAY_LEDGER: DurableObjectNamespace;
}

export type Environment = "sandbox" | "production";

export interface AlertRequest {
  kind: "alert";
  requestId: string;
  deviceToken: string;
  topic: string;
  environment: Environment;
  expiresAt: string;
  collapseId: string;
  title: string;
  body: string;
  threadKey?: string;
  category: "TRON_NOTIFICATION" | "TRON_REMINDER";
  badge: number;
  serverId: string;
  deliveryId: string;
}

export interface BackgroundRequest {
  kind: "background";
  requestId: string;
  deviceToken: string;
  topic: string;
  environment: Environment;
  expiresAt: string;
  collapseId: string;
  badge: number;
  serverId: string;
}

export type NotificationRequest = AlertRequest | BackgroundRequest;

export type RelayStatus =
  | "accepted_by_apns"
  | "retryable"
  | "permanent_failure"
  | "invalid_token"
  | "ambiguous";

export interface RelayResult {
  status: RelayStatus;
  apnsId?: string;
  reason?: string;
  retryAfterSeconds?: number;
}

export interface LedgerRow extends Record<string, SqlStorageValue> {
  state: string;
  response_json: string | null;
}

export const RELAY_PATH = "/v2/notification";
export const MAX_BODY_BYTES = 16 * 1024;
