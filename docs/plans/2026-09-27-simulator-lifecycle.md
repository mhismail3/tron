# Simulator lifecycle

- **Started:** 2026-09-27
- **Status:** Active
- **Last updated:** 2026-09-28, SIM-9 done; SIM-8 runs on its own branch
- **Goal:** Agents run as many iOS simulators in parallel as the Mac can afford, and every simulator, process and artifact the test tooling creates is released automatically, including after crashes, so the live Gateway never runs short of memory.

## Goal and constraints

Parallel simulators are wanted: the Mac has 18 cores and 36 GB, and several
agent sessions test at once. What must stop is resources outliving the work
that needed them. The phone's Gateway connection is the thing being protected.

- **Cleanup must not depend on agent discipline.** The `AGENTS.md` cleanup rules
  stay, but the tooling is the owner: a command that boots a simulator releases
  it when the command ends, and anything a crash or kill leaves behind is
  reclaimed by the next invocation of any Tron test tool.
- **Parallelism is limited by memory, not by a fixed count.** Admission reads
  the machine's memory state when a simulator is about to boot.
- **Never touch what a live owner holds.** A simulator whose lease is held by a
  running process is never shut down or deleted. The Development simulator
  (`scripts/tron-ios-simulator`) holds the paired app container and is never
  deleted or erased by any of this.
- **No test-behaviour change.** Selectors, tiers, exit codes, products and
  result layout stay as they are, except where a task says otherwise.
- Gateway rebuilds and restarts stay manual (`AGENTS.md` rule 8).

## Context

Measured 2026-09-27 while the user saw Gateway disconnect and reconnect cycles:

