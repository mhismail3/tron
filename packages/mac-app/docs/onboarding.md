# Tron Mac onboarding

The onboarding UI is a projection of current system truth, not persisted page
position. `GatewayOnboardingModel` owns every probe and mutation and uses
`GatewayLifecycleCoordinator` for service changes.

## Flow

1. **Welcome** explains that Tron runs from the menu bar.
2. **Tailscale** requires a connected live address in `100.64.0.0/10`.
3. **Install Gateway** validates and registers the mode-specific Login Item,
   starts it, and requires authenticated health.
4. **Permissions** requires Full Disk Access and a successful Gateway restart.
5. **Connect iPhone** includes iPhone installation guidance, authenticated
   health, the current one-time code, and explicit Refresh or Retry actions.
6. **Done** atomically records completion and opens the menu-bar experience.

Back and repeated primary actions are disabled during mutations. Probes are
cancelled when superseded or when the view disappears. Each probe carries a
generation ticket, so an older completion cannot advance the wizard or replace
newer state.

Every step uses one fixed 480 by 440 point window and the same header, body, and
footer regions. Step content cannot resize or recenter the shell; titles retain
priority over the fixed progress pill, forward pages push in from the right,
Back pushes in from the left, and card shadows can render into the window's
horizontal gutters without being clipped. Motion is derived from each actual
source and destination page, so the first direction reversal cannot inherit a
stale transition from the prior navigation. Navigation controls remain pinned
to the same bottom inset.

## Interrupted setup

On launch, the model observes Tailscale, service registration, authenticated
health, permissions, and pairing readiness. It presents the earliest incomplete
step. It does not restore temporary button, progress, error, or pairing values.

A missing Mac state record begins at Welcome. A corrupt record begins at Welcome
with a repair message. Service approval requirements, state-write failures,
permission restart failures, and pairing failures remain on the current step
with a safe retry action.

## Accessibility

Every step has a VoiceOver header and progress label. Focus returns to the new
header after navigation. Status icons are decorative when adjacent text carries
the state, errors are combined into readable announcements, and Reduce Motion
uses an opacity transition instead of directional movement.

## Completion boundary

Completion is valid only after authenticated Gateway health succeeds and the
owner-only state record is atomically written. The menu-bar pairing window has
its own ephemeral model and never changes onboarding completion.
