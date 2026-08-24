export interface Env {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APPLE_TEAM_ID: string;
  PUSH_REGISTRY: DurableObjectNamespace;
}

export type PushRoute = "beta" | "production-sandbox" | "production";
export type ApnsEnvironment = "sandbox" | "production";
export type AttestationEnvironment = "development" | "production";

export interface RouteDefinition {
  bundleId: string;
  topic: string;
  apnsEnvironment: ApnsEnvironment;
  attestationEnvironment: AttestationEnvironment;
}

export const ROUTES: Readonly<Record<PushRoute, RouteDefinition>> = {
  beta: {
    bundleId: "com.tron.mobile.beta",
    topic: "com.tron.mobile.beta",
    apnsEnvironment: "sandbox",
    attestationEnvironment: "development",
  },
  "production-sandbox": {
    bundleId: "com.tron.mobile",
    topic: "com.tron.mobile",
    apnsEnvironment: "sandbox",
    attestationEnvironment: "development",
  },
  production: {
    bundleId: "com.tron.mobile",
    topic: "com.tron.mobile",
    apnsEnvironment: "production",
    attestationEnvironment: "production",
  },
};

export interface RegistrationFields {
  version: 1;
  challengeId: string;
  challenge: string;
  keyId: string;
  apnsToken: string;
  route: PushRoute;
  bindingHash: string;
}

export interface AttestationRegistration extends RegistrationFields {
  proof: "attestation";
  attestationObject: string;
}

export interface AssertionRegistration extends RegistrationFields {
  proof: "assertion";
  assertionObject: string;
}

export type InstallationRegistration = AttestationRegistration | AssertionRegistration;

export interface NotificationRequest {
  version: 1;
  kind: "agent_alert";
  requestId: string;
  message: string;
  expiresAt: string;
}

export type RelayStatus =
  | "accepted_by_apns"
  | "retryable"
  | "permanent_failure"
  | "invalid_token"
  | "rate_limited"
  | "ambiguous";

export interface RelayResult {
  status: RelayStatus;
  apnsId?: string;
  reason?: string;
  retryAfterSeconds?: number;
}

export interface RegistrationResult {
  version: 1;
  installationId: string;
  grantId: string;
  grantSecret: string;
  route: PushRoute;
}

export interface StoredInstallation extends Record<string, SqlStorageValue> {
  installation_id: string;
  key_id: string;
  public_key_spki: string;
  route: PushRoute;
  apns_token: string;
  token_hash: string;
  assertion_counter: number;
  enabled: number;
}

export interface StoredGrant extends Record<string, SqlStorageValue> {
  grant_id: string;
  installation_id: string;
  binding_hash: string;
  secret: string;
  enabled: number;
  hourly_window: number;
  hourly_count: number;
  daily_window: number;
  daily_count: number;
}

export interface LedgerRow extends Record<string, SqlStorageValue> {
  grant_id: string;
  body_hash: string;
  state: string;
  response_json: string | null;
  quota_charged: number;
}

export const CHALLENGE_PATH = "/v3/attestation/challenge";
export const INSTALLATIONS_PATH = "/v3/installations";
export const NOTIFICATIONS_PATH = "/v3/notifications";
export const GRANT_PATH_PREFIX = "/v3/grants/";
export const MAX_BODY_BYTES = 16 * 1024;
export const MAX_MESSAGE_BYTES = 512;
export const REGISTRY_NAME = "push-registry-v3";
