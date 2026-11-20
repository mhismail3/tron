# Computer and browser use that stays reliable, including while the Mac is locked

Research plan for #2476 (2026-11-20, macOS 27.2 26B123, Mac17,7, 36 GB, Tron Cua 0.33.0 embedded,
Chrome for Testing 151.0.7922.138, agent-browser 0.33.2). Evidence labels: **PROVEN** (run here, raw
output in `probe/results/`), **OBSERVED** (read on this Mac, read-only), **REPORTED** (issue/forum),
**INFERRED**. Anything that needs another locked run is marked **untested, needs a maintainer-scheduled window**.

## 1. What we learned

### 1.1 Locked-console probe (PROVEN)

`probe/probe.mjs` ran the same battery three times, each step checked by an independent oracle (page
value over CDP, the scratch window's state file, PNG luminance):

| Step | Unlocked | Locked, display asleep | Locked, display on |
|---|---|---|---|
| CDP headless: click / Cmd+A replace / screenshot | pass 17 ms / pass / real frame (luma 252) | pass 3 ms / pass / real frame | pass / pass / real frame |
| CDP headless rAF frames per second | 56 | 55 | 59 |
| CDP headed window (default flags): click / replace / screenshot | pass / pass / real frame | **click fail** (oracle 0, 3 s) / pass / real frame | pass / pass / real frame |
| CDP headed + `--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling` | **click fail** / pass / real | pass / pass / real | pass / pass / real |
| agent-browser (headless) open + click + screenshot | pass 1.96 s | pass 1.37 s | pass 1.40 s |
| Cua `get_window_state` AX elements (scratch AppKit window) | 6 elements, 64 ms | **0 elements** | **0 elements** |
| Cua window screenshot | real frame | **error "No content produced"** | real frame (same luma as unlocked) |
| Cua click / type_text / set_value | pass 4.3 s / 4.3 s / 3.2 s | **no element tokens; type/hotkey `refused`** | same as asleep |
| Cua Cmd+A + type (native field) | not in baseline | refused, oracle unchanged | refused |
| Cua `get_desktop_state` / `screencapture` | real desktop (luma 117–130) | **returns a PNG of the lock screen** (luma 0, 100 % dark) | lock screen (luma 7, 73 % dark) |

Cua's own refusal on a live TextEdit window while locked: `off_space_or_ax_unresolved` "window is not
among the process's current AXWindows … background input is refused".

Conclusions:
1. **Browser work over CDP does not need the screen.** Headless and headed Chrome for Testing kept
   rendering, accepted input and produced real screenshots with the console locked, display on or off.
   This proves the browser half of "works while locked" with no new permission.
2. **CDP select-all works when the key event carries `commands: ["selectAll"]`** (5/5 runs). That is the
   root fix for #2481: the macOS editing command must ride on the CDP key event, not the key code.
3. **Desktop work through the real console is impossible while locked.** AX returns nothing, input is
   refused, and capture returns the lock screen. Nothing in the agent's own process can change this
   without an unlock.
4. **Capture lies while locked.** `get_desktop_state` and `screencapture` succeed with a picture of the
   lock screen. That silent wrong result is the most dangerous failure here, and #1195 must refuse it.
5. **The headed-window first click is flaky in both states** (1 failure in 6 headed runs, once unlocked
   and once locked), so it is not lock-related. Root-cause it with repeated reps (P3).
6. Cua actions take 3.2–4.3 s while observations take 64 ms, reproducing #2482.

### 1.2 How the Mac locks here (OBSERVED)

- `sysadminctl -screenLock` reports immediate. `pmset displaysleep 180`, system sleep 0. FileVault is
  off and auto-login is set to the maintainer's account.
- loginwindow logs `enqueueLockScreenRequest reason: 5` at the same second as every pmset "Display is
  turned off" event (e.g. 01:13:02 and 21:10:06). Idle locks are display-sleep locks (INFERRED from the
  matching times). So a scoped `PreventUserIdleDisplaySleep` assertion held during agent work prevents
  the idle lock. It cannot undo a lock.
- `caffeinate -d` lit the display while the console stayed locked. The lock and the display are
  independent once locked.
- Any user process can lock immediately: `login.framework` exports `SACLockScreenImmediate`, which
  returned 0 and set `IOConsoleLocked`. Relocking is therefore trivial. Only unlocking is hard.

