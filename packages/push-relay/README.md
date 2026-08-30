# Tron Push Relay

`@tron/push-relay` is Tron's closed, product-operated APNs transport. It is not
an agent runtime, notification inbox, mobile API gateway, or general push
provider. Production deployment is a manual maintainer action.

The package ports the final pre-Gateway relay's proven APNs provider-token
cache, strict routing, stable provider request IDs, bounded response parsing,
outcome classification, and SQLite Durable Object idempotency. It deliberately
does not restore Engine workers, `/v1`, badges, reminders, background refresh,
or arbitrary APNs payloads.

## Ownership and trust boundary

1. The official iOS app obtains an APNs token and an Apple App Attest key.
2. `POST /v3/attestation/challenge` returns a five-minute one-use challenge.
3. `POST /v3/installations` verifies a new attestation or a subsequent
   assertion. The Worker stores the opaque APNs token and issues one random
   HMAC grant for the attested installation plus pairing-binding hash.
4. iOS transfers that grant over its authenticated Gateway connection.
5. The Gateway signs `POST /v3/notifications` with the endpoint-scoped grant.
6. The Worker resolves the APNs token, applies quota and durable request
   idempotency, and submits one fixed alert to APNs.

A grant can address only its installation. The model cannot select a token,
topic, APNs environment, badge, sound, priority, provider URL, or payload
object. The fixed alert names `tron-notification.caf`, which the iOS target bundles as a supported 1.46-second CAF resource. The Worker maps these exact routes:

| Route | App Attest app ID suffix | App Attest environment | APNs |
| --- | --- | --- | --- |
| `beta` | `com.tron.mobile.beta` | development | sandbox |
| `production-sandbox` | `com.tron.mobile` | development | sandbox |
| `production` | `com.tron.mobile` | production | production |

The prefix is the configured `APPLE_TEAM_ID`. Production has no test or
unverified-attestation route.

## Registration contract

The iOS client creates canonical UTF-8 JSON in this exact key order and passes
its SHA-256 digest as `clientDataHash` to `attestKey` or
`generateAssertion`:

```json
{"apnsToken":"...","bindingHash":"64 lowercase hex","challenge":"...","challengeId":"...","keyId":"...","route":"beta","version":1}
```

The request adds either:

```json
{"proof":"attestation","attestationObject":"base64url"}
```

or:

```json
{"proof":"assertion","assertionObject":"base64url"}
```

All base64 values are unpadded base64url. APNs tokens are lowercase,
even-length hex derived from opaque `Data`; no fixed token length is assumed.
Assertions must carry a strictly increasing authenticator counter. A successful
response returns an opaque `installationId`, `grantId`, and random
`grantSecret`. These are capabilities and must not enter logs or session JSONL.

Attestation verification pins Apple's App Attestation Root CA, verifies the
X.509 chain and validity, Apple nonce extension, relying-party hash, AAGUID,
zero initial counter, credential ID, and public-key hash. The pinned PEM was
retrieved from:

`https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem`

Its source-file SHA-256 at import was
`c778d09ac341f7fd9f8f3b19e2b815af6aed4ad4490e1e92c05cb355212a5013`.
Review Apple PKI announcements before changing it.

## Dispatch authentication

The Gateway sends these headers:

- `x-tron-grant-id`
- `x-tron-timestamp` — ten-digit Unix seconds, within five minutes
- `x-tron-request-id`
- `x-tron-signature` — lowercase hexadecimal HMAC-SHA256

The canonical signed string is:

```text
POST
/v3/notifications
<TIMESTAMP>
<REQUEST_ID>
<SHA256_HEX_OF_EXACT_BODY>
```

The exact bounded body is:

```json
{
  "version": 1,
  "kind": "agent_alert",
  "requestId": "stable opaque ID",
  "message": "at most 512 UTF-8 bytes",
  "title": "optional product title, at most 256 UTF-8 bytes",
  "sessionId": "optional exact session route",
  "machineId": "required with sessionId",
  "expiresAt": "RFC 3339 within 24 hours"
}
```

`title`, `sessionId`, and `machineId` are omitted for generic alerts. The relay accepts the two route fields only as a pair and projects them as fixed top-level APNs custom data; clients admit them as opaque identifiers and resolve the machine against an already-paired Gateway profile. The model cannot provide these fields.

Grant revocation signs an empty body with method `DELETE` and exact path
`/v3/grants/{grantId}`. It is idempotent. Disabled grants are never re-enabled
with their prior capability: a later registration for the same installation and
binding atomically rotates both `grantId` and `grantSecret`. The old signed revoke
therefore resolves as an idempotent missing grant and cannot disable replacement
authority. Disabled records are pruned after the fixed 30-day retention window.

