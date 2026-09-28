# Simulator lifecycle

- **Started:** 2026-09-27
- **Status:** Active
- **Last updated:** 2026-09-28, SIM-4 done; SIM-5 to SIM-9 claimed
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
| SIM-5 | Claimed | Scoped clean and pruning: `clean` removes only this worktree's or lane's simulator, products and runs; `prune` keeps the newest results per worktree and deletes products whose worktree no longer exists; the sweep prunes too | SIM-3 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-6 | Claimed | One view: `scripts/tron-ios-test status --all` lists every booted simulator (owned lanes, the Development simulator, unowned ones), its owner, lease holder and uptime, plus `Simulator.app` | SIM-3 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-7 | Claimed | Same lifecycle everywhere: `scripts/tron-profile-ios`, `scripts/ios-gateway-e2e-test` and `scripts/tron-ios-simulator` use the lane, release, sweep and admission paths; the Development simulator reports idle uptime and is shut down by its `stop` | SIM-1, SIM-2, SIM-4 | chat scroll session (worker lanes), 2026-09-27 |
| SIM-8 | Claimed | Diagnosable disconnects: the Gateway records the Mac's memory pressure and swap in its diagnostics when phone connections drop and reconnect, with a row in `packages/gateway/docs/observability.md` and a test | none | chat scroll session (worker lanes), 2026-09-27 |
| SIM-9 | Claimed | Docs and guidance: `packages/ios-app/docs/development.md`, `.agents/skills/tron-ios/SKILL.md`, `.agents/skills/tron-workspace-housekeeping/SKILL.md` and `AGENTS.md` describe lanes, release, sweep and admission, and replace the manual cleanup steps the tooling now owns | SIM-1 to SIM-7 | chat scroll session (worker lanes), 2026-09-27 |
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
