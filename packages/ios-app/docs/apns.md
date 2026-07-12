# Push Notifications

Tron push delivery has three owners:

1. iOS requests permission, receives the APNs token, and registers it through
   the trusted `device::register` engine function.
2. The server stores policy and a token hash in `device_registration`; the raw
   token stays in a private `0600` transport store under
   `~/.tron/internal/notifications/`.
3. `notification_send` records durable notification/delivery evidence and, when
   policy allows, delegates the network request to the HMAC-authenticated APNs
   relay.

Registration is not a model-facing capability. Models can inspect redacted
device and notification records, but cannot submit tokens or bypass opt-in,
event-family, authority, or exact-selector policy.

## Local Development

The relay is optional and fail-closed. Export both `TRON_RELAY_URL` and
`TRON_RELAY_SECRET`, or copy `packages/mac-app/.env.local.example` to the
ignored `packages/mac-app/.env.local` and fill in both values. `scripts/tron
dev` reads only those two keys. Background dev takeovers write their values to
the private `0600` transient LaunchAgent plist so foreground and background
servers use the same runtime configuration.

If either value is absent, device registration still succeeds and reports that
live APNs is disabled. A push-requested notification records
`apns_relay_not_configured` instead of claiming delivery.

## Safety Invariants

- Raw tokens, relay secrets, APNs response ids, and full token hashes never
  enter model projections or logs.
- Development tokens route to the APNs sandbox with the Beta bundle id;
  production tokens route to production with the production bundle id.
- Terminal APNs token rejection removes private token custody.
- Notification resources remain the source of truth; push is only a delivery
  effect.
- Physical-device validation requires a configured relay and a signed build
  with the matching `aps-environment` entitlement.
