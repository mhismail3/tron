# Tron iOS development

The iOS runbook index. The [tron-ios skill](../../../.agents/skills/tron-ios/SKILL.md) owns the
build matrix, signing, device installs, simulator lanes and leases; each script's `--help` is the
reference for its flags and exit codes. Each module's focused journeys are in the **Verify**
section of its README ([source map](architecture.md#source-map)).

## Fresh-clone prerequisites

Use the toolchain pinned in `config/ci-toolchain.env`; the untracked project comes from
`scripts/install-ci-tools.sh xcodegen`, then `scripts/tron ios generate`.

## Generate and build

`project.yml` is project truth. `Sources/Info.plist` is the only orientation authority (iPhone
portrait, iPad all four); add no `INFOPLIST_KEY_UISupportedInterfaceOrientations*` settings.
Static checks that boot nothing:

```bash
packages/ios-app/scripts/test-source-policy.sh        # orientation, sound, managed sheets, Core imports
packages/ios-app/scripts/test-build-matrix-policy.sh  # optimized Tron Device settings, no compile
scripts/tron-ios-device compile                       # unsigned LocalDevice compile, no device or lease
```

UI validation defines `HOSTED_TEST`, so a green UI run does not prove the shipping app compiles:
run `compile` after changing app views or their model APIs.

### Module layout

Where code goes and Core's `package` access rules: [Core](../Core/README.md#contract). After moving
API, regenerate, build, run the smoke set and the source policy check; a file carrying the protocol
constants keeps its path in `scripts/gateway_protocol_contract.py`.

### Type-checking cost

One slow `some View` body slows every incremental build (keep `@Observable` classes small, as
`AppModel`; split long modifier chains). Find hotspots in a throwaway DerivedData, then delete it:

```bash
cd packages/ios-app && xcodebuild build -project TronMobile.xcodeproj -scheme "Tron UI Validation" \
  -configuration Test -destination 'generic/platform=iOS Simulator' -derivedDataPath "$TMPDIR/tron-typecheck" \
  'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -warn-long-function-bodies=100 -Xfrontend -warn-long-expression-type-checking=100'
```

## Build matrix

Configurations, schemes, identities and push routes: the skill's
[routing table](../../../.agents/skills/tron-ios/SKILL.md#routing-table). Builds go through
`scripts/tron-xcodebuild` (`-jobs min(4, CPUs)`, nice +10; an explicit `-jobs` fails).

### Over-the-air development install

`share` publishes the validated `Tron Device` + `LocalDevice` artifact, built from fetched
`origin/main` in a disposable worktree, to a tailnet-only install page; only when the user asks.
The maintainer-approved share host owns only port 8443's `/` entry.
Each publication gets its own UUID-bearing build ID and immutable manifest/IPA URLs,
even for concurrent calls sharing a revision and clock value. Retention reads publication
time and identity from `build.json`, not a filename grammar; page/latest aliases stay stable.

```bash
scripts/tron-ios-device share --title TITLE --notes NOTES
scripts/tron-ios-device share-host status
python3 scripts/test-tron-ios-device-share.py  # fixture-only publisher, server and host; no build
python3 scripts/test-ios-share-concurrency.py  # no-live default sentinel, concurrency and URLs
```

### Profiling a real slowdown

`scripts/tron-profile compare` is the only regression verdict (exit 3). Decide CPU changes on
`cpu.instructions`; simulator values are host-CPU proxies, never battery evidence.

#### iOS scenario profiler

```bash
scripts/tron-profile ios --self-test          # prove the measurement path first
scripts/tron-profile ios --scenario idle-chat --scenario tool-loop
scripts/tron-profile compare BASE_RUN_DIR CANDIDATE_RUN_DIR
```

It shares the test runner's lane and lease, builds `DevicePerformance`, and refuses a scenario
whose workload or render check diverged. Scenarios: `ProfilingTests/`
([performance baseline](performance-baseline.md)).

#### Attribution: finding the owner

`scripts/tron-profile ios --self-test --trace time-profiler` proves attribution;
`--trace` writes `attribution.json`/`.md` beside the trace, and `compare` refuses traced reports.
Host-wide exports have a 2 GiB budget, so trace a product scenario with `--iterations 1
--window-seconds <n>`. On a device the user profiles `Tron Device`, or runs
`scripts/tron-profile device --attach --device <UDID> --template time-profiler --seconds 30`.

### Always-on diagnostics

What iOS records: [observability](../../gateway/docs/observability.md); export it from **Settings → Logs**.

## Efficient focused tests

Native UI validation is integration/end-to-end; the charter permits four separate bounded logic groups,
but no hosted logic-test target is introduced here. Build once, run
only the owning journeys, and rebuild after an edit (stale products are refused):

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/<Class>/<method>
scripts/tron-ios-test run          # the smoke set (SMOKE_ONLY_TESTING in scripts/tron-ios-test)
scripts/tron-ios-test checkpoint   # build, then the smoke set
python3 scripts/test-ios-test-infrastructure.py
python3 scripts/test-ios-process-evidence.py  # owned-group timeout diagnostics; no Xcode
```

Repeat `--only-testing` for adjacent journeys; a class selector runs the class. Count the methods
executed: an unmatched selector is not evidence. Screenshots stay in the reported
`TestResults.xcresult` (`xcrun xcresulttool export attachments --path <xcresult> --output-path
<private-dir>`), never in the source tree. Goldens: [UI locks](../UITests/Locks/README.md).

### Simulator lifecycle

The skill's [Simulator lifecycle](../../../.agents/skills/tron-ios/SKILL.md#simulator-lifecycle).

### Parallel-worker resource ownership

Each worktree has its own lane, DerivedData and products; run one simulator job per worktree. At most
3 simulator-heavy jobs run at once on the Mac, across all worktrees and workers: `scripts/ios-test-lock.py
--host-slot` takes one of 3 slots for every `tron-ios-test` build or run, profiler run, Gateway E2E command
and `tron-ios-simulator install`, waits (naming the holders) when all are taken, and
`scripts/tron-ios-test slots` shows them. The Development simulator and each device hold host-wide
leases (exit 73 names the holder). Neither
PPID 1 nor high CPU proves abandonment: diagnose with `scripts/tron-ios-test status --all`.

### Test runner safety contract

- Only the exact owned simulator UDID reaches Xcode; only marked simulators are ever deleted.
- `build` stamps `build-identity.json`; `run` refuses products from another worktree or source
  state (exit 74). `scripts/ios-test-process.py` owns each Xcode process group and its deadlines.
  Timeout process listings and samples include only that group; the saved process listing is
  capped at 64 KiB, with up to four samples capped at 256,000 bytes each.
- A pass needs one executed, passing test and writes `coverage.json`; partial evidence is kept.
- A hosted launch without a fixture argument renders the production `ProductionSceneRoot`.

## Gateway fixture work

Real-Gateway boundaries run against a per-worktree fixture Gateway and fault proxy.
The proxy validates the canonical Gateway entrypoint but preserves the caller's
launch path across restarts so the harness's PID ownership proof stays valid.
Boundary setup writes Home role queues and ordinary-chat model/compaction values to
their respective Session scopes. Compaction snapshot provenance uses `session`,
`global`, `project` or `default`; production admission rejects retired `chat` tags.

```bash
scripts/ios-gateway-e2e-test all        # prepare, build, run RealGatewayPiBoundaryTests
scripts/ios-gateway-e2e-test iterate    # after an affected Swift edit
scripts/ios-gateway-e2e-test run-lan    # the two-lane case; needs a private LAN address
scripts/ios-gateway-e2e-test run-ui --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/<method>
```

`run-ui` pairs the production scene against a fresh fixture per journey, leaving
`results/<utc>-ui.*`. The invitation journey checks sent transcript content rather
than a static-text AX role: copyable message rows are interactive controls. `status`, `logs`, `stop` and `clean` act only on this worktree's fixture; run
`clean` before deleting a worktree. DTO changes need Gateway tests and Swift decoding.
The fixture's canonical lifecycle root is its isolated `HOME/Workspace` (exact spelling).
`testProjectLifecycleApproveMovesAndArchives`, `testProjectLifecycleDenialRetainsUntrustedRepository`
and `testProjectLifecycleBusyArchiveUsesCanonicalReason` exercise the native project pages;
the busy journey seeds an empty trust store and a real linked-worktree repository only in
that fixture. It never publishes a GitHub repository. Run these selectors individually;
`TRON_IOS_E2E_UI_RUN_TIMEOUT_SECONDS=300` bounds a journey without changing XCTest oracles.

## Manual iOS release validation and delivery

The repository never archives or uploads production iOS artifacts. The maintainer selects a
checked commit with a clean checkout (`scripts/tron version check`), runs the smoke set, required
journeys and a physical review, runs `scripts/ios-release-toolchain-doctor.sh`, archives
`Tron Release`, checks it with `packages/ios-app/scripts/verify-archive-privacy.sh <xcarchive>`,
and uploads through Xcode Organizer.

## Privacy

Local-network and camera usage only. Provider credentials never enter fixtures, defaults or logs.

### Diagnostic source identity

`TronBuildIdentity.json` stamps the app's commit and dirty state into exports.

## Moved sections

### Dashboard controls
[Automations](../Sources/UI/Automations/README.md#verify); Home view: [Chat](../Sources/UI/Chat/README.md#verify).
### Knowledge sheet
[Automations](../Sources/UI/Automations/README.md#verify).
### Automations sheet
[Automations](../Sources/UI/Automations/README.md#verify).
### Sessions settings and model search
[Settings](../Sources/UI/Settings/README.md#verify); picker: [Onboarding](../Sources/UI/Onboarding/README.md#verify).
### UI motion and loading surfaces
[Presentation](../Sources/UI/README.md#verify).
### Transcript surface visual review
[Settings](../Sources/UI/Settings/README.md#verify).
### Settings scope visual review
[Settings](../Sources/UI/Settings/README.md#verify).
### Shared cursor-window lists
[Presentation](../Sources/UI/README.md#verify).
### Connection recovery diagnostics
[State](../Sources/State/README.md#verify).
### New Session draft and accepted-create boundary
[Chat](../Sources/UI/Chat/README.md#verify).
### Composer image paste
[Chat](../Sources/UI/Chat/README.md#verify).
### Tool results and question actions
[Chat](../Sources/UI/Chat/README.md#verify).
### Chat top-blur validation
[Chat](../Sources/UI/Chat/README.md#verify).
### Push notification release configuration
[Notifications](../Sources/Notifications/README.md#verify).
### Session subagent activity
[Chat](../Sources/UI/Chat/README.md#verify).
### Chat transcript layout
[Chat](../Sources/UI/Chat/README.md#verify).
### Inline display orientation evidence (CT-23)
[Chat](../Sources/UI/Chat/README.md#verify).
### Post-Stop configuration qualification
[Chat](../Sources/UI/Chat/README.md#verify).
### Home transcript chip previews
[Chat](../Sources/UI/Chat/README.md#verify).
### Focused Home tasks verification
[Chat](../Sources/UI/Chat/README.md#verify).
