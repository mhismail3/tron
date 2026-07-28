# Tron notification relay

This Cloudflare Worker is an engine-owned APNs transport adapter. It is not a
Tron worker and it does not accept worker-authored APNs payloads.

The only public operation is `POST /v2/notification`. Requests are
single-target, HMAC authenticated, and limited to the fixed alert and quiet
refresh shapes constructed by the engine. Topic/environment pairs are closed
to `com.tron.mobile.beta`/sandbox plus `com.tron.mobile` with either sandbox
for a locally development-signed Prod install or production for TestFlight and
App Store builds.

`RelayLedger` stores one row per stable engine provider request ID in a
SQLite-backed Durable Object. Completed provider results replay without a
second APNs send. If execution stops after an attempt is marked in progress but
before its provider result is recorded, later calls return `ambiguous` so the
relay never guesses that resending is safe. A request ID with no ledger row is
the normal first-send path; the lookup therefore uses an optional cursor result
rather than SQLite's throwing exactly-one-row accessor.

## Source ownership

`src/index.ts` owns only the Cloudflare Worker entry point and handoff to the
ledger. The closed boundary is separated into:

- `validation.ts` for the two admitted request shapes and topic routes;
- `authentication.ts` and `crypto.ts` for HMAC verification and bounded
  cryptographic encodings;
- `ledger.ts` for the single SQLite Durable Object replay authority;
- `apns.ts` for payload construction, provider-token caching, transport, and
  sanitized APNs classification;
- `contracts.ts` for shared closed types and route limits; and
- `response.ts` for no-store JSON responses.

No module adds a second ledger, provider retry loop, credential store, endpoint,
or deployment mode. Tests mirror validation, authentication, APNs projection,
and durable replay.

## Validate locally

```bash
npm install
npm run check
npm test
```

## Manual Cloudflare configuration

The Cloudflare deployment is intentionally manual. Configure these secrets
before deploying. The tracked Wrangler service name is `tron-push-relay`, the
existing relay used by development engines; keeping that stable preserves its
URL and previously configured secrets.

```bash
npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put TRON_RELAY_SECRET
```

Then configure an engine with `tron auth notifications configure-relay`.
Do not put relay or APNs secrets in source, Worker variables, logs, or command
output.

The manual deployment command is:

```bash
npx wrangler deploy
```

Automation and development agents must not run it. After a manual upgrade from
the removed legacy endpoint, run `tron auth notifications use relay`. Rewriting
the selected typed mode advances the configuration revision without exposing or
re-entering the secret, and immediately requeues unexpired targets blocked on
the unavailable contract.
