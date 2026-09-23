# Watch audio recording

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-23, MIGRATION
- **Goal:** A native Tron Watch app that reliably records, pauses, resumes and stops audio, then automatically archives the original capture on the paired Tron Mac through the iPhone.

Follow the [plan protocol](README.md#protocol) to claim tasks and hand off. The
work happens on branch `feat/watch-audio-recording`.

## Goal and constraints

Reliability outranks code size or marginal battery savings. Ordinary
connectivity failures must not require user troubleshooting.

**Product contract**

- Capture works without a reachable iPhone, Mac or network.
- No arbitrary duration cutoff beyond real battery, storage and platform limits;
  show actionable capacity problems before capture when known.
- Start succeeds only after microphone access, file preparation and audio capture
  succeed. A running timer is never proof of a live microphone.
- Pause stops capture, persists state and permits suspension; Resume continues
  the same logical recording through explicit user interaction.
- Stop finalizes locally and starts delivery without waiting for the Mac. A new
  recording can start while earlier ones await delivery.
- Completed audio survives process relaunch. Interrupted recording is recovered
  explicitly; never claim audio continued while the process was dead.
- Retries and recovery are automatic. Permission denial, unavailable storage,
  revoked pairing and a required reopen get plain-language explanations.
- Never silently erase unsent audio, hide an interruption, or label a recording
  saved on Mac before validating the durable Mac receipt.
- Segmentation introduces no unreported capture gaps; pauses and interruptions
  stay distinguishable in the source timeline.

This is not a promise of uninterrupted recording through battery exhaustion,
reboot, force-quit or OS microphone preemption.

**Out of scope for this increment:** transcription, live speech recognition, a
Notes dashboard, editing, classification, transformations, direct Watch-to-Mac
networking, complications and processing automations. Preserve source audio and
provenance so these can be added without recapturing.

**Safety:** hardware qualification is a release gate, and it does not authorize
an agent to install an app or approve microphone permissions. Gateway rebuilds,
updates and restarts remain manual user actions; never use production lifecycle
changes for failure injection. No device erase, Keychain reset or
reinstall-as-recovery. No automatic deletion of the final mobile copy until the
user settles the backup and retention policy.

## Context

State as of commit `a7f614ae8` on 2026-09-23, from the branch's status report.
Implemented behavior is documented in the branch's owning docs (new
`watch-recording-delivery.md` in `packages/ios-app/docs/` and new `recordings.md`
in `packages/gateway/docs/`), not here.

- **Built in source:** the `TronWatch` watchOS app target embedded in the iPhone
  product; one-minute CAF linear-PCM segment capture with a bounded writer queue
  and a 512-segment cap; durable Watch manifests; WatchConnectivity file transfer
  into a bounded, idempotent iPhone inbox; iPhone background `URLSession`
  delivery pinned to one paired profile; Gateway recording ingestion with
  validated final receipts relayed back to the Watch.
- **Validated:** project generation, strict watchOS and iOS source typechecks, a
  watchOS target build for arm64 and arm64_32 with the correct companion bundle
  identifiers, and focused Gateway recording tests.
- **Not validated:** any hardware, simulator, signing or install qualification;
  audio continuity, energy or soak; background transfer; the embedded Watch app in
  signed-artifact validation.
- **Tooling note:** Gateway recording tests ran with Homebrew Node because the
  bundled Gateway Node rejected a native binding's Team ID. This machine has
  watchOS SDKs but no Watch simulator runtime, and a direct iPhone target build
  wrongly compiles the embedded Watch sources with the iOS SDK.

## Plan rules

**Ownership:** one recording coordinator owns Watch capture and command
serialization. One phone delivery coordinator owns accepted transfers,
independent of views, selected chats and WebSocket epochs. One Gateway recording
store (under `packages/gateway/src/recordings/`) owns admission, publication,
finalization and receipts. Use native platform transfers, not a second
background framework.

**State:** capture state (preparing, recording, paused, finalizing, stopped,
interrupted) and delivery state (local, queued, received by phone, waiting for
Mac, saved on Mac) are separate. Persist identities and durable transitions,
not timer ticks or UI projections. No general event journal, SQLite mirror or
generic sync engine.

**Retained source:** recordings live under the resolved Tron workspace at
`files/recordings/<recording-id>/` with a `recording.json` and ordered segments
with per-segment sidecars. Keep recording ID and schema, source versions, UTC
timestamps and clock offsets, sample timeline, ordered segment identities,
format epochs, byte lengths, frame counts, hashes, pause and interruption ranges,
stop reason and recovery status. Originals are never replaced by derived
artifacts. Workspace unavailability fails closed with no fallback location.

