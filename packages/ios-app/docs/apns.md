# APNs Device Registration

The worker-first fixed kernel retains private APNs token custody but does not
ship a notification inbox or push-delivery plane.

## Ownership

1. iOS requests permission, receives the APNs token, and submits it through the
   authenticated transport-only `device::register` function.
2. The server stores a token hash and registration metadata in the
   `device_registration` resource.
3. The raw token stays in a private `0600` file under
   `~/.tron/internal/devices/` and is never model-visible.

Registration includes the app installation id, bundle id, and signed APNs
environment. Production, Beta, simulator, and side-by-side installs therefore
cannot overwrite each other. Re-registering an identical route is idempotent;
moving a route to a new installation retires the older durable registration.

iOS retries registration after pairing, connection, token refresh, and app
foreground. If notification permission is denied, registration remains
inactive and local diagnostics identify the required Settings action.

## POC Boundary

The fixed source tree performs no APNs send, delivery evidence, notification
read state, badge policy, or model-facing device inspection. A useful push
workflow must be authored as a persistent worker and expose its own trigger,
result, health, inbox, and failure behavior. iOS must not present a fixed push
delivery status that the server no longer owns.

## Safety Invariants

- Raw tokens and full token hashes never enter provider prompts, model tools,
  session events, client projections, or logs.
- Token custody is transport-only and authenticated.
- Routing follows the signed `aps-environment` entitlement, not an Xcode
  configuration label.
- Unregistering or superseding a registration removes obsolete private token
  custody while preserving redacted lifecycle evidence.
- Worker webhook tokens and worker secret bindings are separate from APNs
  device tokens.
