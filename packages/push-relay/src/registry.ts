import { sendToApns } from "./apns";
import { verifyAssertion, verifyAttestation } from "./app-attest";
import { verifyGrantSignature } from "./authentication";
import {
  GRANT_PATH_PREFIX,
  ROUTES,
  type Env,
  type InstallationRegistration,
  type LedgerRow,
  type NotificationRequest,
  type RegistrationResult,
  type RelayResult,
  type StoredGrant,
  type StoredInstallation,
} from "./contracts";
import {
  canonicalRegistration,
  constantTimeEqual,
  decodeBase64Url,
  randomOpaqueId,
  sha256,
  sha256Hex,
  utf8,
} from "./crypto";
import { json } from "./response";
import { isOpaqueId, validateNotification, validateRegistration } from "./validation";

const CHALLENGE_TTL_SECONDS = 5 * 60;
const MAX_ACTIVE_CHALLENGES = 4096;
const MAX_CHALLENGES_PER_MINUTE = 300;
const MAX_CHALLENGE_ATTEMPTS = 3;
const MAX_INSTALLATIONS = 50_000;
const MAX_GRANTS = 100_000;
const MAX_GRANTS_PER_INSTALLATION = 8;
const HOURLY_LIMIT = 30;
const DAILY_LIMIT = 200;
const INSTALLATION_HOURLY_LIMIT = 50;
const INSTALLATION_DAILY_LIMIT = 300;
const RECEIPT_RETENTION_SECONDS = 7 * 24 * 60 * 60;
// APNs owns a 15-second timeout. A second request inside this wider bound can
// safely poll the exact in-flight provider attempt; beyond it, a crashed Worker
// may have left outcome ownership permanently unknowable.
const ACTIVE_PROVIDER_ATTEMPT_SECONDS = 30;
const DISABLED_RETENTION_SECONDS = 30 * 24 * 60 * 60;

interface ChallengeRow extends Record<string, SqlStorageValue> {
  challenge_hash: string;
  expires_at: number;
  consumed_at: number | null;
  attempt_count: number;
}

