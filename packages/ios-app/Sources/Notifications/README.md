# Notifications

## Purpose

Remote alert registration through Tron Push, notification taps, and the Gateway-backed
notification inbox.

## Owns

`AppDelegate`, `PushNotificationCoordinator`, `NotificationInboxCoordinator`,
`DeliveredNotificationRead`.

## Contract

- **Registration.** Only after a Gateway profile exists; the user's permission decision is
  authoritative and denial never blocks pairing or chat. The app obtains an opaque APNs token,
  proves its signed Development or Release identity to the fixed Tron Push origin with App Attest,
  and transfers only the returned endpoint-scoped installation grant to the authenticated Gateway.
  A grant records the relay origin and route that issued it; a mismatched grant is replaced through
  the Worker, never transferred. A Gateway whose relay origin differs is treated as unavailable.
  The stored registration acknowledgement is dropped before a register request is sent, because a
  lost response may mean the Gateway already removed the grant; a re-allowed permission re-registers.
- **Retries.** One bounded, profile-generation-owned operation: a fresh challenge and proof per
  attempt, two backoffs for timeouts and retryable 5xx, no commit across a profile or token change.
  Every key rotation goes through `rotateInvalidKey`, which spends the one automatic budget. Inside the
  registration loop an assertion 401 or the typed `DCError.invalidKey` rotates only while the budget is unspent;
  once it is spent, the current key is marked rejected and the attempt stops (`stoppedRejected`), so the
  agent-requested card can offer a fresh key. The outer handler rotates a flagged key only while the budget is
  unspent, and the card rotates once; both spend the budget. There is one automatic key rotation per app
  launch; success never re-arms it. Every later rotation in that launch requires an approved card. Other rejections stop without
  credential churn; APNs tokens are preserved. Registration reconciles on connection, foreground, profile,
  permission and token changes; Worker failure leaves it pending.
- **Agent-requested retry.** A `push-registration-retry` card (`ChangeReview.intent`, shared native change
  card) rotates the rejected key only on the iPhone that approves it. `PushRegistrationRetryApproval.approve`
  captures a `PushRetryFence` (the answering connection: selected profile, machine, runtime epoch and
  lifecycle admission from `AppModel.pushRetryConnection`, the device, and the registration generation)
  before the answer. It refuses without answering when the coordinator is not on that connection. After the
  Gateway accepts the answer it re-reads the connection and calls `retryAfterApprovedCard`, which refuses if
  anything changed. The Gateway request is then only "requested"; registration success is not claimed. Nothing
  is persisted: an app death or a lost response after acceptance loses the effect (best effort, no replay).
  Duplicate approvals are refused at the answer boundary and never rotate. The approved attempt does not
  re-arm the automatic budget. The key is per iPhone, so the card names the other paired Macs.
- **Residual.** Registration stage and Retry Registration left the app with the Push Notifications sheet
  (approved in the 1.2/5.4 slice). Status is no longer shown on the phone.
- **Secrets.** App Attest keys, token bytes and grants use a Keychain namespace separate from Gateway
  credentials; an unreadable Keychain document is never overwritten with an empty one (push fails
  closed while the Gateway stays usable). The app shows no push settings; it accepts no relay URL or push
  credential from anywhere but the bundled configuration.
- **Alerts.** No badge, background fetch or notification approval actions. Exact changes
  are reviewed in the shared in-chat native card. The bundled `tron-notification.caf` sound; ask pushes are Time
  Sensitive (entitlement in every build configuration). A foreground synchronized chat's
  presentation lease suppresses its own agent-terminal alert at the Gateway. Input needed,
  Finished and Waiting are Global settings the agent changes; the app sends no policy with
  `push.registration.upsert`.
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
  request IDs are removed, leaving other routes and later deliveries intact. This is native presentation cleanup, not proof of canonical inbox
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

None. The registration diagnostic stays in memory until the log upload (settings slice 3) carries it.

## Verify

```bash
scripts/tron-ios-test run --only-testing TronMobileUITests/TronNotificationInboxUITests \
  --only-testing TronMobileUITests/TronHomePushNavigationUITests \
  --only-testing TronMobileUITests/TronDeliveredNotificationUITests \
scripts/validate-push-service-config.sh config/PushService.xcconfig
```

Registration tests inject notification, App Attest and HTTP seams. Delivered-read tests use real
Notification Center local deliveries and production chat visibility over a fixture Gateway;
`HostedDeliveredNotificationFixture` owns exact-ID cleanup. Neither suite proves APNs delivery.
`TRON_PUSH_SERVICE_ORIGIN` is shared with the Mac payload, so a change installs the Mac first.
Before shipping an identity, check its signed entitlements, pair a physical device, rotate its
token by reinstalling, and verify revoke and offline retry.

## Not here

The inbox sheets: [Settings](../UI/Settings/README.md) (`NotificationInboxView`). The relay: the
relay package.