### 1.3 How Codex "Locked use" works (OBSERVED on this Mac; it is already installed)

- **Bundle:** `/Library/Security/SecurityAgentPlugins/CodexComputerUseAuthorizationPlugin.bundle`
  (`com.openai.sky.CUAService.AuthorizationPlugin` 0.1.0 build 809). It is 68 KB, Developer ID
  Application: OpenAI OpCo (2DC432GLL2), with hardened runtime.
- **authorizationdb:** `system.login.screensaver` is now `rule = [com.openai.sky.CUAService.AuthorizationPlugin.remote,
  use-login-window-ui]` with `k-of-n = 1`. The new right is `class = evaluate-mechanisms` with
  `mechanisms = [CodexComputerUseAuthorizationPlugin:allow]` and `tries = 1`. With k-of-n 1, the
  screensaver right is granted if **either** the plug-in allows **or** the normal password UI succeeds.
  That is how the screen unlocks without a password.
- **No stored password.** The plug-in's only logic is to connect to
  `/tmp/com.openai.sky.CUAService/LockScreenLoginAuthorization.sock`. That socket is mode `rw-rw-rw-`,
  but the plug-in checks the peer's audit token code-signing identifier and team ID. It reads `ALLOW` or
  `DENY` and returns allow or deny. No Keychain, Secure Enclave or credential strings appear.
  Consequence (REPORTED, consistent): the login keychain is not unlocked by such an unlock.
- **It is live on 27.2.** At 10:53:07 and 12:03:48 today, authd ran `CodexComputerUseAuthorizationPlugin:allow`
  and the plug-in logged `Login authorization socket response=DENY` (no active Codex turn), then the
  password UI took over. The log also shows one `dlopen` failure in `SecurityAgentHelper-arm64`
  ("mapping process is a platform binary, but mapped file is not"), immediately followed by
  `AuthorizationPluginCreate called`. The non-platform helper still loads it. This is the same library
  validation edge as openai/codex#24013.
- **Service side** (`~/.codex/computer-use/Codex Computer Use.app`, `SkyComputerUseService` strings):
  `LockScreenAutoUnlockCoordinator`, `LockScreenLoginAuthorizationBroker/Approver/SocketServer`
  (answers the plug-in only while a ChatGPT thread holds an "auto-unlocked lease"),
  `SystemLockScreenAXInteractor` (`UserPasswordTextField`, "Press any key or click to unlock"; it
  drives the lock UI so loginwindow evaluates the right), and a separate `CUALockScreenGuardian.app`
  with a `LockScreenPhysicalInputMonitor` (local input relocks and sets `suppressedUntilManualUnlock`).
  `SystemLockScreenOverlayPresenter` puts the "ChatGPT is using your computer / Esc to cancel" shield
  over the displays. The installer tool (`… install|uninstall|status`) backs up the original
  `system.login.screensaver` right to a manifest and restores it on uninstall.