- Swap reached 19.8 GB of 21.5 GB. Twelve Tron test simulators were booted, most
  idle for hours or days (`Tron iOS Tests` 1 day 16 h, a Development "iPhone 17
  Pro" 4.5 days with two app copies, `Simulator.app` 4.5 days).
- A booted simulator's own processes use about 2 GB of physical footprint;
  CoreSimulator services add about 2.7 GB shared across booted devices.
- After shutting the idle ones down: swap 1.7 GB, 83% memory free.
- Disk: 137 GB of simulator devices; per-lane devices 3–14 GB each; 1,790 result
  runs (5 GB); build products for eight worktrees that no longer existed
  (8.8 GB).

Why it accumulates, from the code:

1. `scripts/ios-test-simulator.py` `provision` boots the owned simulator, and
   nothing ever shuts it down. `scripts/ios-test-lock.py` releases the lease
   when its command ends but leaves the simulator booted.
2. Parallel lanes are two undocumented environment variables
   (`TRON_IOS_TEST_STATE_DIR`, `TRON_IOS_TEST_DEVICE_NAME`). Each creates a new
   device; nothing lists or removes lanes.
3. `scripts/tron-ios-test clean` deletes the shared results root for every
   worktree, so agents are told never to run it and nothing is cleaned.
4. Results and per-worktree products are never pruned.
5. `scripts/tron-profile-ios` and `scripts/ios-gateway-e2e-test` share the
   same lease and provisioner, so they inherit the same gaps.

## Plan rules

- **Owned** means a simulator with a Tron ownership marker (`simulator.json`
  written by `scripts/ios-test-simulator.py`). Only owned simulators are ever
  shut down or deleted automatically. The Development simulator is owned by
  `scripts/tron-ios-simulator` and is only ever shut down, never deleted.
- **Orphaned** means an owned simulator that is booted while no live process
  holds its lease (`flock` on its `lease.lock` is free).
- Every isolated test in this plan follows the testing policy: write the
  failure modes first, then the code. The infrastructure tests in
  `scripts/test-ios-test-infrastructure.py` (synthetic `xcrun` and `simctl`)
  are the owner for runner behaviour; each task adds cases there for its own
  written failure modes, including a crash or kill case.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| SIM-1 | Done | Release on exit: the lease holder shuts down the simulator its command booted when the command ends, on success, failure, timeout or signal; an explicit keep-booted option serves tight test-fix loops and is itself released by the sweep | none | chat scroll session (worker lanes), 2026-09-27 |
| SIM-2 | Done | Sweep: every Tron test tool invocation first shuts down orphaned owned simulators (booted, lease free); `scripts/tron-ios-test reap` runs it on demand | SIM-1 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-3 | Done | Named lanes: `--lane NAME` (and `TRON_IOS_TEST_LANE`) names a lane; `lanes` lists every lane with its worktree, state, lease holder, last use and disk size; `lane-remove NAME` deletes its simulator, state and products; the sweep deletes lanes unused for 7 days | SIM-2 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-4 | Done | Memory admission: before booting, read memory pressure and swap; if booting would leave less than a set reserve, fail fast with exit 73 and print what is booted, by which worktree and lane, and for how long | SIM-2 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-5 | Done | Scoped clean and pruning: `clean` removes only this worktree's or lane's simulator, products and runs; `prune` keeps the newest results per worktree and deletes products whose worktree no longer exists; the sweep prunes too | SIM-3 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-6 | Done | One view: `scripts/tron-ios-test status --all` lists every booted simulator (owned lanes, the Development simulator, unowned ones), its owner, lease holder and uptime, plus `Simulator.app` | SIM-3 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-7 | Done | Same lifecycle everywhere: `scripts/tron-profile-ios`, `scripts/ios-gateway-e2e-test` and `scripts/tron-ios-simulator` use the lane, release, sweep and admission paths; the Development simulator reports idle uptime and is shut down by its `stop` | SIM-1, SIM-2, SIM-4 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-8 | Claimed | Diagnosable disconnects: the Gateway records the Mac's memory pressure and swap in its diagnostics when phone connections drop and reconnect, with a row in `packages/gateway/docs/observability.md` and a test | none | chat scroll session (worker lanes), 2026-09-27 |
| SIM-9 | Done | Docs and guidance: `packages/ios-app/docs/development.md`, `.agents/skills/tron-ios/SKILL.md`, `.agents/skills/tron-workspace-housekeeping/SKILL.md` and `AGENTS.md` describe lanes, release, sweep and admission, and replace the manual cleanup steps the tooling now owns | SIM-1 to SIM-7 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-10 | Ready | Remove `TRON_IOS_TEST_STATE_DIR` and `TRON_IOS_TEST_DEVICE_NAME` in favour of lanes, with every caller, once the energy-efficiency plan no longer runs profiling lanes through them | SIM-3 | |

## Task details

### SIM-1 — Release on exit

Owning files: `scripts/ios-test-lock.py`, `scripts/tron-ios-test`,
`scripts/ios-test-simulator.py`.

- The lease holder already outlives its command and forwards signals. It
  records whether this command booted the simulator (as opposed to finding it
  booted under a keep-booted lease) and, in its `finally`, shuts it down after
  the command exits. A shutdown failure is reported, never masks the command's
  own exit code.
- Keep-booted: an explicit option (for example `--keep-booted`) records the
  intent in the lease metadata; the next command in the same lane reuses the
  booted simulator. The sweep (SIM-2) shuts it down once no lease has been held
  for a bounded idle time, so a forgotten keep cannot pin memory.
- Failure modes to write first: command succeeds; command fails; per-process
  timeout (exit 75); SIGINT, SIGTERM and SIGHUP to the holder; the holder itself
  is killed with SIGKILL (covered by SIM-2); simulator already shut down by
  someone else; shutdown hangs (bounded).
- Accept: `scripts/tron-ios-test run` for one owner leaves no Tron simulator
  booted; measured boot cost per run is recorded in the handoff.

### SIM-2 — Sweep

Owning files: `scripts/ios-test-simulator.py`, `scripts/tron-ios-test`.

- Discovery is the ownership markers under `~/.tron/internal/` (the default
  state directory and every lane directory), not device names.
- For each marker: if the device is booted and its `lease.lock` can be locked
  without blocking, shut it down (it is orphaned). Holding the lock during the
  shutdown excludes a racing command.
- Runs at the start of every `tron-ios-test`, `tron-profile-ios` and
  `ios-gateway-e2e-test` invocation and is idempotent and bounded in time.
- Failure modes: marker for a deleted device; lock held by a live process
  (skip); two sweeps at once; a command starting mid-sweep; a device renamed or
  recreated under the same name without a marker (skip, report).

### SIM-3 — Named lanes

- `--lane NAME` maps to one state directory and one device name; the default
  lane is today's `Tron iOS Tests`. The two environment variables stay until
  SIM-10: the energy-efficiency plan's profiling lanes use them while this plan
  runs, and removing them mid-run would break that session.
- A lane's marker records its creating worktree and last-used time.
- `lanes`, `lane-remove NAME` (refuses while its lease is held), and removal of
  lanes unused for 7 days by the sweep.

### SIM-4 — Memory admission

- Before `simctl boot` (not when reusing an already booted lane), read
  `memory_pressure` and `vm.swapusage`. Refuse when free memory would fall
  below a reserve (initial proposal: 8 GB free and swap under 4 GB; tune from
  measurements recorded in the handoff).
- Fail fast with exit 73 and the `status --all` table; do not wait or retry.
  The caller decides whether to wait.
- Failure modes: pressure readers unavailable (fail open with a warning, since
  the tooling must still work in CI); reserve already breached by non-test
  processes (message says so).

### SIM-5 — Scoped clean and pruning

- `clean` for the current worktree and lane only; the shared results root is
  never removed wholesale.
- `prune`: newest 50 runs per worktree and anything younger than 7 days are
  kept; products whose stamped worktree path no longer exists are deleted.

### SIM-6 — One view

- `status --all` output is the table SIM-4 prints on refusal, so an agent sees
  the same picture before its final response and when admission fails.

### SIM-7 — Same lifecycle everywhere

- The profiler runs one scenario set per lane under the same release and
  admission; its reports already warn about host load, and admission makes
  those runs less noisy.
- The Development simulator is never deleted. `status --all` flags it when
  booted with no app interaction for a bounded time; `scripts/tron-ios-simulator stop`
  remains the way to release it.

### SIM-8 — Diagnosable disconnects

- The incident signal that would have diagnosed the 2026-09-27 reconnect
  cycles in one step: host memory pressure and swap next to the Gateway's
  connection drop and reconnect records. Owner and format follow
  `packages/gateway/docs/observability.md`; add the row and its test in the
  same change.

## Handoff log

### Approval · 2026-09-27 · chat scroll session

- Result: the user approved the plan and asked for it to be implemented now in
  an isolated worktree by worker agents.
- Deviations: the protocol claims one task at a time; SIM-1 to SIM-7 and SIM-9
  are claimed together because one supervised lane implements them in order on
  one branch (`sim-lifecycle`), and SIM-8 runs in parallel on its own branch
  (`sim-8-gateway-memory`). SIM-10 split out of SIM-3 (see its row).

### SIM-1 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: the lease holder owns the lane's simulator for the whole command and
  releases it when the command ends - on success, on failure, on the runner's
  own process timeout (75) and on SIGINT/SIGTERM/SIGHUP - unless the command
  asked for `--keep-booted`, which it records in the lease metadata
  (`simulator.keep_booted` with `simulator.booted_when_leased`).
  `scripts/tron-ios-test run` therefore leaves no owned simulator booted.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` — 32 tests, 69 s
  wall (25 tests, 122 s before this change; the seven SIM-1 cases and the two
  new runner cases run against the synthetic xcrun only). Real-machine check
  with every state/discovery root in a fresh `/tmp` lane and only a device this
  task created: `provision` (create+boot) 22.7-122.3 s depending on host load
  and runtime warmth; booting an already-created lane device after a release
  5.2 s; provisioning an already-booted lane (the `--keep-booted` reuse path)
  2.5 s; `--keep-booted` left the device Booted and the lease idle metadata
  truncated; the same lock run without `--keep-booted` left it Shutdown. The
  probe device was deleted; `xcrun simctl list --json` before/after the probe
  is identical and the Mac's only other booted device (a live session's
  `Tron iOS Test`) was never touched. Measured cost of release-on-exit per run:
  about 5 s of boot for an existing lane, plus a one-off 100 s create when the
  lane is new.
- Changes: this commit.
- Kept on purpose: `scripts/tron-profile-ios` and `scripts/ios-gateway-e2e-test`
  still call `scripts/ios-test-lock.py` without `--marker`, so they keep today's
  behaviour (their lease ends, their simulator stays booted) until SIM-7 wires
  the release and sweep into them; `scripts/ios-test-lock.py` therefore takes the
  release marker as an option rather than a requirement.
- Deviations: signal handlers now cover taking the lease and starting the
  command, not only waiting for it, and a signal that arrives while the command
  is starting is forwarded as soon as the child exists. Without that, a signal
  delivered in the (pre-existing) startup window killed the holder, orphaned its
  command and left the simulator booted - the synthetic signal cases hit it
  about one run in four. A command that never started releases nothing.
- For the next agent: SIM-2 adds the sweep that reclaims what a `--keep-booted`
  or killed holder leaves; `scripts/ios-test-simulator.py state` and `shutdown`
  are the marker-scoped primitives it builds on. The `TRON_IOS_TEST_DEVICE_NAME`/
  `TRON_IOS_TEST_STATE_DIR` lanes on the real Mac (`ios-test-CT22`) are still
  used by the energy-efficiency session (SIM-10).

### SIM-2 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: every `scripts/tron-ios-test` command that provisions the simulator
  first releases orphaned owned lanes - owned simulators booted while no live
  process holds their `lease.lock` - and `scripts/tron-ios-test reap` runs the
  same sweep on demand, outside any lease. Discovery is the ownership markers
  under one lane root (`$TRON_IOS_TEST_DISCOVERY_ROOT`, default the parent of
  the state directory: `$HOME/.tron/internal`, then
  `$HOME/.tron/internal/ios-test` and each lane beside or inside it, two levels
  deep), never device names; each release takes that lane's lease without
  waiting and holds it for the whole bounded shutdown.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` — 40 tests,
  86-113 s wall over three runs (32 tests, 69 s at the SIM-1 commit); the eight new SIM-2 cases cover
  only-orphans, a held lane, a deleted device, a renamed identity case, the
  Development marker, a hung shutdown with recovery, two concurrent sweeps and a
  command starting mid-sweep. Real-machine check with the discovery root and
  state directory in a fresh `/tmp` lane that only this task created: a booted
  lane device with a free lease was shut down by
  `scripts/tron-ios-test reap` (`shut down Tron Lifecycle Probe (<lane>)`, exit
  0), a second `reap` printed nothing, and `xcrun simctl list --json` showed the
  Mac's other devices untouched apart from another session's own concurrent
  create/delete. The probe device was deleted; no lane under `~/.tron/internal`
  and no Development simulator was shut down, deleted or swept (their markers
  were only read).
- Changes: this commit.
- Kept on purpose: the sweep runs before provisioning for the commands that
  provision (`checkpoint`, `prepare`, `build`, `run`, `diagnose`) and for
  `reap`; `status` stays read-only (it never takes the lease) and `clean` only
  removes this worktree's lane, as their contracts say. A lane whose lease is
  free but whose simulator is booted is released by design, which is exactly
  what reclaims a `--keep-booted` lane once its loop is over.
- Deviations: the plan lists the sweep for `tron-profile-ios` and
  `ios-gateway-e2e-test` too under SIM-2's owning files; those callers are wired
  in SIM-7, and today they still lease and provision without the sweep or
  release. A dead marker (device gone) is skipped silently rather than warned
  about, because `provision` recovers it; a marker whose device identity changed
  and one that names the Development simulator are skipped with a warning.
- For the next agent: SIM-3's lanes must live under the discovery root as
  children or siblings of the default state directory for the sweep to find them;
  `marker_paths` is the one place that decides discovery depth. On the real Mac
  the pre-existing `ios-test-CT22` lane (energy-efficiency) is already
  discovered as a sibling and will be released as soon as it is orphaned.

### SIM-3 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: a lane is one state directory and one device name. `--lane NAME` (or
  `TRON_IOS_TEST_LANE`) selects `<lane root>/ios-test-NAME` holding the device
  `Tron iOS Tests (NAME)`; the default lane keeps today's directory and name.
  Every lane's marker now records the worktree that created its simulator and
  the time a command last used it. `scripts/tron-ios-test lanes` lists every
  lane - worktree, device state, lease holder, last use and simulator disk size
  - and is read-only. `scripts/tron-ios-test lane-remove NAME` deletes one
  lane's simulator and state plus the products of a worktree that no longer
  exists, refusing a lane a live process holds (73) and state with no ownership
  marker (66). The sweep every provisioning command and `reap` already runs now
  also deletes lanes no command has used for 7 days.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` - 50 tests,
  65.5-94.7 s wall over four full runs (40 tests, 86-113 s at the SIM-2 commit),
  with ten new SIM-3 cases: `LaneFixture`
  `test_lanes_lists_worktree_state_holder_last_use_and_disk`,
  `test_lanes_is_read_only_and_never_takes_a_held_lease`,
  `test_a_named_lane_refuses_the_pre_lane_overrides_and_bad_names`,
  `test_lane_removal_refuses_a_directory_outside_the_lane_root`,
  `test_lane_remove_refuses_a_held_lane_and_keeps_its_device_and_state`,
  `test_lane_remove_deletes_a_marker_owned_lane_and_keeps_marker_less_state`,
  `test_the_sweep_expires_lanes_unused_for_longer_than_the_ttl`,
  `test_a_lane_whose_holder_was_killed_is_listed_idle_and_expires`, and
  `RunnerFixture`
  `test_a_named_lane_provisions_its_own_simulator_and_records_its_use` and
  `test_lane_remove_keeps_a_live_worktrees_products_and_reclaims_a_deleted_worktrees`;
  `python3 scripts/test-tron-profile-ios.py` - 7 tests, 0.05 s. Real-machine
  check with the discovery root, state directory and Development marker inside
  one fresh `/tmp` directory and only a device this task created: `provision`
  (create+boot) 29 s and its marker recorded `worktree` plus
  `last_used_epoch_seconds`; `scripts/tron-ios-test lanes` printed the row
  `default /private/tmp/tron-sim Booted idle 2026-09-28T05:23:56Z 1.4 GB`;
  `scripts/tron-ios-test lane-remove default` removed the device and the state
  directory, kept the live worktree's products with the message naming them, and
  a second removal printed `no such lane` and exited 0; `xcrun simctl list
  --json` afterwards showed the probe device gone, the pre-existing booted
  `Tron iOS Tests` untouched, and only another session's own concurrent create
  (`Tron iOS Tests Perf CHATVIEW`) as new. The probe directory was deleted.
- Changes: this commit.
- Kept on purpose: `clean` still removes this worktree's simulator, products and
  results (SIM-5 scopes it) while `lane-remove` is the lane-scoped command;
  `lanes` never sweeps; a lane name maps to `ios-test-<name>` and the device
  `Tron iOS Tests (<name>)`, which is what the pre-existing sibling lane
  directories already look like. `TRON_IOS_TEST_STATE_DIR` and
  `TRON_IOS_TEST_DEVICE_NAME` keep working for the default lane (`--lane default`
  is the explicit way to say so), so CI and the profiler are unaffected until
  SIM-7 and SIM-10.
- Deviations: `lane-remove` keeps the products of a worktree that still exists
  instead of deleting them, because products are per worktree and shared by
  every lane of that worktree - deleting them would break the other lanes and
  the running worktree - so it reclaims products only once the recorded worktree
  is gone. A named lane *refuses* the two pre-lane overrides rather than letting
  one spelling silently win. "Never the default lane's marker-less state" is
  implemented as "the sweep is driven by ownership markers", so a lane directory
  with no marker is never removed (the default lane's exists before its first
  provision), while a *dated* marker is expired even in the default lane - the
  idle `Tron iOS Tests` device was this incident's own offender and is the disk
  this plan wants back. Expiry runs inside the existing sweep rather than as a
  new command, so it happens on every provisioning command and on `reap`, and a
  marker written before lanes recorded a last use (for example the
  energy-efficiency lane) is never expired until a command dates it.
- Risks: two lanes of one worktree still share that worktree's single products
  directory (only the simulator and lease are per lane), so concurrent lanes
  belong to different worktrees until SIM-5 scopes products; SIM-4's admission is
  also what will bound how many lanes a Mac takes on at once.
- For the next agent: `lane_rows`/`list_lanes` in `scripts/ios-test-simulator.py`
  is the one lane table - SIM-4 refusal output and SIM-6 `status --all` should
  print it rather than a second projection. SIM-5 belongs in the same sweep
  loop: `expire_lane` already takes the lease and knows the recorded worktree,
  and `clean` needs the same lane-scoped directory rules. SIM-7 should pass
  `--worktree` to `provision` from the profiler and the E2E harness so their
  lanes are attributed as well as dated. The 7-day TTL is the module constant
  `LANE_TTL_SECONDS` with no environment override; tests date markers instead of
  waiting. A lane's device is deleted through its own marker, so an expired or
  renamed lane is skipped rather than guessed at.

### SIM-4 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: a boot is admitted on the Mac's memory instead of a fixed count. Right
  before `simctl boot` - never for a lane whose simulator is already booted -
  `scripts/ios-test-simulator.py provision` reads `memory_pressure` and
  `sysctl vm.swapusage` and refuses with exit 73 and the simulator table (every
  lane with state, worktree, lease holder, uptime and disk, every booted device
  no lane owns, and `Simulator.app`) when free memory is below 8 GB or swap in
  use is at 4 GB. Both are configurable
  (`TRON_IOS_TEST_MEMORY_RESERVE_BYTES`, `TRON_IOS_TEST_SWAP_LIMIT_BYTES`), the
  refusal is fast and says when no owned lane is booted (so the shortage is not
  the test tooling's), and an unavailable reader admits the boot with a warning.
  `scripts/tron-ios-test` keeps 73 instead of mapping it to 66.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` - 56 tests, 94.7 s
  wall (50 tests, 65.5-94.7 s at the SIM-3 commit), with six new SIM-4 cases:
  `AdmissionFixture` `test_a_boot_is_refused_when_free_memory_is_below_the_reserve`,
  `test_a_boot_is_refused_when_swap_is_at_the_limit`,
  `test_the_refusal_names_the_booted_lane_its_worktree_and_uptime`,
  `test_an_unavailable_reader_admits_the_boot_with_a_warning` (missing, failing
  and unparsable readers), `test_an_already_booted_lane_is_reused_without_admission`
  and `RunnerFixture` `test_the_runner_keeps_the_admission_exit_and_boots_nothing`
  (exit 73 survives the runner, no `simctl boot` in the synthetic log, the
  created device stays Shutdown). Every fixture now installs synthetic
  `memory_pressure`, `sysctl` and `ps` readers through
  `TRON_IOS_MEMORY_PRESSURE`/`TRON_IOS_SYSCTL`/`TRON_IOS_PS`, so no test depends
  on this Mac's real memory state. No real-machine smoke check was run for this
  task: the readers were exercised on the real Mac only by reading them
  (`memory_pressure` reports 72% free, `sysctl -n vm.swapusage` 999.75M used,
  `ps -axo pid=,etime=,command=`), and nothing was booted, shut down or deleted.
