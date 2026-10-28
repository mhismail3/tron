# DRAFT — frozen git inventory

Lexical inventories, not failure counts. Run from the repository. No tests were executed. The broad family/pathspec terminology in the report refers to these exact globs.

## Inventory 1 — 1719 commits

`git log 47e1b26a24b29e020e57405513b592edfca4b9ae --since=2026-10-18T00:00:00Z --until=2026-10-28T18:07:08Z --format=%H`

Count empty lines out; deduplicate paths for inventory3. Git default history traversal counts merge commits.

## Inventory 2 — 589 commits

`git log 47e1b26a24b29e020e57405513b592edfca4b9ae --since=2026-10-18T00:00:00Z --until=2026-10-28T18:07:08Z --format=%H -- 'packages/**/test*' 'packages/**/Tests/**' 'packages/**/UITests/**' 'packages/**/E2ETests/**' 'scripts/test-*' 'scripts/test_*' 'tools/**/test*' 'tools/**/tests/**' 'test-results/**'`

Count empty lines out; deduplicate paths for inventory3. Git default history traversal counts merge commits.

## Inventory 3 — 234 distinct paths

`git log 47e1b26a24b29e020e57405513b592edfca4b9ae --since=2026-10-18T00:00:00Z --until=2026-10-28T18:07:08Z --name-only --format= -- '*fixture*' '*Fixture*' '*golden*' '*Goldens/**' 'packages/gateway/test-fixtures/**'`

Count empty lines out; deduplicate paths for inventory3. Git default history traversal counts merge commits.

## Inventory 4 — 138 commits

`git log 47e1b26a24b29e020e57405513b592edfca4b9ae --since=2026-10-18T00:00:00Z --until=2026-10-28T18:07:08Z --format='%h %cI %s' -- '*golden*' '*Goldens*' '*baseline*' '*Baseline*'`

