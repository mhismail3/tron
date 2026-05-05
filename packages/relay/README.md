# Tron Push Relay

Cloudflare Worker that forwards push notification requests from Tron servers to Apple's APNs. Holds the `.p8` signing key so individual server installations don't need it.

## Architecture

```
Tron Server ──HTTPS──► This Worker ─��HTTP/2──► api.push.apple.com
              HMAC-signed request    JWT-signed with .p8 key
```

- Servers authenticate via HMAC-SHA256 signed requests
- Worker signs APNs JWTs using the `.p8` key stored in Wrangler secrets
- JWTs are cached for 50 minutes (Apple allows up to 60)
- Each request can target up to 50 device tokens in parallel
- Environment (sandbox/production) is specified per-request

## Deployment

```bash
cd packages/relay
npm install
npx wrangler login     # one-time Cloudflare OAuth
npx wrangler deploy
```

## Secrets

Set via `wrangler secret put <NAME>`:

| Secret | Value |
|--------|-------|
| `APNS_KEY_P8` | Full contents of the `.p8` private key file |
| `APNS_KEY_ID` | 10-character Apple key ID (e.g., `4Y6ZSKVKZ2`) |
| `APNS_TEAM_ID` | 10-character Apple team ID (e.g., `MYGKXH6TY4`) |
| `TRON_RELAY_SECRET` | Shared HMAC secret (generate with `openssl rand -hex 32`) |

The bundle ID is configured in `wrangler.toml` as a plain variable (not a secret).

## Build Integration

The server reads relay credentials from compile-time environment variables via `option_env!()`. Release builds set them from GitHub Actions secrets in `.github/workflows/release-mac.yml`, so installed users do not need any local relay config:

```bash
TRON_RELAY_URL="https://tron-push-relay.<subdomain>.workers.dev"
TRON_RELAY_SECRET="<same HMAC secret set in Wrangler>"
TRON_RELAY_ENVIRONMENT=production
```

Developers testing push delivery locally may export the same variables before building/running `tron`. They are never read from `~/.tron/profiles/auth.json`.

For Xcode Mac wrapper dogfood, prefer `packages/mac-app/.env.local`: copy `packages/mac-app/.env.local.example`, fill in the same relay values, then run `packages/mac-app/scripts/bundle-agent.sh`. The bundle script reads only the relay keys from that ignored file before Cargo compiles the staged helper.

## API

### `POST /v1/push`

**Headers:**
- `X-Tron-Timestamp`: Unix seconds
- `X-Tron-Signature`: `hex(HMAC-SHA256(secret, "{timestamp}.{body}"))`

**Body:**
```json
{
  "device_tokens": ["64-char-hex-string"],
  "notification": {
    "title": "Task Complete",
    "body": "Your build finished",
    "priority": "high",
    "sound": "default",
    "badge": 1,
    "thread_id": "session-id",
    "data": { "sessionId": "..." }
  },
  "environment": "sandbox"
}
```

**Response:**
```json
{
  "results": [
    { "device_token": "...", "success": true, "apns_id": "uuid", "status_code": 200 },
    { "device_token": "...", "success": false, "status_code": 410, "reason": "Unregistered" }
  ]
}
```

**Error codes:** 400 (bad request), 401 (invalid signature), 408 (expired timestamp), 413 (too many tokens)