- Changes: this commit.
- Kept on purpose: the reserve is checked before the boot, so a booted
  simulator's own ~2 GB footprint comes out of the reserve rather than being
  estimated; a lane created but not booted by a refused command keeps its device
  and marker, so the next command reuses that instead of creating another.
  `--default-state-dir`/`--discovery-root` are now passed to every simulator
  command by the runner, and `lane_root` degrades to the caller's own marker-plus
  booted devices when a caller (the profiler, the E2E harness, the lease holder)
  names neither, so a view that cannot see the Mac's other lanes never claims
  they are idle.
- Deviations: the refusal table is the SIM-6 view (`simulator_rows`), because the
  plan requires `status --all` to print exactly what admission prints; SIM-6 adds
  the command, the runner wiring, the docs and its own tests around it. The
  reader commands are injectable through three environment variables
  (`TRON_IOS_MEMORY_PRESSURE`, `TRON_IOS_SYSCTL`, `TRON_IOS_PS`) in the same
  shape as the existing `TRON_IOS_XCRUN`. `LANE_BUSY_EXIT` became `BUSY_EXIT`
  (same value, documented as the runner's one "not now" exit).
- For the next agent: SIM-5's `prune`/scoped `clean` belong in this same module,
  which already owns `remove_lane` and the products of a deleted worktree; SIM-6
  only has to add `simulators` to the command choices, wire `status --all`, and
  test the unowned/Development/Simulator.app rows that SIM-4 already renders.
  Uptime comes from `ps -axo pid=,etime=,command=` (macOS has no `etimes`);
  macOS `ps` in this Xcode is what proves a device's boot time, so
  `TRON_IOS_PS` is also what SIM-6's tests must fake.

### SIM-5 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: `clean` is scoped and `prune` reclaims disk. `clean` removes this
  lane's simulator, this lane's runs (attributed by a `owner.json` the runner
  writes when it creates the run directory, or by the `source.worktree` of an
  older run's `metadata.json`) and this worktree's products; the shared results
  root is never removed wholesale, and a results root without the runner's
  ownership marker is refused (66) rather than skipped. `scripts/tron-ios-test
  prune` keeps the newest 50 runs of each worktree plus everything younger than
  7 days, deletes the test products whose `build-identity.json` names a worktree
  that no longer exists, and drops a `latest` symlink whose run it pruned. Every
  sweep prunes too, so `reap` and each provisioning command reclaim disk as well
  as memory.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` - 62 tests, 92.8 s
  wall (56 tests, 94.7 s at the SIM-4 commit), with six new SIM-5 cases in
  `ReclaimFixture`: `test_clean_removes_only_this_worktrees_lane_runs_and_products`
  (this worktree's two runs and its legacy metadata-only run go, another lane's
  run, another worktree's run and its products stay, the root and its marker
  stay, a dangling `latest` goes, the lane's simulator is deleted),
  `test_prune_keeps_the_newest_50_of_a_worktree_and_anything_under_7_days`
  (51 young runs of one worktree: the 51st is beyond the newest 50 and stays; two
  8- and 9-day-old runs beyond the window go; another worktree's 30-day-old only
  run stays; a second `prune` prints nothing),
  `test_prune_deletes_the_products_of_a_deleted_worktree_only`,
  `test_prune_leaves_a_root_without_the_ownership_marker_alone` (and `reap` in
  the same state still exits 0),
  `test_clean_refuses_a_results_root_without_the_ownership_marker` and
  `test_the_sweep_prunes_so_reap_reclaims_memory_and_disk`.
  `python3 scripts/test-tron-profile-ios.py` - 7 tests, 0.05 s. No real-machine
  check: every case runs against the synthetic simctl with the lane root, results
  root and products root inside the fixture's temporary directory. Correction
  (found and fixed under SIM-6, recorded there): at this commit the sweep-level
  fixtures still inherited the Mac's real HOME, so their `reap` passed the real
  `~/Library/Developer/Tron/ios` roots to a sweep that now prunes.
- Changes: this commit.
- Kept on purpose: `lane-remove` still keeps a live worktree's products (they are
  shared by that worktree's lanes) and reclaims them only once its recorded
  worktree is gone - `prune` now performs the same reclamation for a worktree
  that has no lane left. `clean` keeps `TRON_IOS_TEST_PRESERVE_ARTIFACTS=1`
  behaviour (simulator only), which is what CI uses. Prune skips, with a warning,
  a root it cannot prove; the explicit `clean` refuses instead, because an agent
  asking for 5 GB back must not be told nothing happened.
- Deviations: the retained-run bookkeeping is a new `owner.json` inside each run
  directory (the plan's "newest results per worktree" needs an owner, and the
  runner has no index); it is additive, so the result layout is otherwise
  unchanged. Retention uses the module constants `RUNS_KEPT_PER_WORKTREE` (50)
  and `RUN_TTL_SECONDS` (7 days) with no environment override, so tests date the
  runs instead of waiting. Products of a worktree whose stamp is missing are kept
  (nothing proves the owner is gone). Pruning runs inside the sweep rather than
  as a step the runner sequences, so every existing sweep caller prunes.
- For the next agent: SIM-6's `status --all` should reuse `simulator_rows` (it is
  already the admission refusal table) and only has to add the command, wire the
  runner's `status --all`, and test the Development/unowned/Simulator.app rows -
  `TRON_IOS_PS` is the injectable process table those uptimes come from. Runs and
  products are pruned by the sweep before provisioning, so a `run` still holds
  its lane's lease while another worktree's old runs are reclaimed; nothing in
  these paths takes a second lease.

### SIM-6 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: `scripts/tron-ios-test status --all` prints one view of everything that
  holds the Mac's memory: every lane with its state, worktree, lease holder,
  uptime and disk size, every booted simulator no lane owns, the remembered
  Development simulator (named `development`, and `missing` when its device is
  gone), and `Simulator.app` whether or not it is running. It is read-only (no
  lease, no boot, no removal), and it is the exact table the admission refusal
  from SIM-4 prints, because both call the module's `simulator_rows`. Uptime is
  the age of each booted device's own boot process (`launchd_sim` for that UDID,
  `Simulator.app/Contents/MacOS/Simulator` for the GUI app), read through the
  injectable `TRON_IOS_PS`; `human_duration` renders it as `3d 4h`/`16h 5m`/`42m`.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` - 66 tests green,
  344.9 s wall at this commit and 557.1 s in the re-run after the HOME isolation
  fix below, both with the host compiling another session's worktree at the same
  time (62 tests, 92.8 s at the SIM-5 commit; the four new SIM-6 cases alone run
  in 1.7 s), with four new SIM-6 cases in
  `StatusFixture`: `test_status_all_lists_every_booted_simulator_once`
  (booted default lane with worktree and disk, a shutdown lane with a live lease
  holder named, a lane whose device is missing, the Development device, an
  unowned booted device, a shutdown unowned device that must not appear),
  `test_status_all_takes_uptime_from_the_process_table` (`1d 16h` from the boot
  process, nothing for a shutdown lane, an unreadable `ps` warns and leaves the
  cell empty rather than inventing), `test_status_all_always_shows_simulator_app`
  (`running` with its uptime, then `not running` with none) and
  `test_status_all_changes_nothing` (lane directory listing and inventory
  unchanged, no lease file created for a lane idle for 8 days, and no boot,
  shutdown, delete, erase, create or bootstatus call in the synthetic simctl
  log). Visual check of the rendered table through the synthetic simctl with a
  temp lane root (`/tmp/tron-status-probe`, deleted afterwards; no real
  simulator was read): six rows, lanes first (default, alpha, beta), then
  development, unowned, `Simulator.app`.
- Changes: this commit.
- Kept on purpose: `status --all` prints only the table, so it composes with the
  runner's other output; the plain `status` output is unchanged. Lanes are listed
  whether booted or not (a released lane must be visibly released), while unowned
  devices appear only while booted (a shutdown unowned device holds nothing).
  `--all` is rejected for every other command (74) so a mistyped `lanes --all`
  cannot look like it worked.
- Risks and deviation: this commit also isolates HOME in `OwnedLaneFixture`.
  Between the SIM-5 commit and this one the sweep-level fixtures
  (`ReleaseFixture`, `SweepFixture`) inherited this Mac's real HOME, so their
  `reap` invocations passed the real `~/Library/Developer/Tron/ios/test-runs` and
  `test-derived-data` to the sweep, which prunes. Nothing in the real results
  root could be removed (every one of its 1,834 entries is dated 2026-09-25 to
  2026-09-28, inside the 7-day window, and `latest` is the only entry without a
  date), and every marker-owned products directory there names a worktree that
  still exists (four live, one still building without a stamp). The context's
  eight dead worktrees (8.8 GB) are no longer under the products root and this
  handoff cannot prove whether an earlier session's `lane-remove` or these test
  runs reclaimed them; the roots' mtimes are explained by another session
  creating `tron-fit-2914e2163cc4` and two new runs, and the run count only grew
  (1832 to 1834). All of it is regenerable test output inside the tool's own
  roots - no simulator, lane, lease, product of a live worktree or source data
  was affected - and no fixture can reach those roots again, which is why the
  fix is here rather than in a note.
- Deviations: this commit also carries two review nits in the SIM-4/SIM-5 code -
  the runner's admission exit is a plain `if` instead of an `&&` list, and a run
  whose `owner.json` is unreadable keeps the lane it records instead of being
  forced to the default lane. The renderer (`simulator_rows`/`print_simulators`) landed in SIM-4
  because the admission refusal had to print exactly this table; SIM-6 added the
  `simulators` command, the runner's `status --all`, the docs and the four cases
  above. Uptime for the Development simulator and unowned devices comes from the
  same process table rather than from a remembered timestamp, so it needs no
  cooperation from those owners.
- For the next agent: SIM-7 wires the profiler, the E2E harness and
  `scripts/tron-ios-simulator` into these paths - they should pass
  `--discovery-root`/`--default-state-dir` (and `--lane`) so their lanes are
  named and their runs attributed, and their omission today only means their
  refusal tables see their own lane plus booted devices. SIM-9 documents
  `status --all` in the skill; `packages/ios-app/docs/development.md` already has
  the runner section.

### SIM-7 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: `scripts/tron-profile-ios`, `scripts/ios-gateway-e2e-test` and
  `scripts/tron-ios-simulator` no longer keep a lifecycle of their own. The
  profiler and the Gateway E2E harness lease the lane together with its
  ownership marker, so the holder shuts down the simulator their command booted
  when the command ends; both run the same sweep before they provision; both
  pass `--discovery-root`, `--default-state-dir` and `--worktree` to the shared
  provisioner, so their lanes are discovered, attributed, reported and
  reclaimed like any other lane; and both keep exit 73 when the shared
  provisioner refuses a boot (the Mac's memory admission, or a lane a live
  process holds) instead of reporting it as a broken destination.
  `scripts/tron-ios-simulator status` reports how long the remembered
  Development simulator has been booted - the same boot-process fact the
  `status --all` row prints, through a new `development-uptime` command on
  `scripts/ios-test-simulator.py` rather than a second uptime implementation -
  and `stop` remains the way to release it. The Development simulator is never
  shut down or deleted by the test tooling, which the new cases guard as well as
  the existing simulator-level ones.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` - 76 tests,
  213.6 s wall at the containment commit (75 tests, 173.2 s with SIM-7's own
  cases; 66 tests, 344.9-557.1 s at the SIM-6 commit), with ten new cases. The
  five that fail against the pre-change scripts: `ProfilerLifecycleFixture`
  `test_the_profiler_releases_its_lane_and_sweeps_orphans` (the lane it boots is
  released, an orphan lane in the lane root is swept, a held lane is left Booted,
  the marker records this worktree) and
  `test_a_profiler_boot_the_mac_refuses_keeps_the_shared_exit` (73 survives, no
  `boot` in the synthetic simctl log), `GatewayE2EFixture`
  `test_an_e2e_build_releases_its_lane_and_sweeps_orphans` and
  `test_an_e2e_build_the_mac_refuses_keeps_the_shared_exit` (73 instead of 1, and
  nothing built), and `DevelopmentSimulatorFixture`
  `test_status_reports_how_long_the_remembered_simulator_has_been_booted`
  (`1d 4h` from the boot process, `unknown` when the table is unreadable, and
  `not booted` for a shutdown device). The four contract guards pass before and
  after by design: `test_a_killed_e2e_build_leaves_its_lane_to_the_next_sweep`
  (a command killed while it holds the lane leaves it booted and
  `scripts/tron-ios-test reap` reclaims it), the Development simulator's
  `stop`-touches-only-the-remembered-simulator case, and the two cases where the
  sweep, `clean`, `lane-remove` and the E2E `clean` refuse a lane whose marker
  names the remembered Development simulator. `python3
  scripts/test-tron-profile-ios.py` - 7 tests, 0.001 s; `python3
  scripts/test-tron-profile.py` - 10 tests, 36.4 s;
  `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass. Real-machine read-only check:
  `scripts/ios-test-simulator.py development-uptime` against a marker in a fresh
  `/tmp/tron-sim7-probe` directory naming another session's booted lane device
  printed `1h 38m`, matching that device's own boot process (`65790 01:38:53
  launchd_sim .../6B59E412-79C4-430C-8885-24C05956DD82`);
  `TRON_IOS_SIMULATOR_STATE_DIR=/tmp/tron-sim7-probe scripts/tron-ios-simulator
  status` printed the same uptime, and `scripts/tron-ios-test status --all` with
  its lane root inside that directory listed the Development simulator and the
  booted devices read-only. Nothing was booted, shut down, deleted or swept:
  every state and discovery root in the probe was inside the probe directory,
  which was deleted afterwards, and `~/.tron/internal/run/ios-simulator-udid`
  kept its 2026-09-25 mtime. No real boot/release check of a profiler or E2E
  lane: their lifecycle is the shared provisioner, lease and sweep already
  verified against real simulators in SIM-1, SIM-2 and SIM-4, and a real
  create+boot would add device churn (3-14 GB) while other sessions test.
- Changes: `b9c11e9d0` and this commit.
- Kept on purpose: the profiler and the E2E harness still select their lane with
  the pre-lane `TRON_IOS_TEST_STATE_DIR`/`TRON_IOS_TEST_DEVICE_NAME` spellings
  (SIM-10 replaces them with lanes for every caller); the profiler's sweep
  reclaims lanes only and prunes no results or products, because the runner's
  roots are not the profiler's; `scripts/tron-ios-simulator start` still boots
  the user's paired Development simulator without the memory admission, since
  this task scoped that helper to reporting uptime and never being deleted;
  `--keep-booted` was not added to the profiler or the E2E harness, where one
  boot per command already serves a scenario set or a boundary run.
- Deviations: the E2E harness reports a refused boot as 73 (was 1) and the
  profiler as 73 (was 66), which is what "the same admission path" means to a
  caller that decides whether to wait; `development-uptime` is a new read-only
  command on the shared module rather than a second uptime reader in
  `scripts/tron-ios-simulator`; the plan's "`status --all` flags it when booted
  with no app interaction for a bounded time" is implemented as the real uptime
  (the UPTIME column, and the line `status` prints) because the Mac records no
  app-interaction signal, and no idle threshold was invented. This commit also
  contains the containment guard the SIM-6 correction below describes.
- Risks: the E2E harness now applies memory admission on CI too. The runner
  already did, so this is not new evidence of a CI regression, but no GitHub
  runner was observed from here; `TRON_IOS_TEST_MEMORY_RESERVE_BYTES` tunes it if
  a runner is tight.
- For the next agent: SIM-8 (Gateway memory diagnostics) runs on its own branch;
  SIM-9 owns the skills and the remaining documentation. Every fixture in
  `scripts/test-ios-test-infrastructure.py` now inherits `ContainedFixture`, so a
  fixture that lets HOME or a Tron root fall outside its temporary directory
  fails immediately with the escaping variable named instead of mutating this
  Mac's state; keep new fixtures on `contained_environment`/`run_script`.

### SIM-6 correction · 2026-09-28 · chat scroll session (worker lanes)

- Corrects: the SIM-6 handoff entry above, in its "Risks and deviation"
  paragraph about the real results and products roots.
- Result: the eight dead worktrees' 8.8 GB of test products were deleted
  manually by the supervisor at about 20:40 local on 2026-09-28, before these
  test runs. The products of the deleted `tron-perf-follow` and
  `tron-perf-reveal` worktrees are gone and may have been reclaimed by those
  leaked test `reap`s, which is the intended prune behaviour for the products of
  a worktree that no longer exists. Nothing else in that paragraph changes:
  every fixture root, the live worktrees' products, and every lane, lease and
  simulator were untouched.
- Evidence: the supervisor's account, recorded here. The guard added by SIM-7
  (`ContainedFixture` and its negative control in
  `scripts/test-ios-test-infrastructure.py`) makes any fixture that inherited a
  real HOME or Tron root fail immediately, so the leak cannot recur.
- Changes: this commit.
- For the next agent: run the infrastructure suite after touching any fixture
  environment; a leaked root now fails with the escaping variable named.

### SIM-9 · Done · 2026-09-28 · chat scroll session (worker lanes)

- Result: the four docs now describe the lifecycle the tooling owns instead of
  asking agents to remember it. `AGENTS.md`'s process-cleanup section says the
  test tooling releases the simulator a command boots, that each provisioning
  command sweeps orphans and expires lanes unused for 7 days (the runner's sweep
  prunes old runs and products too), that a refused boot exits 73 with the
  `status --all` table, and that an agent runs that table before its final
  response; `scripts/tron-ios-test`'s usage says the same for `status --all` and
  spells out that `--keep-booted` is a provisioning-command option.
  `.agents/skills/tron-ios/SKILL.md` gains a **Simulator lifecycle** section
  (lanes, release, sweep, admission, `status --all`, `lanes`, `lane-remove`,
  `clean`/`prune`, the Development simulator) plus a link from the lease
  paragraph and two new stop rules (never release another owner's simulator by
  hand; never force a boot past 73).
  `.agents/skills/tron-workspace-housekeeping/SKILL.md` no longer treats a
  worktree's simulator, runs and products as something a housekeeper cleans by
  hand: a new **iOS simulator lanes, runs and products** section owns that
  guidance, step 4's "run the build cleaners" item points at it, and step 5 asks
  for `lanes`/`status --all` after a removal. The rules that still apply stay:
  stop only what you started, never a process/lane/lease another session holds,
  the Gateway and its agent children are never yours to stop, and the Gateway
  lifecycle is untouched by housekeeping.
- Evidence: all eight script suites green, 194 tests, in a first pass after the
  edits and again against the committed tree:
  `python3 scripts/test-ios-test-infrastructure.py` 76 tests / 302 s then
  76 / 228 s (76 / 213.6 s at the SIM-7 commit; the earlier runs shared the Mac
  with other sessions),
  `test-tron-profile.py` 10 / 48 s, `test-mac-reinstall.py` 69 / 9 s,
  `test-personal-info-guard.py` 9 / 10 s, `test-native-host.py` 11 / 0.4 s,
  `test-tron-profile-attribution.py` 9 / 0.03 s, `test-tron-profile-ios.py`
  7 / 0.001 s, `test-gateway-protocol-contract.py` 3 / 0.02 s.
  `python3 scripts/check-documentation-policy.py` passed (46 authored files, so
  every new link and heading anchor resolves) and `scripts/personal-info-guard.sh`
  is clean. Read-only real-machine check with the lane root and state directory
  inside a fresh `/tmp/tron-sim9-probe`: `scripts/tron-ios-test status --all`
  rendered the documented table (one `not-provisioned`/idle lane row, the
  remembered Development device as Shutdown, two booted devices of other
  sessions as `unowned`, `Simulator.app not running`) and `lanes` rendered the
  single default row; the probe directory was empty afterwards, so nothing was
  written, leased, booted, shut down or deleted, and the probe root is why those
  booted devices appeared as unowned instead of as the lanes the default root
  would name. Only `xcrun simctl list`, `ps`, `memory_pressure` and `sysctl`
  reads happened, and the probe directory was deleted.
- Changes: this commit.
- Kept on purpose: `packages/ios-app/docs/development.md` already described
  lanes, release, the sweep, admission, `clean`/`prune` and `status --all` from
  SIM-1 to SIM-7, so this task changed only the sentence that left the
  `status --all` guidance ambiguous rather than rewriting the sections; the
  command list there already names `status --all`, `lanes`, `lane-remove`,
  `reap`, `prune` and `clean`. AGENTS.md keeps its shape - the human rules (own
  only what you started, broad kills forbidden, Gateway untouchable) stay and
  only the manual simulator shutdown is replaced - and grew by eight lines. The
  housekeeping skill keeps Git as its subject: it invokes the test tooling
  rather than reimplementing lane removal, and it still refuses to stop agents,
  suspend processes or transition the Gateway.
- Deviations: the plan's SIM-9 scope names four docs; the task also named
  `scripts/tron-ios-test`'s usage text, so its two agent-facing lines (`status
  --all`, `--keep-booted`) were corrected there in the same commit. No behaviour
  changed and no test was added or updated: the change is documentation, and
  test-only assertions on documentation text are what the testing policy
  forbids. `TRON_IOS_TEST_STATE_DIR` and `TRON_IOS_TEST_DEVICE_NAME` are still
  described as naming the default lane, because SIM-10 removes them, not this
  task.
- For the next agent: SIM-10 (Ready) removes the two pre-lane overrides in favour
  of lanes; its callers are `scripts/ios-ci-test.sh`, `scripts/tron-profile-ios`,
  `scripts/ios-gateway-e2e-test`, the lane bullets in
  `.agents/skills/tron-ios/SKILL.md` and the two paragraphs in `development.md`
  that name them, and its dependency is the energy-efficiency plan's profiling
  lanes. SIM-8 runs on its own branch. Closing this plan then means moving the
  lasting rules (release, sweep, admission, "never touch another owner's lane")
  into the owning docs, appending a HISTORY.md entry and deleting the plan file.

### Review fixes · 2026-09-28 · chat scroll session (worker lanes)

- Result: the review findings P1-1, P1-2, P2-1 to P2-6 are fixed on this branch,
  each with the failure mode written first and each new test verified against the
  pre-fix code.
  - **P1-1** `scripts/tron-profile-ios` started the lease holder with
    `subprocess.run`, so a SIGINT made CPython SIGKILL the holder and the lane's
    simulator was never released. It now `os.execv`s into the holder, as the bash
    callers `exec` it: the run's own process is the holder, so the signal reaches
    the holder, which forwards it and releases afterwards.
  - **P1-2** `scripts/ios-test-lock.py` forwarded a signal only to its direct
    child: the shell died at once while the process owner below it and the
    xcodebuild that owner runs in its own session kept going, and the holder
    released the simulator under a live test. The holder now starts the command
    in its own process group, forwards SIGINT/SIGTERM/SIGHUP to that group, and
    waits (bounded, 30 s) for the group to be empty before releasing; a tree that
    outlives the bound is reported instead of silently outliving the lease.
  - **P2-1** the holder passes the lease's own descriptor to the command
    (`pass_fds`, its number in `TRON_IOS_TEST_LEASE_FD`), so the flock lives
    exactly as long as the command tree: a holder killed with SIGKILL leaves a
    lane whose lease the sweep skips while the orphaned command runs, and
    reclaims once it has exited. A process a command *detaches* is not part of
    that tree, so `scripts/ios-gateway-e2e-test` now starts the Gateway fixture
    and fault proxy through a `detach` helper that closes the descriptor and
    keeps `$!` the detached process's own pid; without it the lane would stay
    leased for as long as that Gateway runs and the harness's next command
    would fail 73.
  - **P2-2** `lease_holder` no longer takes each lane's exclusive lease to probe
    it (a `lanes` or `status --all` pass could make a command starting at that
    moment fail 73). It reads the pid and start second the holder records and
    proves them against the process table, and the holder writes its own identity
    before it probes the simulator, so the record is readable as soon as the
    lease is held. A caller that already failed to lock a lane still gets a
    description of it.
  - **P2-3** `remove_lane` refuses a directory that contains another lane's
    ownership marker (removing it would take that lane's state with it), and
    `expire_lane` catches `OSError` as well as `DestinationError`, so a removal
    that races the file system is reported and the sweep carries on.
  - **P2-4** boots are serialized across every lane on one machine-wide admission
    lock in the lane root, held from the memory read until `bootstatus` returns,
    so concurrent starts see the previous boot; a boot that cannot take it in
    `--admission-wait-seconds` (300, `TRON_IOS_TEST_ADMISSION_WAIT_SECONDS`) is
    refused with the shared 73 and table. Admission gates on free memory only:
    `SWAP_LIMIT_BYTES`, `--swap-limit-bytes` and `TRON_IOS_TEST_SWAP_LIMIT_BYTES`
    are gone, and swap in use is printed in the table header (with free memory)
    instead of refusing boots persistently.
  - **P2-5** docs corrected: `development.md` no longer claims lanes serialize
    against each other (each lane owns its lease and simulator; lanes of one
    worktree share its products directory, so build one lane at a time), and
    "never deletes any simulator it owns" now says the shared Development
    simulator is never deleted while the tooling's own marked simulators are
    deleted by `clean`, `lane-remove` and the sweep (`scripts/tron-ios-simulator`
    usage and `development.md`).
  - **P2-6** the containment guard is structural: every process the test module
    starts goes through one launcher that refuses an environment whose HOME or
    Tron roots fall outside the fixture's temporary directory, and the module's
    `subprocess` name is that launcher, so a call site cannot bypass it. A new
    negative control covers the disk-only `prune` path, which starts no synthetic
    tool at all. The double-negative `assertFalse((...).exists() is False)` in
    `ReclaimFixture` is now `assertTrue(...exists())`.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py` — 86 tests, 201 s
  wall on the committed tree (228 s in the first full run, while other sessions
  shared the Mac; 76 tests at the SIM-9 commit). The nine cases for the source
  findings were run with the fixed sources stashed and failed for their own
  failure mode: the profiler died with `KeyboardInterrupt` inside
  `subprocess.run` (status -2) and left the lane booted; the chain's release
  probe reported `released-while-the-command-tree-lived`; the sweep shut down a
  simulator a surviving orphan command still held; `lanes` reported a lane
  `idle` while its recorded holder was live and the view took the lease;
  `lane-remove` deleted a directory holding another lane's marker; a blocked
  lane crashed the sweep with `PermissionError`; both concurrent boots were
  admitted; the untakeable admission lock was ignored; and 4.9 GB of swap
  refused a boot. The tenth case is the launcher's own negative control, which
  fails whenever a leaking environment reaches a process at all, and the second
  control covers the disk-only `prune` path that the tools' own guard cannot see.
  `python3 scripts/test-tron-profile-ios.py` 7 tests pass and
  `python3 scripts/check-documentation-policy.py` passes (46 authored files).
- Deviations and notes: three fixture cases were adjusted because the fixes
  changed the observable edges they relied on - the signalled-holder case now
  waits for the command itself instead of the lease file (the holder records its
  identity before it probes the simulator), the lane-expiry case waits for the
  killed holder's command to exit before it asserts a stale lease is idle, and
  the SIGKILL case waits for the orphan command to start before it kills the
  holder. The test module keeps the synthetic tools' own guard and its log
  alongside the new launcher, so a script under test that hands an escaping
  environment on to a tool is still refused where the fixture cannot see it.
  `scripts/ios-gateway-e2e-test`'s own signal trap was left as it is: the holder
  now signals and waits for the whole tree, which covers that harness too, and
  changing its trap would widen this task beyond its findings. Its `detach`
  helper is the one production change P2-1 needed outside the holder, and it is
  verified by reading the harness's own function back with a real descriptor:
  the detached child's `/dev/fd` has neither the lease nor a stale number, the
  caller still holds the lease while it runs, and `$!` is the child's pid. No
  Gateway, simulator or device state outside the synthetic fixtures was touched.
