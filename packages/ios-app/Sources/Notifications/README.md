# Notifications

## Purpose

Remote alert registration through Tron Push, notification taps, and the Gateway-backed
notification inbox.

## Owns

`AppDelegate`, `PushNotificationCoordinator`, `NotificationInboxCoordinator`,
`RetiredNotificationBadge`, `DeliveredNotificationRead`.

## Contract

- **Registration.** Only after a Gateway profile exists; the user's permission decision is
  authoritative and denial never blocks pairing or chat. The app obtains an opaque APNs token,
  proves its signed Development or Release identity to the fixed Tron Push origin with App Attest,
  and transfers only the returned endpoint-scoped installation grant to the authenticated Gateway.
  A grant records the relay origin and route that issued it; a mismatched grant is replaced through
  the Worker, never transferred. A Gateway whose relay origin differs is treated as unavailable.
- **Retries.** One bounded, profile-generation-owned operation: a fresh challenge and proof per
  attempt, two backoffs for timeouts and retryable 5xx, no commit across a profile or token change.
  An assertion 401 or the typed invalid-key code clears only the App Attest key, once. Other
  rejections stop without credential churn; APNs tokens are preserved. Registration reconciles on
  connection, foreground, profile, permission and token changes; Worker failure leaves it pending.
- **Secrets.** App Attest keys, token bytes and grants use a Keychain namespace separate from Gateway
  credentials. Settings shows only a fixed local stage label; the app accepts no relay URL or push
  credential from settings.
- **Alerts.** No badge, background fetch or notification approval actions. Exact changes
  are reviewed in the shared in-chat native card. The bundled `tron-notification.caf` sound; ask pushes are Time
  Sensitive (entitlement in every build configuration). A foreground synchronized chat's
  presentation lease suppresses its own agent-terminal alert at the Gateway. Push Notifications
  settings toggle Input needed, Finished and Waiting through `push.registration.upsert`, rolling
  back on failure. A zero badge is written at launch to clear the retired badge implementation.
- **Icon.** iOS owns the small app icon in system notifications; there is no per-notification
  theme color or icon override in Tron's payload. Theme selection uses bundled alternate app
  icons through UIKit, not a notification extension or communication-avatar workaround. Apple
  documents system-scaled notification icons, but not alternate-icon cache refresh timing;
  neither new nor already-delivered notification parity is guaranteed. Device validation is
  separate from simulator app-icon previews. See [Apple icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)
  and [alternate-icon workflow](https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons).
- **Delivered reads.** A synchronized chat becoming visible captures a native delivered cut,
  matching admitted machine/session routes at or before that visibility. Home membership comes
  from `home.chapterList`, not dashboard names or rows; a failed ledger read never widens cleanup.
  Profile, connection and presentation currency fence native reads and removal. Only captured
  request IDs are removed, leaving other routes and later deliveries intact; the existing retired
  badge owner restores zero. This is native presentation cleanup, not proof of canonical inbox
  persistence: the Gateway's independent captured-ID read retries remain authoritative.
- **Taps.** Admission rejects partial, oversized or non-opaque routes, resolves the machine only
  against a paired profile, marks the inbox row read without delaying navigation, and joins an
  in-flight same-profile reconnect at transport activation. A tap on the chapter the Gateway's
  `home.status` names opens Home itself, which sends through `home.prompt`. A tap for the presented
  conversation keeps that chat; any other target mounts only after the presented chat retires, so
  its restoring open never contends with the target. A tap from Automations or Apps switches
  to Sessions first. A background or cold tap is held in memory only, never persisted.
- **Inbox.** `notification-inbox.v1`. `NotificationInboxCoordinator` keeps a bounded projection of
  two server windows per profile (`all`, `unread`, the latter the server's own page), merges
  refreshes by id so loaded older pages and keyset cursors survive, and pages each window through
  its scroll sentinel. Mark Read sends each profile a `readAll` cut at its newest shown row; opening
  a synchronized chat acknowledges that chat's rows (all of Home's chapters for Home). Kinds:
  `agent_finished` (neutral "Agent finished" for every terminal outcome) and `waiting`. No
  pull-to-refresh; `notification.inbox.changed` drives updates and a failed read keeps rows. The
  sheet's loading pulse is only for the inbox's first windows: once any profile's window is shown, a
  refresh (even of an empty Unread window after Mark Read) keeps the settled rows or empty state.

## Invariants

- Settings and logs never expose origins, identifiers, tokens, proofs, grants, response bodies,
  certificates or bindings.
- Gateway list pages and command receipts are the inbox authority; there is no client read mirror.

## Entry points

`PushNotificationCoordinator.swift`, `NotificationInboxCoordinator.swift`, `AppDelegate.swift`,
`DeliveredNotificationRead.swift`; `SessionPresentationStore`'s synchronized visibility callback.

## Signals

Registration stage label only.

## Verify

```bash
scripts/tron-ios-test run --only-testing TronMobileUITests/TronNotificationInboxUITests \
  --only-testing TronMobileUITests/TronHomePushNavigationUITests \
  --only-testing TronMobileUITests/TronDeliveredNotificationUITests \
  --only-testing TronMobileUITests/TronSmokeUITests/testPushReadinessAndRegistrationAreSeparateFromPolicyToggles
scripts/validate-push-service-config.sh config/PushService.xcconfig
```

Registration tests inject notification, App Attest and HTTP seams. Delivered-read tests use real
Notification Center local deliveries and production chat visibility over a fixture Gateway;
`HostedDeliveredNotificationFixture` owns exact-ID cleanup. Neither suite proves APNs delivery.
`TRON_PUSH_SERVICE_ORIGIN` is shared with the Mac payload, so a change installs the Mac first.
Before shipping an identity, check its signed entitlements, pair a physical device, rotate its
token by reinstalling, and verify revoke, offline retry and the Settings registration stage.

## Not here

The inbox sheets: [Settings](../UI/Settings/README.md) (`NotificationInboxView`). The relay: the
relay package.