## Delivery semantics

The Durable Object records each request ID, grant ID, and body hash before
contacting APNs. Terminal results replay without another APNs request. An
overlapping request for an ID whose provider attempt is still inside the bounded
30-second provider window returns `in_progress`; polling that same ID can observe
the eventual terminal result without starting a second APNs request. A stale
provider attempt or crash whose APNs outcome is unknown replays `ambiguous`; it
does not blindly resend.
Explicitly retryable outcomes may be attempted again with the same request ID.
A request-ID reuse with a different grant or body fails permanently.

Each grant admits at most 30 new requests per hour and 200 per UTC day; each
installation admits at most 50 per hour and 300 per day across its grants. One
installation may own at most eight grants, and global installation/grant tables
are transactionally bounded. Retries of an admitted request do not consume
another quota unit. The cached APNs provider token is keyed by a cryptographic
fingerprint of the team ID, key ID, and complete private-key contents. APNs
`InvalidProviderToken` and `ExpiredProviderToken` responses clear that cache and
remain retryable, so credential replacement and provider invalidation cannot
reuse stale authority. Provider-token construction and APNs transport exceptions
use separate fixed retryable reasons without projecting credentials, provider
responses, or exception text. The closed APNs request
retains a 15-second abort bound and the platform-default redirect mode; forcing
`redirect: "error"` makes deployed Workers reject APNs egress before a provider
response. APNs invalid-token responses disable the installation and all of its
grants.

`accepted_by_apns` means only that APNs accepted the provider request. It is not
proof of presentation or human receipt.

## Local validation

Use the repository-pinned Node version when available:

```bash
cd packages/push-relay
npm ci
npm run check
npm test
npm run build           # production-config dry-run only; does not deploy
npm run build:sandbox   # isolated sandbox-config dry-run only
```

Tests run in the Workers Vitest pool and exercise the real SQLite Durable Object
boundary. Outbound APNs requests are intercepted locally.

## Manual deployment

Use only read-only inventory commands before any mutation. They expose IDs and
secret names, never secret values; retain their output only in maintainer-owned
release evidence:

```bash
npx wrangler whoami
npx wrangler deployments status --name tron-push-relay --json
npx wrangler deployments list --name tron-push-relay --json
npx wrangler versions list --name tron-push-relay --json
npx wrangler secret list --name tron-push-relay --format json
```

Confirm the deployed migration tag, Durable Object binding,
workers.dev/custom origin, and secret names. Production and sandbox are fresh
services whose only SQLite class is `PushRegistry` at `v1`. The retired Worker,
its `RelayLedger` namespace, and `TRON_RELAY_SECRET` are not migration inputs and
must not exist in the release account. Any other Durable Object class or
migration state is a stop condition requiring deletion or Cloudflare review.

The named `sandbox` environment is a distinct service,
`tron-push-relay-sandbox`, with its own SQLite Durable Object namespace and
secrets. It does not automatically replace the single client origin in
`config/PushService.xcconfig`; isolated device validation must deliberately set
that origin, rebuild and install matching Mac/iOS artifacts, then restore the
production origin before release review. A bare deploy never counts as sandbox
validation. Configure the four secret names below independently for sandbox,
then a maintainer may manually run `npx wrangler deploy --env sandbox`. No script
in this package performs that mutation.

Configure these Cloudflare secrets manually:

```text
APNS_KEY_P8
APNS_KEY_ID
APNS_TEAM_ID
APPLE_TEAM_ID
```

After physical-device sandbox verification, an explicit production release
review, and a rollback decision, a maintainer may manually run the production
command `npx wrangler deploy --env=""`. It must not be invoked by an agent or CI.

There is intentionally no deployment script, CI deployment, install-time deployment, shared Mac
relay secret, or user-configurable relay origin. The signed Mac/iOS release must
be built with the manually verified public Worker origin.

## Operational privacy

Do not add logging of request bodies, messages, APNs tokens, installation IDs,
grant IDs/secrets, signatures, attestation objects, Apple receipts, certificate
fields, or APNs response bodies. Metrics may use bounded correlation hashes and
outcome classes. Cloudflare and Apple necessarily observe routing and alert
content.

Recommended infrastructure controls outside this source package are a
Cloudflare request-size rule, challenge-route rate limit, aggregate emergency
kill switch, and alerts on quota/invalid-token/ambiguous outcome rates.