- **Known failures (REPORTED):** hang on 26.6 (openai/codex#26415), a 17-minute lockout and the
  mechanism left behind after disabling (#29616), login keychain left locked (community), library
  validation rejection on 26.5 (#24013).

**Security note for Mohsin:** this Mac already has a passwordless screen-unlock path. Any process
signed by OpenAI team 2DC432GLL2 that answers `ALLOW` on that socket unlocks the console. This is a
deliberate product feature, but it is a standing trust grant you should decide on (approval A6).

### 1.4 Other options (research briefs, mostly INFERRED, see §6)

- **macOS VM** (Tart/Lume/UTM on Virtualization.framework): the guest has its own login and lock state,
  so a host lock should not stop it (INFERRED, **untested, needs a maintainer-scheduled window**). The
  macOS 26 base image is about 25 GB, the stock credential is `admin/admin`, and the EULA reportedly
  allows 2 extra macOS VMs. The guest is a separate desktop: no access to Mohsin's apps, data or
  signed-in sessions.
- **Second GUI session** (hidden agent user + Screen Sharing virtual session): untested. It needs user
  creation (sudo) and its own TCC grants. A weaker boundary than a VM.
- **CGVirtualDisplay:** the lock is session-wide, so a virtual display in the locked session is still
  locked (INFERRED). Private API, no locked-use value. Dropped.
- **caffeinate / IOPMAssertion:** prevents the idle lock (§1.2) but cannot recover one.
- **Cua upstream** has no locked-session work (README read; INFERRED from absence). Upstream is at
  cua-driver-rs 0.55.4 vs Tron's 0.33.0, so the speed and popup gaps may already be fixed there.

## 2. Ranked options

| # | Option | Reliability | Works while locked | Security | Setup cost | Reversibility |
|---|---|---|---|---|---|---|
| 1 | **Tron-owned Chrome over CDP** (headless for unattended, headed for live view and logins; persistent owned profiles) | High; PROVEN 100 % locked except the known flaky first headed click | **Yes, PROVEN** | Good: own profile, loopback CDP, no personal Chrome | Already landed (#2556 owned browser) | Full |
| 2 | **Prevent the idle lock during active agent turns** (scoped `PreventUserIdleDisplaySleep`, #1195 branch) + fast finite refusal + iPhone notify | High for the in-turn case | Prevents the lock; not after one | Screen stays unlocked while an agent works and Mohsin is away | Code exists unlanded | Full |
| 3 | **Tron unlock lease**: authorization plug-in, Codex architecture, but each unlock approved on Mohsin's iPhone | Medium; macOS-version fragile (Codex reports) | **Yes, real desktop** | High-risk surface: system auth path; lockout risk; keychain stays locked | Developer ID cert, sudo install, ~4 tasks | Yes via backed-up right, if the uninstall is tested |
| 4 | **macOS VM agent desktop** (Tart) | Medium-high (INFERRED) | Yes, independent of the host (untested) | Best isolation; no host data | 25 GB+ image, 8 GB RAM while running | Full (`tart delete`) |
| 5 | Second macOS user session | Unknown | Possibly | Weaker than a VM | sudo, per-user TCC | Medium |
| 6 | Change lock settings / store login password / auto-type password | High | Yes | **Unacceptable**: a stored credential or a permanently unlocked Mac | — | — |
| 7 | CGVirtualDisplay | — | No (INFERRED) | Private API | — | — |

## 3. Recommended architecture

**The most robust design is to need the console as rarely as possible, and then to make the
console path honest and scoped.**

1. **Browser path (all web work): CDP only, Tron-owned Chrome.** Unattended surfaces (wakes,
   automations, delegated workers) default to headless. Use headed only when a live view or a human
   step (login, 2FA, CAPTCHA) is needed. Retire Cua-into-Chromium as a supported route. Its gaps
   (#2480: background input unverifiable, AX tree starves, select-all) disappear rather than get
   patched. Real accounts use owned persistent profiles signed in once with Mohsin's help (parallel
   task for the Pinfold studio profile). The worker blocked at 18:51Z was blocked only because its web
   work went through the console. On this path it would have continued.
2. **Native path (unlocked console): Cua, made fast and honest.** Land #1195 (finite `mac_locked`/
   `display_asleep` refusals, including capture), then fix the speed (#2482), popups (#2483) and sheet
   tokens (#2547) at the driver owner, measuring an upstream 0.55.x candidate first.
3. **Locked path, in order:**
   - **L1, no new authority:** hold the scoped display assertion while a computer turn is active, so a
     working agent is never locked mid-task. On a lock, refuse in under 1 s and send one iPhone
     notification ("Mac locked; unlock to continue <task>"). Browser work continues.
   - **L2, the real desktop while locked, if Mohsin wants Codex parity:** a **Tron unlock lease**. It
     copies Codex's proven architecture (authorization plug-in that only says allow/deny, no password)
     with three stricter rules. (a) Each lease needs an exact tap on Mohsin's iPhone, bound to one task
     and a time limit; nothing local can request one. (b) A shield on every display, relock on any
     physical input, and `SACLockScreenImmediate` at lease end, Stop, crash or timeout. (c) The plug-in
     fails closed in under 1 s: any socket error, timeout or signature mismatch returns deny, so the
     password UI always remains. **Prototype it inside a macOS VM guest first** (root in a disposable
     guest), and install on the host only after the unlock-and-relock rows pass there.
   - **L3, optional:** a Tart VM as an isolated "agent desktop" for native tasks that do not need
     Mohsin's data (app testing, risky installs, untrusted sites).

Why this order: L1 is reversible and needs no approval. CDP already covers most real tasks while
locked (PROVEN). L2 is the only way to drive Mohsin's actual apps while locked, but it changes the
system authentication path, so it must earn its place in a VM first.

## 4. Experiment matrix (new computer-bench rows)

Locked rows run only when `IOConsoleLocked` is already true from a natural idle lock (like `--foreground`
waits for idle). Otherwise they report `needs-locked`. The bench never locks the Mac itself.

| Row | Setup | Pass | Fail | Status |
|---|---|---|---|---|
| `locked-browser` | Owned Chrome headless, locked | click, Cmd+A replace, screenshot luma > 40 and not dark, oracle-verified, 3/3, median < 200 ms | any oracle miss or dark frame | PROVEN 3/3 ad hoc; needs a bench row |
| `locked-browser-headed` | Owned Chrome headed, locked | same, 10/10 | any miss | 5/6 headed runs overall; flaky first click; root-cause first |
| `locked-refusal` (existing n/m) | Cua observe/act/capture while locked | finite `mac_locked` refusal < 1 s, **no PNG returned** | timeout, generic error, or a lock-screen image | Fails today: capture returns the lock screen (PROVEN) |
| `display-asleep-refusal` | Locked, display asleep | `display_asleep` refusal < 1 s | — | Untested, needs a maintainer-scheduled window |
| `idle-lock-held` | Active computer turn > displaysleep | no lock during the turn; assertion gone after turn end, Stop and a killed runtime (`pmset -g assertions`) | lock mid-turn or a leaked assertion | #1195 branch has a fixture proof; physical run untested |
| `unlock-and-relock` | Unlock lease (VM first) | iPhone-approved lease unlocks in < 5 s; shield on all displays; relock < 1 s after lease end; physical input relocks < 500 ms; 0/20 unlocks without a fresh approval; plug-in timeout/kill → password UI in < 2 s; uninstall restores the exact backed-up right | any unlock without approval, a hang > 2 s, or a residual right | Untested, needs approvals A2–A4 |
| `locked-native` | Lease active, scratch window | native-click/type/replace/select/modal pass like the unlocked rows | — | Untested |
| `keychain-after-unlock` | After a lease unlock | `security show-keychain-info login.keychain-db` reports the state; documented, no secret read | — | Untested |
| `vm-desktop` | Tart guest, host locked | guest Cua native rows pass; guest screenshot real | guest locked or paused | Untested, needs A1 |
| `cua-speed` (#2482) | Unlocked | native-click/type ≤ 0.5 s median, 3/3 | — | Baseline 3.2–4.3 s PROVEN |
| `native-select` (#2483), `native-sheet` (#2547) | Unlocked | 3/3 background, ≤ 1 s | — | Baseline 0/3 |

## 5. Phased tasks (~2 h each)

| Phase | Task | Acceptance | Approval |
|---|---|---|---|
| P1 | Land #1195 (unlanded `fix/1195-console-admission`), extended so `get_desktop_state`/window capture refuse while locked | `locked-refusal` passes in the next natural lock; capture never returns a lock-screen PNG; assertion lifecycle proof green | none (Gateway install stays Mohsin's) |
| P2 | Add `locked-browser`, `locked-refusal` and `needs-locked` gating to computer-bench; replace `probe/` with the bench rows | rows report `needs-locked` when unlocked and pass when naturally locked; probe deleted | none |
| P3 | Browser path: unattended surfaces use the owned browser headless; key events carry macOS editing `commands` (#2481 candidate); root-cause the headed first-click flake | `replace` 3/3 agent-browser; headed click 20/20; `locked-browser` 3/3 | none |
| P4 | Retire Cua-into-Chromium as a route: bench web rows move to CDP; close #2480 with evidence | no Cua web rows; scorecard regenerated | none |
| P5 | Cua speed: profile the 3–4 s (settle/verify waits vs CLI per call); bench an isolated upstream 0.55.x candidate via `COMPUTER_BENCH_CUA_DRIVER/SOCKET` | `cua-speed` ≤ 0.5 s or a measured owner decision | driver upgrade follows the normal updater |
| P6 | Popups and sheets (#2483, #2547) at the driver/adapter owner | `native-select`, `native-sheet` 3/3 | none |
| P7 | Maintainer-scheduled locked window (Mohsin present): `display-asleep-refusal`, headed Chrome via Cua while locked, one Codex Locked-use turn on 27.2 (observe unlock, shield, relock, keychain state) | rows recorded with raw logs | A2 |
| P8 | Tart VM spike: one macOS guest, auto-login, Cua in the guest, host locked naturally | `vm-desktop` result; RAM/disk measured | A1 |
| P9 | Unlock-lease design + plug-in prototype **in the VM guest** (iPhone approval stubbed by a signed local broker) | `unlock-and-relock` passes in the guest, including fail-closed and uninstall | A1, A3 |
| P10 | iPhone-approved lease end to end (Gateway approval card → Native Host broker → plug-in) in the guest | 0/20 forged unlocks; lease-scoped audit log | A3 |
| P11 | Host install behind an exact native card, then `unlock-and-relock` + `locked-native` on the real console | all rows pass; uninstall tested on the host | A4 (+A6 decision) |

## 6. Approvals needed from Mohsin (exact)

| ID | Action | Risk | Undo |
|---|---|---|---|
| A1 | `brew install cirruslabs/cli/tart`, then `tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tron-agent` (~25 GB download, ~8 GB RAM while running) and change the guest's `admin/admin` password | disk, RAM, a VM on the LAN if bridged (use NAT) | `tart delete tron-agent; brew uninstall tart` |
| A2 | One 30-minute maintainer-present locked window for P7 (agent locks with `SACLockScreenImmediate`; you unlock) | blocks every desktop worker for the window | you unlock |
| A3 | Create a **Developer ID Application** certificate on team MYGKXH6TY4 (only Apple Development and Apple Distribution exist today); needed to sign a SecurityAgent plug-in | an account-level signing identity | revoke (itself approval item 3) |
| A4 | Host install of the Tron unlock plug-in: `sudo` copies the signed bundle to `/Library/Security/SecurityAgentPlugins/`, saves `security authorizationdb read system.login.screensaver` as a backup, then writes the right as `[com.tron.unlock, <existing entries>]`, k-of-n 1 | a bug in the system unlock path can hang the lock screen (Codex #26415/#29616); login keychain stays locked after an agent unlock; a second passwordless path next to Codex's | `sudo security authorizationdb write system.login.screensaver < backup.plist; sudo rm -rf …/TronUnlock.bundle`; Screen Sharing (already on) remains a recovery route |
| A5 | Decision: hold a display-sleep assertion during active computer turns (L1) | the screen stays unlocked and visible while an agent works unattended | already scoped to the turn; turn it off by setting |
| A6 | Decision on the **existing Codex Locked-use plug-in**: keep, or remove with `"…/Codex Computer Use Installer.app/Contents/Resources/CodexComputerUseAuthorizationPluginInstallerTool" uninstall <resources>` (root) | keeping it is a standing passwordless unlock path for OpenAI-signed code; removing it disables ChatGPT Locked use | reinstall from ChatGPT settings |
| — | Not recommended, not requested: storing the login password, changing the screen-lock delay, disabling the lock, new TCC grants | — | — |

## 7. Proven vs inferred

- PROVEN on this Mac: §1.1 table; `SACLockScreenImmediate` locks; `caffeinate -d` wakes the display
  without unlocking; Cua 3–4 s actions; CDP `selectAll` command fixes replace.
- OBSERVED read-only: Codex plug-in bundle, signature, authorizationdb rules, socket, service class
  names, plug-in DENY log lines, lock-reason/display-sleep coincidence, signing identities.
- INFERRED: the keychain stays locked after a plug-in unlock (REPORTED + mechanism); VM guests survive a
  host lock; a second session works; CGVirtualDisplay has no value; Cua upstream fixes.
- Untested, needs a maintainer-scheduled window: headed Chrome driven by Cua while locked, the
  display-asleep refusal row, a Codex locked turn end to end on 27.2, every L2/L3 row.

## 8. Evidence files

- `probe/probe.mjs`, `probe/native.swift`: the probe battery (temporary; replaced by bench rows in P2).
- `probe/results/unlocked-baseline.json` (19:57:51Z), `locked-display-asleep.json` (20:00:50Z),
  `locked-display-on.json` (20:02:16Z): raw step results.
- Research briefs (session artifacts, partial because the search provider was rate-limited):
  `codex-locked-use.md`, `cua-upstream.md`, `vm-and-sessions.md` under workflow run
  `66bdaf81-456a-4107-b847-de5d77823401`.
