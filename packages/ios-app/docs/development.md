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

Physical `install` also holds the same inherited kernel rebuild lease as Mac replacement,
before protocol admission/build/signing. Contention exits 73 without building or installing.
`compile` takes neither physical-device nor Mac-replacement lease and never installs.

UI validation defines `HOSTED_TEST`, so a green UI run does not prove the shipping app compiles:
run `compile` after changing app views or their model APIs.

### Module layout

Where code goes and Core's `package` access rules: [Core](../Core/README.md#contract). After moving
API, regenerate, build, run the smoke set and the source policy check; a file carrying the protocol
constants keeps its path in `scripts/gateway_protocol_contract.py`.

### Type-checking cost

One slow `some View` body slows every incremental build (keep `@Observable` classes small, as
`AppModel`, whose behavior lives in extensions because the macro re-expands the whole class body
per member; split long modifier chains). Find hotspots in a throwaway DerivedData, then delete it:

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
([performance baseline](performance-baseline.md)). The Home-sheet scenario sets and restores its
dashboard filter through `AppLocalBehaviorSettings`, the mounted dashboard's settings owner;
writing its persisted preferences alone does not update a live dashboard.

Verify runs the scenarios of each `ProfilingTests` class that `scripts/profile.module.json` declares in
`iosScenarios` once (`--iterations 1`) on each change, and passes them only on their functional receipts
([verify](../../../tools/verify/README.md#owner-declared-profiling-scenarios)). Measured numbers stay diagnostic:
`--self-test` and `compare` are never validation gates.

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
<private-dir>`), never in the source tree. Accessibility witnesses: [UI locks](../UITests/Locks/README.md).

A synthesized tap or drag returns only after the app is idle, so a sheet detent it settles is read
directly afterwards. An `XCTNSPredicateExpectation` or `waitForExistence` polls first after about 1 s,
and each poll takes accessibility snapshots that cost seconds under host load, so a short window over
already-settled state fails on load, not behaviour (#2410). Settings Editor/Revert readiness reads
its hittability and unchanged 44-point bounds immediately, polling only while false. Each evaluation
must complete within the same monotonic five-second deadline; late success is rejected. A fixture that holds a reply to expose a loading state holds it until the
test releases it, never for a fixed time.

The hosted dashboard reveal probe reports shown section orders independently from animation starts.
Rows first mounted after the reveal window are already visible without an animation; they contribute
their shown order, not an animation count. The dashboard journey checks both section presence and an
unchanged animation count across live updates. Its new worker stays behind a named fixture release
permit until the test observes absence and posts the release; host/query latency cannot consume a
fixed injection window. The same fixture-release owner keeps task-list replies behind their existing
named permit.

Hosted foreground captures retain cumulative RPC counts and the latest 64 indexed, timestamped
method/parameter records in the native probe. Parameter JSON over 1,024 bytes is explicitly omitted; the probe reports
how many earlier records were dropped. Captures print the ordered before/after interval before any
fail-fast assertion and attach it with the native state, distinguishing Manage task reads (`limit: 20`)
from filtered Tasks reads without changing the exact read-count assertions. After dismissing Memory,
the Manage journey joins its original native stack and exact reveal-owned read batch before taking
the foreground baseline, so reveal work is not counted as a second foreground refresh.

### Simulator lifecycle

The skill's [Simulator lifecycle](../../../.agents/skills/tron-ios/SKILL.md#simulator-lifecycle).

### Parallel-worker resource ownership

Each worktree has its own lane, DerivedData and products; run one simulator job per worktree. At most
3 simulator-heavy jobs run at once on the Mac, across all worktrees and workers: `scripts/ios-test-lock.py
--host-slot` takes one of 3 slots for every `tron-ios-test` build or run, profiler run, Gateway E2E command
and `tron-ios-simulator install`, waits (naming the holders) when all are taken, and
`scripts/tron-ios-test slots` shows them. `tron-ios-test --host-slot-wait-seconds N`
opts into bounded acquisition (exit 73 when unavailable), without timing out admitted
work or changing the default unbounded wait. Pre-land verify uses 30 seconds and reports
unavailable iOS checks/tests as deferred, never passed; the batch retains unbounded admission. The Development simulator and each device hold host-wide
leases (exit 73 names the holder). Neither
PPID 1 nor high CPU proves abandonment: diagnose with `scripts/tron-ios-test status --all`.

### Test runner safety contract

- Only the exact owned simulator UDID reaches Xcode; only marked simulators are ever deleted.
- `build` stamps `build-identity.json`; `run` refuses products from another worktree or source
  state (exit 74). `scripts/ios-test-process.py` owns each Xcode process group and its deadlines.
  Timeout process listings and samples include only that group; the saved process listing is
  capped at 64 KiB, with up to four samples capped at 256,000 bytes each.
- `tron-ios-test` test phases and `ios-gateway-e2e-test run-ui` journey test phases pass their
  leased simulator UUID to the process supervisor for one passive XCTest idle capture.
  Builds and non-UI Gateway boundary tests do not opt in. A streamed `Wait for com.tron.mobile.testhost to idle` with no subsequent XCTest
  progress for 15 seconds is **provisional prolonged idle**, not a proven 60-second stall or a
  CPU/wakeup measurement. An actual `App animations complete notification not received` warning
  confirms only that same wait; it can also trigger capture when streamed output was delayed.
  Other XCTest progress retires the pending wait; host/Xcode chatter does not. No timeout,
  retry, animation setting, event or test result changes.
- Read `test-evidence/xctest-idle.json`, `app-capture.json`, `app-main-thread.sample.txt` and,
  when the app main queue answers, `app-animation-state.json` in the **same run directory**.
  Admission resolves that simulator's `com.tron.mobile.testhost` app container, its plist
  executable and exactly one live `proc_pidpath` match, rechecked before SIGUSR2 and sampling.
  No name-only process match, device input or other simulator is used. The hosted app's
  PID/launch readiness receipt must match the independently read kernel process birth
  (seconds/microseconds), and both executable and birth are rechecked immediately before
  signalling. Persistent readiness from another process incarnation cannot authorize SIGUSR2;
  sampling still proceeds if readiness fails, after rechecking the same executable/incarnation. An unanswered main queue retains `not-received-within-2s` plus the
  external sample rather than waiting for the app to recover.
- Capture runs off the stream reader with a 15-second total command budget, 3-second command
  limits (10 for the one-second sample and symbolication), a two-second snapshot wait and a bounded 20-second
  join on exit. Diagnostic commands are owned subprocess groups, killed on deadline/output
  overflow; any partial sample stdout survives its deadline. PID listing is capped at 64 KiB; sample and snapshot each at 256,000 bytes (sample
  retains its beginning if capped). Capture failure is evidence, never a test failure.
- `HostedPresentationProbe` installs this signal hook only in `HOSTED_TEST`. It reads the actual
  window layer trees (at most 16 windows, 512 layers, depth 24, 128 animations, 16 per layer)
  and timing/repeat/visibility metadata, never pixels, view text, animation keys or surface
  identities. Its at-most-16 weak coordinator references read aggregate mounted/activity
  counts directly from `PresentationActivityCoordinator`; activity counting is omitted and marked
  truncated above 64 mounted surfaces. These reads are not a second surface graph.
  Limits/truncation are explicit. Three fixed cache files hold readiness, the supervisor request and the latest snapshot;
  Kernel process birth, PID, random launch identity and a per-capture request nonce fence
  readiness and snapshots. No hook ships in normal builds.
  Public layer inspection cannot explain private SwiftUI/render-server work or prove why XCTest
  waited. A responsive main thread with repeating CA animation is evidence, not a root cause.
- A pass needs one executed, passing test and writes `coverage.json`; partial evidence is kept.
- A hosted launch without a fixture argument renders the production `ProductionSceneRoot`.

### Proving idle diagnostics

The existing process-evidence owner runs two exact UI selectors in separate supervised helper
invocations and then applies its artifact oracles. The default Python mode remains simulator-free:

```bash
python3 scripts/test-ios-process-evidence.py
python3 scripts/test-ios-process-evidence.py --hosted-idle
```

`--hosted-idle` owns the diagnostic pair: a `checkpoint` of
`TronMobileUITests/TronIdleControlUITests/testActualXCTestIdleControls` builds and runs first;
a serial `run` of `testBlockedMainThreadIdleCapture` reuses those exact products. It intentionally
pays an incremental build even when a calling verifier already built: standalone or source-only
selection must not depend on an undeclared fresh-product prerequisite. The owner streams helper
output, propagates build/run/oracle failures and cancellation, and resolves only each invocation's
single exact completion receipt, never a global newest run. Both run metadata source identities
must match the owner's unchanged worktree fingerprint. The pair requires one simulator slot at
a time. `scripts/ios.module.json` declares this class's owner command: normal verification selects
it after the ordinary phone/Pad matrix joins, not in the default Python lane or a combined UI shard.
The selected replacement owns both fresh runs and their artifact assertions; ordinary-shard exclusion
requires that replacement to be selected. Failed or deferred current builds prevent its invocation.

The artifact oracle checks real XCTest completion, exact run/simulator/app PID and kernel-birth
provenance, external main-thread stacks, live repeating CA animation and canonical surface counts.
Baseline, shipped active/covered orb and SwiftUI-repeat controls must finish without consuming the
capture; only the UIView repeat control holds idle long enough. The blocked-main control must
retain an unanswered signal and a sleeping main-thread stack while completing normally. Both
artificial holds last20s, solely to exercise capture, not change product/test timeouts.
The simulator-free process suite also launches two real native owned-process incarnations and
plants previous-birth readiness at the current PID. It requires no signal/request, live successor
and a retained external sample: this tests stale readiness without claiming actual PID reuse.

Retained runs can be inspected without a simulator:

```bash
python3 scripts/test-ios-process-evidence.py --idle-controls-run <first-run-dir> --blocked-main-run <second-run-dir>
```

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
scripts/ios-gateway-e2e-test all --only-testing TronMobileE2ETests/RealGatewayPiBoundaryTests/testSharedLinkUploadAndWebSocketLiveness
scripts/ios-gateway-e2e-test run-lan    # the two-lane case; needs a private LAN address
scripts/ios-gateway-e2e-test run-ui --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/<method>
```

`--only-testing` selects exact owned methods, repeats in requested order and survives
lease re-execution. Boundary `run`/`all`/`iterate` own the two default methods;
`run-lan` owns only its LAN method, while `run-ui` owns its UI journeys. No selector
means each command keeps its existing default sequence; foreign, class, suite and
removed native vendor-setup selectors refuse before any build, fixture or lease.

`run-ui` pairs the production scene against a fresh fixture per journey, leaving
`results/<utc>-ui.*`; its `app-log/` holds the hosted app's own `app.jsonl`,
cleared before the journey and copied after it (absent when the app wrote none). `TRON_IOS_E2E_UI_LANES=N` (1 to the 3 host slots) runs the
journeys on N lanes at once: the command's own lane plus `<lane>-uiK` lanes, each
with its own lease, host slot, simulator and fixture (`laneK/results/`), taking
journeys from one queue, longest first by `TRON_IOS_E2E_UI_JOURNEY_SECONDS` (JSON
journey to seconds). After a failure no lane starts another journey; each journey's
output prints whole when it ends. An extra lane that cannot be leased or booted runs
nothing and is named; the others cover its journeys. The invitation journey requires the full accepted prompt
label before and after foreground, independent of AX role: overflowing prompts
are reader buttons. Generated navigation-title snippets are not transcript
retention evidence and cannot satisfy the full-label query. `status`, `logs`, `stop` and `clean` act only on this worktree's fixture; run
`clean` before deleting a worktree. DTO changes need Gateway tests and Swift decoding.
The fixture's canonical lifecycle root is its isolated `HOME/Workspace` (exact spelling).
`testProjectLifecycleApproveCreatesUntrustsAndTrusts`, `testProjectLifecycleDenialRetainsUntrustedRepository`,
`testProjectLifecycleRefusedApprovalShowsItsReason` and `testProjectLifecycleBusyTrustUsesCanonicalReason`
exercise the native project pages;
the busy journey seeds an empty trust store and a real linked-worktree repository only in
that fixture. Run these selectors individually;
`TRON_IOS_E2E_UI_RUN_TIMEOUT_SECONDS=300` bounds a journey without changing XCTest oracles.

## Manual iOS release validation and delivery

The repository never archives or uploads production iOS artifacts. The maintainer selects a
checked commit with a clean checkout (`scripts/tron version check`), runs the smoke set, required
journeys and a physical review, runs `scripts/verify-ci-toolchain.sh release`, archives
`Tron Release`, checks it with `packages/ios-app/scripts/verify-archive-privacy.sh <xcarchive>`,
and uploads through Xcode Organizer.

## Privacy

Local-network and camera usage only. Provider credentials never enter fixtures, defaults or logs.

### Diagnostic source identity

`TronBuildIdentity.json` stamps the app's commit and dirty state into exports.

## Moved sections

### Dashboard controls
[Automations](../Sources/UI/Automations/README.md#verify); Home view: [Chat](../Sources/UI/Chat/README.md#verify).
### Research files and retired Knowledge routes
[Research files](knowledge-sources.md).
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