**Custody:** Watch and phone keep sources until a validated Mac receipt. A
phone-custody acknowledgement is never shown as saved on Mac. Pending files are
never eviction candidates.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| W-1 | Done | Watch target, capture coordinator and Start/Pause/Resume/Stop screen in source | none | watch-audio branch session |
| W-3 | Done | Gateway recording ingestion, idempotent segment admission and validated final receipts | none | watch-audio branch session |
| W-4 | Done | Watch-to-iPhone file transfer into a durable, bounded, idempotent inbox | W-1 | watch-audio branch session |
| W-MERGE-1 | Ready | Before merging `feat/watch-audio-recording`: delete the branch's old plan file (`watch-audio-plan.md` in `packages/ios-app/docs/`) and its link in `packages/ios-app/README.md`, and make sure every implemented fact from its status report lives in the branch's owning delivery and recordings docs | none | |
| W-2a | Ready | Missing capture tests: writer callback stress, queue saturation, rotation at non-48-kHz rates, writer failures | W-1 | |
| W-4a | Ready | Missing delivery tests: Watch transfer retries, iPhone move/index crash recovery, cleanup regressions | W-4 | |
| W-5a | Ready | iPhone delivery gaps: protected-data lock and credential-revocation delivery states, Gateway capability and status reconciliation | W-4 | |
| W-7a | Ready | Extend signed-artifact and helper validation to the embedded Watch app (built Info.plist, entitlements, install) | W-1 | |
| W-2b | Needs scoping | Capture format and continuity qualification: a time-coded acoustic fixture across segment boundaries and pause/resume, abrupt-kill and write-failure recovery, measured unsaved-tail bound; confirm or replace CAF/PCM | W-2a | |
| W-6 | Needs scoping | Low-maintenance UX finish and retention policy; the user decides mobile-copy retention and backup policy before any automatic deletion | W-5a | |
| W-7 | Needs scoping | Physical qualification on the paired Watch and iPhone per the scenarios below, then a manually activated candidate; the user installs and approves permissions | W-2b, W-4a, W-5a, W-7a | |

## Task details

### W-7 — Hardware qualification scenarios

| Scenario | Required evidence |
| --- | --- |
| 2-hour recording, then toward 8 hours if battery permits | Playable original, timeline continuity, measured battery, CPU, memory and storage; actual duration ceiling |
| Repeated segment rotations and pause/resume | No unexplained missing or duplicated spans |
| Watch face, wrist down, another app; debugger disconnected | Capture stays active where the OS permits |
| Calls, Siri, alarms, route changes, low storage | Accurate interruption or stop state; prior audio preserved |
| Abrupt Watch termination or reboot | Completed segments survive; unfinished tail handled honestly |
| Phone absent during capture, later reconnect | Automatic byte-identical delivery after Stop |
| Phone locked, suspended, terminated or force-quit | Supported background paths work; a required reopen resumes pending work |
| Mac asleep or offline, VPN unavailable, update or revocation | Files stay local; no wrong-destination uploads |
| Duplicate or reordered uploads, lost commit response | One logical recording; stable verified receipt |
| Server crash, disk full, corrupt or truncated files | No false completion or loss of accepted bytes |
| Receipt delay, interrupted local cleanup | No premature deletion |

Release only with no known silent-loss, false-success or premature-deletion bug,
and with measured interruption and recovery limits documented. Target watchOS 26
on the actual paired hardware (expected Series 9 or 10); confirm the exact
models first and claim no others.

## Handoff log

### MIGRATION · Done · 2026-09-23 · planning session

- Result: converted the original design draft and the branch's status report into this plan. The draft's goal, product contract and architecture became the constraints and plan rules; its seven work packages became tasks, with statuses taken from the branch status report at `a7f614ae8`.
- Evidence: the branch's commits `11cf698c0` (durable Watch recording ingestion), `b348d0874` (delivery) and `a7f614ae8` (modern Watch target configuration), and its status report. Nothing was re-run for this migration.
- Changes: this file. The untracked draft copy and its uncommitted README link on `main` were removed. The branch still carries its own copy until W-MERGE-1.
- Deviations: the draft proposed AAC through `AVAudioRecorder` as the baseline. The branch instead writes continuous microphone input as one-minute CAF linear-PCM segments, which W-2b must qualify or replace. Platform reference links from the draft are dropped; they belong in the owning docs if still needed.
- For the next agent: the branch worktree (`tron-watch-audio`) had 5 uncommitted files on 2026-09-23 (changes to the delivery and recordings docs, `project.yml`, the Watch store tests, and a new connectivity test double). Coordinate with its owner before claiming a task that touches those files. Do W-MERGE-1 as part of merging the branch.