```text
b24ed6f49 2026-10-27T18:53:48-07:00 test(ios): re-record Session Settings lock goldens for untitled card and footer caption (#2075)
918fb2796 2026-10-27T17:11:46-07:00 test(ios): approve Session visuals and value-last pixel oracle
33f7a3113 2026-10-27T13:31:36-07:00 test(ios): record approved in-chat approval chip goldens (#2070)
99a69ce97 2026-10-27T12:23:04-07:00 test: record the approval tools' wait parameter in the run, session, home, transport and automation locks (#2050, maintainer-approved)
68a3c089f 2026-10-27T12:21:25-07:00 test(protocol): record the approval tools' wait parameter in the wire lock (#2050, maintainer-approved)
c99923b59 2026-10-27T10:03:53-07:00 test(gateway): align approved settings approval trace metadata
c5742f94f 2026-10-27T07:43:53-07:00 test(ios): adopt approved settled chat and tool sheet locks (#2003)
c881f8d07 2026-10-27T00:20:49-07:00 refactor: share canonical receipt field rules below Run (#2058)
3848f0799 2026-10-26T23:42:57-07:00 test(ios): adopt approved Home Settings hierarchy (#2004)
284101884 2026-10-26T17:48:58-07:00 refactor: remove Home dependency on Transport implementation types (#2049)
dbc863666 2026-10-26T16:37:23-07:00 refactor: give Automation identity codecs their lower owner (#2025)
49fb01de0 2026-10-26T16:25:31-07:00 test: align owned-run settings descriptions with blocking approvals (#2042)
0f9f864c3 2026-10-26T14:44:36-07:00 test(profile): apply exact approved lifecycle and oracle patch
4d5c74ae5 2026-10-26T14:44:35-07:00 test(profile): apply exact approved hierarchy oracle edits
8bc58c179 2026-10-26T13:58:13-07:00 test: repair approved stale Gateway contracts and iOS selectors
9cf526457 2026-10-26T09:45:22-07:00 test: repair five waived locks with stable wire capture (#2028)
1b6e9d6b6 2026-10-26T00:14:42-07:00 test(home): record approved projects tool contract in scenario lock
85f9394e3 2026-10-25T23:40:09-07:00 refactor(gateway): own shared tailnet probes in platform (#2008)
d1ba11a23 2026-10-25T20:39:21-07:00 test(home): accept approved profile and settings lock deltas
84f9c914e 2026-10-25T17:41:21-07:00 fix(settings): preserve outcome selection and fence action execution/expiry (#1642, checkpoint)
747a0da63 2026-10-25T17:41:21-07:00 feat(settings): requesters hear every approval outcome; request hold, expiry timer, maintainer-only decide, one key id rule (#1642)
26c337147 2026-10-25T15:20:47-07:00 test: record ten approved routine-editor exposure lock deltas
9e07a0445 2026-10-25T13:11:34-07:00 test(chat): record approved upstream-error metadata in wire locks
76c94c873 2026-10-25T11:44:59-07:00 refactor(kernel): use K3 ModuleLog for managed subagents
f222d86c7 2026-10-25T02:28:33-07:00 refactor: keep profile audit formatting with settings presentation
201442ccc 2026-10-25T02:10:00-07:00 refactor: consume workspace root operations without concrete knowledge coupling
e109a873e 2026-10-25T01:49:38-07:00 refactor: remove automation transport type reach-ins
99134fff0 2026-10-25T00:03:04-07:00 refactor: own qualified Jev metadata with provider pricing
931b3ee5b 2026-10-24T23:47:01-07:00 refactor: give connections a pure shared contract
d994d0eb9 2026-10-24T23:16:31-07:00 refactor: give display wire values a pure lower owner
922b50416 2026-10-24T23:06:36-07:00 refactor(kernel): own worker control contracts in delegation
20138ac28 2026-10-24T22:35:16-07:00 test: adopt approved protocol web-search schema baseline
5fa570d3e 2026-10-24T22:18:00-07:00 refactor: separate generic registration ownership from product admission
ebb05dffa 2026-10-24T21:41:55-07:00 refactor: K1 owns canonical readers and K4 owns prompt bounds
02e439166 2026-10-24T21:21:02-07:00 refactor: native resource lifetime and context use module owners
fa659b257 2026-10-24T21:07:17-07:00 refactor: notify module owns session rekey and read cuts
495696825 2026-10-24T20:59:15-07:00 refactor: remove Registry Knowledge service bridge
4a41c250e 2026-10-24T20:50:02-07:00 refactor(host): relocate generic extension presentation into K3
77bd82f2c 2026-10-24T17:03:44-07:00 chore(layers): retire fixed Run Admin dependency pair (#1937)
8244d1e04 2026-10-24T14:57:38-07:00 test(web): adopt approved contracts and prove retained child reload (#1927)
3aca1c132 2026-10-24T11:53:06-07:00 test(ios): refresh approved P4 captures for merged Settings layout (#1805)
a0f05659c 2026-10-24T11:53:06-07:00 test(ios): adopt approved P4 UI baseline (#1805)
497a5dab5 2026-10-24T02:19:45-07:00 refactor: give display its resource admission and lifecycle owner
5439ad450 2026-10-24T00:43:50-07:00 refactor(gateway): compose Home model policies outside session owners
89afbd81a 2026-10-24T00:13:15-07:00 chore(settings): tighten two approved resolved layer violations
42dba4180 2026-10-23T02:45:37-07:00 chore(layers): remove retired extension-to-display exception (#1736)
6621f2831 2026-10-23T00:01:13-07:00 move(gateway): Home sources and locks to modules/home (#1721)
eae402569 2026-10-22T20:21:35-07:00 chore(gateway): tighten the layer baseline after #1707 (-2 pairs)
c3fdf5dbf 2026-10-22T20:10:23-07:00 chore(gateway): tighten the layer baseline after #1706 (-4 pairs)
26b709d34 2026-10-22T20:06:29-07:00 simplify(gateway): composition passes connections and schedule operations to modules, not through the registry (#1705)
f342d3a1d 2026-10-22T12:50:10-07:00 refactor(delegation): move delegation files and generic task report/checkin/worker extension into kernel/delegation (#1692)
fd5835093 2026-10-22T11:01:57-07:00 tooling(layers): undeclared pairs are reported only and edges into L0/L1 are allowed; baselines keep upward and two-way pairs (#1687)
099e3ae03 2026-10-22T10:15:46-07:00 test(ios): sub-sheet titles equal their rows, rows and titles in the sheet theme, Instructions summaries on the title line; re-record settings-session lock (#1680)
0b769e817 2026-10-22T09:26:18-07:00 test(delegation): align settings schema golden with #1634 (#1662)
a61cb490b 2026-10-21T22:06:31-07:00 settings: Home fixtures drop retired record model; shared row identity; Changes via Global (#1634)
3df36400b 2026-10-21T21:23:30-07:00 settings: Project > Session/Home > Global checkpoint (#1634)
dec6680c6 2026-10-21T11:17:39-07:00 refactor(run): move compaction policy and SDK contract to run
89b9874bc 2026-10-21T10:46:23-07:00 test(ios): restore ten approved pre-removal sheet blur goldens (#1631)
40230e004 2026-10-21T08:06:06-07:00 test(gateway): record project-root-trust golden after settings regrouping (#1626)
71cdd223d 2026-10-21T06:46:37-07:00 test(ios): checkpoint candidate sheet-backdrop goldens for maintainer review
71759d412 2026-10-21T06:34:17-07:00 test(settings): checkpoint requested section goldens pending approval
e421113f6 2026-10-21T01:10:43-07:00 refactor(run): move receipts markers and drain work tokens into kernel (#1603)
c8555c228 2026-10-20T23:37:45-07:00 test(notifications): pin the slow-link idle rebaseline schedule (#1596)
e28069419 2026-10-20T22:42:43-07:00 refactor(projection): move canonical origin classification to its owner (#1591)
d2f064e4f 2026-10-20T22:15:33-07:00 refactor(projection): move projection owner into kernel (#1589)
27539324d 2026-10-20T20:19:36-07:00 refactor(gateway): finish descriptor composition and remove legacy module host (#1584)
fa86e848f 2026-10-20T19:36:47-07:00 refactor(host): describe settings through its session port (#1581)
0ac0cb8c5 2026-10-20T18:59:24-07:00 refactor(host): tighten kernel descriptor composition dependencies (#1580)
dcadede9e 2026-10-20T18:51:50-07:00 refactor(host): tighten descriptor composition layer ratchet (#1579)
35d77b369 2026-10-20T16:42:08-07:00 lock(gateway/session-catalog): catalog index: activity time per entry shape, and a candidate reconcile can no longer read (#1560)
10572439a 2026-10-20T16:42:08-07:00 lock(gateway/session-catalog): catalog index append accumulates every entry kind's metadata (#1560)
b37408276 2026-10-20T16:42:08-07:00 lock(gateway/session-catalog): blob store: a file blob whose directory became a file, and content that cannot register while its removal runs (#1560)
2c76a3f29 2026-10-20T16:42:08-07:00 test(locks): blob-store steps join prune's detached cleanup through a lease release or disposal; aliases keep the value's shape (#1560 review)
4d4e48f22 2026-10-20T16:42:08-07:00 lock(gateway/session-catalog): blob store: a twice-released lease and a missing or looped file blob (#1560)
537181856 2026-10-20T16:42:08-07:00 lock(gateway/session-catalog): catalog metadata index paths: stamp, save, append, reconcile, admission; store-path-lock aliases host file identities (#1560)
c40e03c21 2026-10-20T16:42:07-07:00 lock(gateway/session-catalog): blob store paths: limits, register, lease ranges, bounds, prune and dispose (#1560)
ddcbe195b 2026-10-20T15:43:56-07:00 test(ios/locks): settings-home goldens carry the approved Connected Services summary (#1558)
0a0e91266 2026-10-20T15:31:39-07:00 lock(gateway/home): home-contention-restart records the non-terminal task at the shutdown boundary and blinds the internal error message; docs rows (#1556)
2c0c979a2 2026-10-20T15:31:39-07:00 lock(gateway/home): home-contention-restart: busy contenders, a refused ledger write, task recovery and wake after a restart; harness same-root restart and production package/hook owners (#1556)
332a2e9c7 2026-10-20T15:31:39-07:00 lock(gateway/session-catalog): project-root-resources: packages.list and hooks.list resolve a subdirectory to its project root (#1556)
92d211ff2 2026-10-20T15:11:07-07:00 lock(gateway/notifications): waiting, queued-restart and queued-cancel push scenario locks (#1555)
939d6fd42 2026-10-20T14:49:12-07:00 lock(gateway/episodic): the episodic store records reproducibly; the harness names host-assigned cursor values (#1563)
1b4749591 2026-10-20T14:43:43-07:00 lock(gateway/run): run-eviction-choice makes an open session the least recently used, so the subscriber check decides (#1554)
45bae19b6 2026-10-20T14:43:42-07:00 lock(gateway/run): queue control, lifecycle RPCs, eviction choice and drain blocker scenario locks (#1554)
68ca9d930 2026-10-20T14:38:45-07:00 lock(gateway/transport): command-receipt races: a lane outlives one holder, a prune or rebuild inside a replaying duplicate's lane (#1557)
fda757d1c 2026-10-20T12:06:09-07:00 simplify(gateway/apps): apps is the first module descriptor (#1545)
5e6edfdcf 2026-10-20T11:08:15-07:00 move(gateway/apps): src/apps to src/modules/apps (#1543)
3509d8df6 2026-10-20T10:17:15-07:00 lock(gateway/session-catalog): record root compaction budgets and trust revocation reload in project-root-trust (#1538)
5d6084775 2026-10-20T10:17:15-07:00 lock(gateway/session-catalog): drop timing-dependent tool progress frames from project-root-trust (#1538)
fd9a20d68 2026-10-20T10:17:15-07:00 lock(gateway/session-catalog): projectDir subdirectory session with trust scenario lock (#1538)
e016eea65 2026-10-20T10:13:15-07:00 lock(gateway/run): record that an open session is never reclaimed in run-cold-load-eviction (#1537)
aafb6122d 2026-10-20T10:13:15-07:00 lock(gateway/run): record the drain's begin snapshot in run-drain-snapshot (#1537)
2d45d81a0 2026-10-20T10:13:15-07:00 lock(gateway/run): cold load, eviction and drain snapshot scenario locks (#1537)
833dc3cc7 2026-10-20T10:04:56-07:00 lock: home-activation-wake runs the production push owner: Home's notify tool and its finished pushes (#1536)
72af1236e 2026-10-20T10:04:56-07:00 lock: home-activation-wake records each request's stream options (#1536)
6992a99d2 2026-10-20T10:04:56-07:00 lock: home-activation-wake records each runtime's loaded extensions and tool schema digests (#1536)
ffda88262 2026-10-20T10:04:55-07:00 lock: home-activation-wake drops snapshot-stated topics, records a settled reopen snapshot (#1536)
803b7288c 2026-10-20T10:04:55-07:00 lock: home-activation-wake records context section names; blinds path-derived token counts (#1536)
9c2dfcf85 2026-10-20T10:04:55-07:00 lock: home-activation-wake blinds duration-dependent sizes and path-derived token counts (#1536)
107ee83f5 2026-10-20T10:04:55-07:00 lock: gateway/home scenario lock home-activation-wake: designation, first runtime, delegating activation, worker report, wake (#1536)
943c6ff8d 2026-10-20T09:53:47-07:00 test(gateway): lock an automation's owned run end to end (#1540)
4f1de45dd 2026-10-20T09:49:26-07:00 test(gateway): lock terminal and input-required pushes at the relay boundary (#1539)
89b52d15e 2026-10-20T02:44:32-07:00 doc(ios): condense swift-apps, knowledge-sources and performance-baseline docs (#1533)
08a227fca 2026-10-20T01:16:59-07:00 test(ios): re-record settings-home UI lock goldens for #1521
cdffca3c6 2026-10-19T20:34:42-07:00 test(locks): review notes: relabel the approvals rewrite step, fail a published invalid Home record, setup and restores outside refusal steps (#1493 review)
d20a772b2 2026-10-19T20:34:42-07:00 test(locks): run-markers lock pins lane serialization for a write arriving behind a queued one (#1493)
f58ceddff 2026-10-19T20:34:42-07:00 test(locks): workspace-state markers mutation-path lock (#1493)
ee05d52d4 2026-10-19T20:34:42-07:00 test(locks): home-task store mutation-path lock (#1493)
62f1b18df 2026-10-19T20:34:41-07:00 test(locks): run-markers mutation-path lock (#1493)
d451b051a 2026-10-19T20:34:41-07:00 test(locks): settings-approvals mutation-path lock; counted randomUUID shared with corpus recording (#1493)
bd9d1e810 2026-10-19T19:05:17-07:00 tooling(layers): ratchet module pairs and unindexed files, not file-edge counts (#1489)
4ec25353f 2026-10-19T18:54:21-07:00 test(locks): a receipt naming another method or identity is refused by status and execution (#1484)
68484976b 2026-10-19T18:54:05-07:00 test(locks): the model-queue lock reads a child's projection exactly at each skip's expiry (#1484)
ca6832d1b 2026-10-19T18:54:05-07:00 test(locks): command receipts pin bounds, rebuilds inside pending and completed write windows, and the early prompt lane (#1484)
7d395a72a 2026-10-19T18:54:05-07:00 test(locks): session-search, model-queue and release-date store locks; settings and new stores re-record byte for byte (#1484)
987b53218 2026-10-19T18:16:49-07:00 chore(ios): re-record the iOS reference baseline once at main's counts, maintainer-approved (#1483)
cc77f7b35 2026-10-19T15:29:12-07:00 test(locks): live store files are ordered by their normalized entry, not by generated ids (#1472)
62fc8bfb3 2026-10-19T15:26:51-07:00 test(locks): store locks for settings floors and approvals, Home designation and learned profile, episodic memory and display artifacts; corpus re-records named stores only (#1472)
5d3a0c8c2 2026-10-19T15:26:51-07:00 test(locks): command receipt lock pins the duplicate fence across a prune during completion (#1472)
9cffc79c3 2026-10-19T15:26:50-07:00 test(locks): mutation-path locks pin admission shapes, receipt bindings, aggregate bytes and failed writes (#1472)
b97cd5db0 2026-10-19T15:26:50-07:00 test(locks): mutation-path locks for the session attention, session archive and command receipt stores (#1472)
abd252a48 2026-10-19T12:59:54-07:00 test: UI-lock PNG goldens in Git LFS, recorded on main (#1466)
334ac906b 2026-10-19T12:51:33-07:00 lock: queued steers and follow-ups are admission-window state; pruned from event shapes like pendingPrompt (#1465)
8ccbc1ba9 2026-10-19T12:51:33-07:00 lock: the devices store renews its ten-minute pairing invitation on open; exclude only that file from the no-write check (#1465)
ad8509657 2026-10-19T12:51:33-07:00 lock: corpus manifest keeps empty directories Git drops; corpus re-recorded (#1465)
2961d4913 2026-10-19T12:51:33-07:00 lock: contextUsage is a checkout-derived estimate; compare its structure only (#1465)
c244eed89 2026-10-19T12:51:33-07:00 lock: prune admission-window transients (pendingPrompt, activeToolSegmentId, pre-persistence context notice) from event shapes; goldens lose only those paths (#1465)
2d354b24e 2026-10-19T12:51:33-07:00 lock: protocol-8 wire contract lock from real frames (gateway/protocol); harness exposes raw handshake (#1465)
c147f1765 2026-10-19T12:51:33-07:00 lock: persisted-store corpus (V4): recorder, synthetic corpus home and 12 store locks read through the real owners (#1465)
1cb2bdefd 2026-10-19T11:39:04-07:00 test: UI locks record via TEST_RUNNER_TRON_UPDATE_LOCKS; one seeded DecorativeRandom; README (#1464)
290bc8ae6 2026-10-19T11:39:04-07:00 test: iOS UI lock framework with a11y and screenshot locks over hosted fixtures (#1464)
a58520b58 2026-10-19T11:19:21-07:00 lock: settle waits for no operation; reconnect lock records snapshots, not racy event shapes (#1463)
732cf7367 2026-10-19T11:11:23-07:00 lock: subagent kernel lock (gateway/delegation, nested pass); normalization owns file timestamps, path digests, activity and process ids (#1463)
07a31c7e6 2026-10-19T11:08:11-07:00 lock: reconnect-snapshot (gateway/transport) and settings-change (gateway/admin) kernel locks (#1463)
0892b5c5e 2026-10-19T11:06:57-07:00 lock: gateway lock harness and gateway/run kernel locks: prompt/stream, steer, abort, compaction, extension UI (#1463)
c0024b58f 2026-10-19T10:37:55-07:00 tooling: iOS layer baseline, ownership and docs for scripts/tron layers ios (#1459)
a0f402191 2026-10-19T10:08:45-07:00 tooling: scripts/tron layers: Gateway import graph against manifest layers with a shrink-only baseline (#1457)
a7533bc09 2026-10-19T02:44:22-07:00 feat(gateway): upgrade the Pi SDK cohort to 1.3.0 so model catalogs refresh again (#1340, #1025)
```