export class PushRegistry {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    this.state.blockConcurrencyWhile(async () => {
      this.state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS challenges (
          challenge_id TEXT PRIMARY KEY,
          challenge_hash TEXT NOT NULL,
          expires_at INTEGER NOT NULL,
          consumed_at INTEGER,
          attempt_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS installations (
          installation_id TEXT PRIMARY KEY,
          key_id TEXT NOT NULL UNIQUE,
          public_key_spki TEXT NOT NULL,
          route TEXT NOT NULL,
          apns_token TEXT NOT NULL,
          token_hash TEXT NOT NULL,
          assertion_counter INTEGER NOT NULL,
          enabled INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS grants (
          grant_id TEXT PRIMARY KEY,
          installation_id TEXT NOT NULL,
          binding_hash TEXT NOT NULL,
          secret TEXT NOT NULL,
          enabled INTEGER NOT NULL,
          hourly_window INTEGER NOT NULL,
          hourly_count INTEGER NOT NULL,
          daily_window INTEGER NOT NULL,
          daily_count INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          UNIQUE(installation_id, binding_hash)
        );
        CREATE TABLE IF NOT EXISTS service_limits (
          key TEXT PRIMARY KEY,
          window_start INTEGER NOT NULL,
          count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS installation_limits (
          installation_id TEXT PRIMARY KEY,
          hourly_window INTEGER NOT NULL,
          hourly_count INTEGER NOT NULL,
          daily_window INTEGER NOT NULL,
          daily_count INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS relay_requests (
          request_id TEXT PRIMARY KEY,
          grant_id TEXT NOT NULL,
          body_hash TEXT NOT NULL,
          state TEXT NOT NULL,
          response_json TEXT,
          quota_charged INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS grants_installation_idx ON grants(installation_id);
        CREATE INDEX IF NOT EXISTS relay_requests_updated_idx ON relay_requests(updated_at);
      `);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/v3/attestation/challenge") return this.createChallenge();
    if (request.method === "POST" && url.pathname === "/v3/installations") return this.registerInstallation(request);
    if (request.method === "POST" && url.pathname === "/v3/notifications") return this.dispatch(request);
    if (request.method === "DELETE" && url.pathname.startsWith(GRANT_PATH_PREFIX)) return this.revoke(request, url.pathname);
    return json({ error: "not_found" }, 404);
  }

  private async createChallenge(): Promise<Response> {
    const now = epochSeconds();
    this.prune(now);
    if (!await this.admitServiceLimit("challenges", Math.floor(now / 60) * 60, MAX_CHALLENGES_PER_MINUTE)) {
      return json({ error: "rate_limited" }, 429);
    }
    const active = this.state.storage.sql
      .exec<{ count: number }>("SELECT COUNT(*) AS count FROM challenges WHERE consumed_at IS NULL AND expires_at >= ?", now)
      .one().count;
    if (active >= MAX_ACTIVE_CHALLENGES) return json({ error: "temporarily_unavailable" }, 503);
    const challengeId = randomOpaqueId();
    const challenge = randomOpaqueId(32);
    this.state.storage.sql.exec(
      "INSERT INTO challenges (challenge_id, challenge_hash, expires_at, consumed_at, attempt_count) VALUES (?, ?, ?, NULL, 0)",
      challengeId,
      await sha256Hex(utf8(challenge)),
      now + CHALLENGE_TTL_SECONDS,
    );
    return json({ version: 1, challengeId, challenge, expiresAt: new Date((now + CHALLENGE_TTL_SECONDS) * 1000).toISOString() });
  }

  private async registerInstallation(request: Request): Promise<Response> {
    if (!this.env.APPLE_TEAM_ID) return json({ error: "service_not_configured" }, 503);
    let parsed: ReturnType<typeof validateRegistration>;
    try { parsed = validateRegistration(await request.json()); } catch { return json({ error: "invalid_json" }, 400); }
    if (!parsed.ok) return json({ error: parsed.error }, 400);
    const registration = parsed.value;
    const challenge = await this.admitChallenge(registration);
    if (!challenge) return json({ error: "invalid_attestation" }, 401);

    const route = ROUTES[registration.route];
    const appId = `${this.env.APPLE_TEAM_ID}.${route.bundleId}`;
    const clientDataHash = await sha256(canonicalRegistration(registration));
    const existing = this.installationByKey(registration.keyId);
    let publicKeySpki: string;
    let counter: number;
    try {
      if (registration.proof === "attestation") {
        if (existing) throw new Error("key_already_attested");
        const verified = await verifyAttestation({
          attestationObject: registration.attestationObject,
          keyId: registration.keyId,
          clientDataHash,
          appId,
          environment: route.attestationEnvironment,
        });
        publicKeySpki = verified.publicKeySpki;
        counter = verified.counter;
      } else {
        if (!existing || existing.route !== registration.route || existing.enabled !== 1) throw new Error("unknown_attestation_key");
        publicKeySpki = existing.public_key_spki;
        counter = await verifyAssertion({
          assertionObject: registration.assertionObject,
          publicKeySpki,
          clientDataHash,
          appId,
          previousCounter: Number(existing.assertion_counter),
        });
      }
    } catch {
      return json({ error: "invalid_attestation" }, 401);
    }

    const tokenHash = await sha256Hex(utf8(registration.apnsToken));
    try {
      const result = await this.state.storage.transaction(async (): Promise<RegistrationResult> => {
        const currentChallenge = this.challenge(registration.challengeId);
        if (!currentChallenge || currentChallenge.consumed_at !== null || currentChallenge.expires_at < epochSeconds()) {
          throw new Error("challenge_replayed");
        }
        this.state.storage.sql.exec("UPDATE challenges SET consumed_at = ? WHERE challenge_id = ?", epochSeconds(), registration.challengeId);

        let installation = this.installationByKey(registration.keyId);
        const now = epochSeconds();
        const tokenOwner = this.state.storage.sql.exec<StoredInstallation>(
          "SELECT * FROM installations WHERE route = ? AND token_hash = ? AND key_id <> ?", registration.route, tokenHash, registration.keyId,
        ).toArray()[0];
        if (tokenOwner) {
          this.state.storage.sql.exec("UPDATE installations SET enabled = 0, updated_at = ? WHERE installation_id = ?", now, tokenOwner.installation_id);
          this.state.storage.sql.exec("UPDATE grants SET enabled = 0, updated_at = ? WHERE installation_id = ?", now, tokenOwner.installation_id);
        }
        if (registration.proof === "attestation") {
          if (installation) throw new Error("key_already_attested");
          const installationCount = this.state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM installations").one().count;
          if (Number(installationCount) >= MAX_INSTALLATIONS) throw new Error("installation_capacity");
          const installationId = randomOpaqueId();
          this.state.storage.sql.exec(
            `INSERT INTO installations
             (installation_id, key_id, public_key_spki, route, apns_token, token_hash, assertion_counter, enabled, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
            installationId, registration.keyId, publicKeySpki, registration.route,
            registration.apnsToken, tokenHash, counter, now, now,
          );
          installation = this.installationByKey(registration.keyId);
        } else {
          if (!installation || installation.route !== registration.route || Number(installation.assertion_counter) >= counter) {
            throw new Error("assertion_replayed");
          }
          this.state.storage.sql.exec(
            "UPDATE installations SET apns_token = ?, token_hash = ?, assertion_counter = ?, enabled = 1, updated_at = ? WHERE installation_id = ?",
            registration.apnsToken, tokenHash, counter, now, installation.installation_id,
          );
          installation = this.installationByKey(registration.keyId);
        }
        if (!installation) throw new Error("installation_write_failed");
        let grant = this.grantByBinding(installation.installation_id, registration.bindingHash);
        if (!grant) {
          const grantCount = this.state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM grants").one().count;
          const installationGrantCount = this.state.storage.sql.exec<{ count: number }>(
            "SELECT COUNT(*) AS count FROM grants WHERE installation_id = ?", installation.installation_id,
          ).one().count;
          if (Number(grantCount) >= MAX_GRANTS || Number(installationGrantCount) >= MAX_GRANTS_PER_INSTALLATION) {
            throw new Error("grant_capacity");
          }
          const grantId = randomOpaqueId();
          const secret = randomOpaqueId(32);
          const hour = hourWindow(now);
          const day = dayWindow(now);
          this.state.storage.sql.exec(
            `INSERT INTO grants
             (grant_id, installation_id, binding_hash, secret, enabled, hourly_window, hourly_count, daily_window, daily_count, created_at, updated_at)
             VALUES (?, ?, ?, ?, 1, ?, 0, ?, 0, ?, ?)`,
            grantId, installation.installation_id, registration.bindingHash, secret, hour, day, now, now,
          );
          grant = this.grant(grantId);
        } else if (grant.enabled !== 1) {
          // A disabled endpoint capability may already have crossed a remote
          // revocation boundary. Re-admission rotates both opaque authority
          // values so an old signed tombstone can never disable the new grant.
          const previousGrantId = grant.grant_id;
          const grantId = randomOpaqueId();
          const secret = randomOpaqueId(32);
          this.state.storage.sql.exec(
            `UPDATE grants SET grant_id = ?, secret = ?, enabled = 1,
             hourly_window = ?, hourly_count = 0, daily_window = ?, daily_count = 0,
             created_at = ?, updated_at = ? WHERE grant_id = ?`,
            grantId, secret, hourWindow(now), dayWindow(now), now, now, previousGrantId,
          );
          grant = this.grant(grantId);
        }
        if (!grant) throw new Error("grant_write_failed");
        return {
          version: 1,
          installationId: installation.installation_id,
          grantId: grant.grant_id,
          grantSecret: grant.secret,
          route: registration.route,
        };
      });
      return json(result, 201);
    } catch (error) {
      if ((error as Error).message === "installation_capacity" || (error as Error).message === "grant_capacity") {
        return json({ error: "temporarily_unavailable" }, 503);
      }
      return json({ error: "registration_conflict" }, 409);
    }
  }

  private async dispatch(request: Request): Promise<Response> {
    const body = new Uint8Array(await request.arrayBuffer());
    let parsed: ReturnType<typeof validateNotification>;
    try { parsed = validateNotification(JSON.parse(new TextDecoder().decode(body))); } catch { return json({ error: "invalid_json" }, 400); }
    if (!parsed.ok) return json({ error: parsed.error }, 400);
    const notification = parsed.value;
    const grantId = request.headers.get("x-tron-grant-id");
    const timestamp = request.headers.get("x-tron-timestamp");
    const requestId = request.headers.get("x-tron-request-id");
    const signature = request.headers.get("x-tron-signature");
    if (!grantId || !timestamp || !requestId || !signature || !isOpaqueId(grantId) || !isOpaqueId(requestId) || requestId !== notification.requestId) {
      return json({ error: "invalid_authentication_headers" }, 401);
    }
    const grant = this.grant(grantId);
    if (!grant || grant.enabled !== 1 || !(await verifyGrantSignature({
      secret: grant.secret, method: "POST", path: "/v3/notifications", timestamp, requestId, body, provided: signature,
    }))) return json({ error: "invalid_signature" }, 401);
    const installation = this.installation(grant.installation_id);
    if (!installation || installation.enabled !== 1) return json({ error: "installation_unavailable" }, 410);

    const bodyHash = await sha256Hex(body);
    const admission = await this.beginDispatch(requestId, grant, installation.installation_id, bodyHash);
    if (admission.response) return json(admission.response);
    if (!admission.admitted) return json({ status: "rate_limited", reason: "rate_limited", retryAfterSeconds: admission.retryAfterSeconds } satisfies RelayResult);

    const route = ROUTES[installation.route];
    let result: RelayResult;
    try {
      result = await sendToApns(this.env, notification, {
        deviceToken: installation.apns_token,
        topic: route.topic,
        environment: route.apnsEnvironment,
      });
    } catch {
      result = { status: "retryable", reason: "relay_transport_error", retryAfterSeconds: 30 };
    }
    await this.finishDispatch(requestId, result);
    if (result.status === "invalid_token") {
      await this.state.storage.transaction(async () => {
        const now = epochSeconds();
        this.state.storage.sql.exec("UPDATE installations SET enabled = 0, updated_at = ? WHERE installation_id = ?", now, installation.installation_id);
        this.state.storage.sql.exec("UPDATE grants SET enabled = 0, updated_at = ? WHERE installation_id = ?", now, installation.installation_id);
      });
    }
    return json(result);
  }

  private async revoke(request: Request, path: string): Promise<Response> {
    const grantId = path.slice(GRANT_PATH_PREFIX.length);
    const timestamp = request.headers.get("x-tron-timestamp");
    const requestId = request.headers.get("x-tron-request-id");
    const signature = request.headers.get("x-tron-signature");
    if (!isOpaqueId(grantId) || !timestamp || !requestId || !signature || !isOpaqueId(requestId)) {
      return json({ error: "invalid_authentication_headers" }, 401);
    }
    const grant = this.grant(grantId);
    const body = new Uint8Array();
    // Opaque missing grants are an idempotent terminal revoke, including after
    // bounded disabled-record pruning.
    if (!grant) return json({ error: "not_found" }, 404);
    if (!(await verifyGrantSignature({
      secret: grant.secret, method: "DELETE", path, timestamp, requestId, body, provided: signature,
    }))) return json({ error: "invalid_signature" }, 401);
    this.state.storage.sql.exec("UPDATE grants SET enabled = 0, updated_at = ? WHERE grant_id = ?", epochSeconds(), grantId);
    return json({ version: 1, revoked: true });
  }

  private async admitServiceLimit(key: string, window: number, maximum: number): Promise<boolean> {
    return this.state.storage.transaction(async () => {
      const row = this.state.storage.sql.exec<{ window_start: number; count: number }>(
        "SELECT window_start, count FROM service_limits WHERE key = ?", key,
      ).toArray()[0];
      const count = row && Number(row.window_start) === window ? Number(row.count) : 0;
      if (count >= maximum) return false;
      this.state.storage.sql.exec(
        `INSERT INTO service_limits (key, window_start, count) VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET window_start = excluded.window_start, count = excluded.count`,
        key, window, count + 1,
      );
      return true;
    });
  }

  private async admitChallenge(registration: InstallationRegistration): Promise<ChallengeRow | undefined> {
    const expected = await sha256(utf8(registration.challenge));
    return this.state.storage.transaction(async () => {
      const row = this.challenge(registration.challengeId);
      const now = epochSeconds();
      if (!row || row.consumed_at !== null || row.expires_at < now || row.attempt_count >= MAX_CHALLENGE_ATTEMPTS) return undefined;
      // Reserve an attempt before expensive certificate/assertion verification.
      this.state.storage.sql.exec("UPDATE challenges SET attempt_count = attempt_count + 1 WHERE challenge_id = ?", registration.challengeId);
      const actual = decodeHex(row.challenge_hash);
      return constantTimeEqual(expected, actual) ? row : undefined;
    });
  }

  private async beginDispatch(requestId: string, grant: StoredGrant, installationId: string, bodyHash: string): Promise<{
    response?: RelayResult; admitted: boolean; retryAfterSeconds?: number;
  }> {
    return this.state.storage.transaction(async () => {
      const now = epochSeconds();
      this.state.storage.sql.exec("DELETE FROM relay_requests WHERE updated_at < ?", now - RECEIPT_RETENTION_SECONDS);
      const existing = this.state.storage.sql.exec<LedgerRow>(
        "SELECT grant_id, body_hash, state, response_json, quota_charged, updated_at FROM relay_requests WHERE request_id = ?",
        requestId,
      ).toArray()[0];
      if (existing) {
        if (existing.grant_id !== grant.grant_id || existing.body_hash !== bodyHash) {
          return { response: { status: "permanent_failure", reason: "request_id_conflict" }, admitted: false };
        }
        if (existing.state === "in_progress") {
          const updatedAt = Number(existing.updated_at);
          const age = Number.isFinite(updatedAt) ? Math.max(0, now - updatedAt) : Number.POSITIVE_INFINITY;
          return {
            response: age <= ACTIVE_PROVIDER_ATTEMPT_SECONDS
              ? { status: "in_progress", reason: "provider_request_in_progress" }
              : { status: "ambiguous", reason: "provider_outcome_unknown" },
            admitted: false,
          };
        }
        if (existing.state === "terminal" && existing.response_json) {
          try { return { response: JSON.parse(existing.response_json) as RelayResult, admitted: false }; }
          catch { return { response: { status: "ambiguous", reason: "ledger_result_invalid" }, admitted: false }; }
        }
        this.state.storage.sql.exec("UPDATE relay_requests SET state = 'in_progress', response_json = NULL, updated_at = ? WHERE request_id = ?", epochSeconds(), requestId);
        return { admitted: true };
      }

      const hour = hourWindow(now);
      const day = dayWindow(now);
      const hourlyCount = Number(grant.hourly_window) === hour ? Number(grant.hourly_count) : 0;
      const dailyCount = Number(grant.daily_window) === day ? Number(grant.daily_count) : 0;
      const installationLimit = this.state.storage.sql.exec<{
        hourly_window: number; hourly_count: number; daily_window: number; daily_count: number;
      }>("SELECT hourly_window, hourly_count, daily_window, daily_count FROM installation_limits WHERE installation_id = ?", installationId).toArray()[0];
      const installationHourly = installationLimit && Number(installationLimit.hourly_window) === hour ? Number(installationLimit.hourly_count) : 0;
      const installationDaily = installationLimit && Number(installationLimit.daily_window) === day ? Number(installationLimit.daily_count) : 0;
      if (hourlyCount >= HOURLY_LIMIT || dailyCount >= DAILY_LIMIT
        || installationHourly >= INSTALLATION_HOURLY_LIMIT || installationDaily >= INSTALLATION_DAILY_LIMIT) {
        const hourlyLimited = hourlyCount >= HOURLY_LIMIT || installationHourly >= INSTALLATION_HOURLY_LIMIT;
        const retryAfterSeconds = hourlyLimited ? Math.max(1, hour + 3600 - now) : Math.max(1, day + 86400 - now);
        const result: RelayResult = { status: "rate_limited", reason: "rate_limited", retryAfterSeconds };
        this.state.storage.sql.exec(
          "INSERT INTO relay_requests (request_id, grant_id, body_hash, state, response_json, quota_charged, updated_at) VALUES (?, ?, ?, 'terminal', ?, 0, ?)",
          requestId, grant.grant_id, bodyHash, JSON.stringify(result), now,
        );
        return { response: result, admitted: false };
      }
      this.state.storage.sql.exec(
        "UPDATE grants SET hourly_window = ?, hourly_count = ?, daily_window = ?, daily_count = ?, updated_at = ? WHERE grant_id = ?",
        hour, hourlyCount + 1, day, dailyCount + 1, now, grant.grant_id,
      );
      this.state.storage.sql.exec(
        `INSERT INTO installation_limits (installation_id, hourly_window, hourly_count, daily_window, daily_count, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(installation_id) DO UPDATE SET hourly_window = excluded.hourly_window,
         hourly_count = excluded.hourly_count, daily_window = excluded.daily_window,
         daily_count = excluded.daily_count, updated_at = excluded.updated_at`,
        installationId, hour, installationHourly + 1, day, installationDaily + 1, now,
      );
      this.state.storage.sql.exec(
        "INSERT INTO relay_requests (request_id, grant_id, body_hash, state, response_json, quota_charged, updated_at) VALUES (?, ?, ?, 'in_progress', NULL, 1, ?)",
        requestId, grant.grant_id, bodyHash, now,
      );
      return { admitted: true };
    });
  }

  private async finishDispatch(requestId: string, result: RelayResult): Promise<void> {
    const terminal = result.status === "accepted_by_apns" || result.status === "permanent_failure" || result.status === "invalid_token";
    this.state.storage.sql.exec(
      "UPDATE relay_requests SET state = ?, response_json = ?, updated_at = ? WHERE request_id = ?",
      terminal ? "terminal" : "retryable", JSON.stringify(result), epochSeconds(), requestId,
    );
  }

  private challenge(id: string): ChallengeRow | undefined {
    return this.state.storage.sql.exec<ChallengeRow>(
      "SELECT challenge_hash, expires_at, consumed_at, attempt_count FROM challenges WHERE challenge_id = ?", id,
    ).toArray()[0];
  }
  private installationByKey(keyId: string): StoredInstallation | undefined {
    return this.state.storage.sql.exec<StoredInstallation>("SELECT * FROM installations WHERE key_id = ?", keyId).toArray()[0];
  }
  private installation(id: string): StoredInstallation | undefined {
    return this.state.storage.sql.exec<StoredInstallation>("SELECT * FROM installations WHERE installation_id = ?", id).toArray()[0];
  }
  private grant(id: string): StoredGrant | undefined {
    return this.state.storage.sql.exec<StoredGrant>("SELECT * FROM grants WHERE grant_id = ?", id).toArray()[0];
  }
  private grantByBinding(installationId: string, bindingHash: string): StoredGrant | undefined {
    return this.state.storage.sql.exec<StoredGrant>(
      "SELECT * FROM grants WHERE installation_id = ? AND binding_hash = ?", installationId, bindingHash,
    ).toArray()[0];
  }
  private prune(now: number): void {
    this.state.storage.sql.exec("DELETE FROM challenges WHERE expires_at < ? OR consumed_at IS NOT NULL", now - 60);
    this.state.storage.sql.exec("DELETE FROM relay_requests WHERE updated_at < ?", now - RECEIPT_RETENTION_SECONDS);
    this.state.storage.sql.exec("DELETE FROM grants WHERE enabled = 0 AND updated_at < ?", now - DISABLED_RETENTION_SECONDS);
    this.state.storage.sql.exec(
      "DELETE FROM installations WHERE enabled = 0 AND updated_at < ? AND NOT EXISTS (SELECT 1 FROM grants WHERE grants.installation_id = installations.installation_id)",
      now - DISABLED_RETENTION_SECONDS,
    );
    this.state.storage.sql.exec("DELETE FROM installation_limits WHERE updated_at < ?", now - DISABLED_RETENTION_SECONDS);
  }
}

function epochSeconds(): number { return Math.floor(Date.now() / 1000); }
function hourWindow(now: number): number { return Math.floor(now / 3600) * 3600; }
function dayWindow(now: number): number { return Math.floor(now / 86400) * 86400; }
function decodeHex(value: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/.test(value)) return new Uint8Array();
  return Uint8Array.from(value.match(/../g)!.map((byte) => Number.parseInt(byte, 16)));
}
