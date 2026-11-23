# Computer use, locked-Mac use and browser automation: master plan

Parent issue: #2476. Written 2026-11-21 against main `ee42fcb13`. That is also the Gateway now running
in `/Applications/Tron.app` (payload `sourceRevision`, process started 11:11 PT). The installed Cua
driver is 0.33.0. This plan identifies and root-causes problems; it changes no code.

Evidence labels:
- **PROVEN**: run or read here, with a file:line or log reference.
- **INFERRED**: follows from source but was not run.
- **UNKNOWN**: not settled. The settling experiment is named.

The Mac was locked for the whole investigation. No desktop reproduction was possible, so every claim
that needs the unlocked desktop is labelled as such.

## 0. Summary for a reader with no context

Tron operates the Mac in two ways:
- **`computer`**: native apps through the bundled Cua driver, which works by accessibility and synthetic input.
- **`agent_browser`**: web pages through a Tron-owned Chrome for Testing that it controls over the Chrome
  DevTools Protocol (CDP).

About 20 open items reduce to **nine root causes**:

1. Web work is routed through the desktop.
2. The Cua driver pin is 23 releases behind upstream.
3. Tron's Cua adapter has no deadlines and a mismatched contract.
4. The browser engine misses macOS editing commands.
5. A locked console makes the desktop unusable.
6. The tools are not equally available on every surface.
7. The owned browser has lifecycle edges.
8. Browser guidance and errors point to refused routes.
9. Measurement is stale and bypasses the product path.

Two items are now resolved or obsolete:
- The locked-Mac refusal (#1195) and the studio-profile launch fix are live. A `computer` call during
  this task returned `mac_locked` without capturing anything (PROVEN).
- The personal-Chrome attach (#2479) was superseded by the 2026-11-15 ruling that Tron stops attaching
  to personal Chrome.

Most remaining work is mechanical once three decisions are made: the driver upgrade, carrying a patched
browser engine, and whether Tron may ever unlock the Mac.

## 1. Goal and requirements

**Goal.** Tron can do anything Mohsin could do at the Mac, unattended and from any surface (Home,
workers, subagents, automations). It acts at human speed or faster and verifies every effect. When it
cannot act, it says why within a second.

| # | Requirement | Measure |
|---|---|---|
| R1 | **All web work runs over CDP in a Tron-owned Chrome** (headless when unattended, headed for live view or a human step). It works with the Mac locked or unlocked, and in persistent signed-in owned profiles such as studio. Never Mohsin's personal Chrome. | Web rows of §2 3/3, also while locked; median action ≤ 300 ms |
| R2 | **Web text is exact.** Type, replace, select-all and paste of Unicode text read back byte-exact from the DOM before any submit. | `replace`, `caption-exact` 20/20 |
| R3 | **Native apps on the unlocked console:** read, click, type, replace, pop-up select, sheet or modal, file dialog and permission prompt. Background first; foreground only when refused, and the frontmost app is restored afterwards. | Native rows 3/3; action median ≤ 0.5 s; modal ≤ 1 s |
| R4 | **Honest failure.** Locked, asleep, no console, a hung driver, a stale token or an uncertain effect each gives a finite typed result in < 1 s (a hang is bounded at 10 s). No lock-screen image is returned and no call hangs. | Refusal rows 3/3 |
| R5 | **No mid-task lock** while Tron is actively working. Locked use (acting on the real desktop while locked) happens only if Mohsin approves it (D3). | `idle-lock-held`; `unlock-and-relock` if D3 |
| R6 | **Every surface:** Home maintainer turns, task workers, interactive sessions, automations and subagent children that ask for them. | Surface rows ≥ 19/24 measured, not declared |
| R7 | **Measured on the product path.** The bench calls the same adapter the agent uses, on the installed driver. | Scorecard regenerated per package |

## 2. Acceptance scorecard

`scripts/tron computer-bench` runs these tasks. Each is checked by an independent oracle (DOM over CDP,
a scratch-window state file, or PNG luminance), never by the tool's own claim. Three repetitions unless
stated otherwise.

| Row | Requirement | Pass |
|---|---|---|
| web-navigate/click/type/form/upload/download/tab/dialog/screenshot/ax/session-reuse/oauth | R1 | 3/3, median ≤ 300 ms (session-reuse ≤ 5 s) |
| web-replace | R2 | 3/3: Meta+A then type gives exactly the new value |
| caption-exact | R2 | 20/20: a 280-char Unicode caption (·, quotes, URL, emoji) into a contenteditable composer fixture reads back byte-exact |
| owned-persistent-profile | R1 | prepare → launch → record → connect → read → close, 20/20, zero orphans |
| locked-browser | R1 | the web rows above pass with `IOConsoleLocked=true`, headless and headed |
| native-read/click/type/replace | R3 | 3/3 background, median ≤ 0.5 s |
| native-select | R3 | 3/3 background, ≤ 1 s |
| native-sheet | R3 | fresh sheet-button token clicks 3/3; stale and foreign tokens refuse |
| native-modal | R3 | 3/3, ≤ 1 s |
| native-file-dialog | R3 | choose a file by path in an NSOpenPanel, 3/3 |
| foreground-restore | R3 | foreground input, then the frontmost app is restored, 3/3 (idle Mac) |
| permission-prompt | R3 | approve a real TCC prompt for a scratch app, 1/1, maintainer-scheduled |
| locked-refusal / asleep-refusal | R4 | typed refusal < 1 s, no PNG (natural lock only) |
| driver-hang | R4 | a stalled driver call ends as `outcomeUnknown` ≤ 10 s; Stop ends the turn in ≤ 1 s |
| idle-lock-held | R5 | no lock during a working turn longer than display sleep; assertion gone after end, Stop or kill |
| surface-home / worker / subagent | R6 | each surface runs the rows end to end through its own admission |

## 3. Items and root causes, grouped by shared cause

Each item lists: **symptom → reproduction → root cause and evidence → acceptance**.

### RC1. Web work routed through the desktop (Cua into Chromium)

This is the main cause of the field failures. Cua acts on Chromium through accessibility and synthetic
key events. Neither carries DOM truth, so Cua cannot see or confirm what happened in the page.

- **#2480a: background Cmd+A does nothing in Chromium.**
  - Reproduction: `computer-bench --tools cua --only replace` (0/3 on 0.28).
  - Cause, PROVEN path: Cua posts combos to the process (`SLEventPostToPid`, cua `input/keyboard.rs:632-640`)
    without making the window key. Select-all is an editing command that goes through the key window's
    responder chain. Upstream conceded this in v0.56.0 (`7539bddaf`, "stop promising background hotkeys
    reach Chromium").
  - UNKNOWN: the exact drop point. Experiment: on an isolated Chrome for Testing window, compare background
    `hotkey`, `press_key`+cmd and foreground `hotkey`, reading the selection over CDP.
  - The CDP route solves it (RC4): the prior probe showed 5/5 when the key event carries `commands:["selectAll"]`.
- **#2480b: every web action reports `unverifiable`.**
  - Cause, PROVEN and by design: `hotkey.rs:502-512` always returns unverifiable. `type_text.rs:435-440`
    refuses AXValue as proof inside an AXWebArea. Tron maps that to `outcomeUnknown` (`cua-client.ts:30-36`).
  - Only a DOM read can confirm a web effect, so this cannot be fixed inside Cua.
- **#2480c: the web accessibility tree starves on fast polling.**
  - Cause, PROVEN that 0.33 lacks the first-read wait: upstream added it in v0.36.0 (`4f7084573`), v0.42.4
    (`5a9530166`) and v0.55.0 (`5e2614903`, "read Chrome's page content on the first read"). That makes it
    also RC2.
- **Field F2: X captions garbled** (Pinfold worker, 2026-11-20 19:02–19:06Z).
  - Two foreground `hotkey cmd+v` pastes both returned `unverifiable` and appeared not to land. A
    221-character foreground `type_text` followed and took 24 s, against about 6.6 s nominal. The agent
    then saw the earlier pastes "landed late and mixed with the typed text".
  - Cause: INFERRED. The pastes were queued to Chromium and interleaved with the keystroke stream; the root
    is that a web edit was made without DOM confirmation.
  - The window was not in the background for the typing: every `type_text` was foreground.
  - The exact corruption is UNKNOWN, because the evidence is screenshots that are not in the transcript.
    Experiment: on the `caption-exact` fixture, foreground `type_text` with and without a preceding
    unconfirmed paste, 20 runs each, reading back over CDP.
  - What worked: clear, foreground `type_text`, then read back through `cmd+a`/`cmd+c`/`pbpaste`. The
    `pbpaste` read shows false mismatches without `LANG=en_US.UTF-8`.
  - The same worker typed byte-exact over CDP `keyboard type` in the studio fix session (#2476 comment of
    2026-11-20). That is the RC1 fix shown working.
- **Field F6: other web steps that failed through Cua.**
  - `cmd+shift+g` went to Chrome's find bar instead of the file dialog. Foreground keys go to the frontmost
    window; the dialog is a separate window.
  - An Instagram hour field typed `06` and got `03`.
  - About 40 observations per X post: every action is unconfirmed, so the agent re-observes after each one.
  - The equivalent CDP operations (`upload` via setInputFiles, `fill`/`type`, DOM read) already pass 3/3 on
    the bench.
- **Who shares RC1:** F2, F6, #2480a/b, and #2476 gaps 3 and 5 (the huge `get_window_state` output).
- **Acceptance:**
  - Web tasks never use `computer` (the `computer` guidance says so; the bench has no Cua web rows).
  - `caption-exact` 20/20 and `web-replace` 3/3 through `agent_browser`.
  - Close #2480a/b as superseded by the route change. Keep #2480c under RC2 only for native Electron apps.

### RC2. The Cua driver pin is behind upstream

Tron pins 0.33.0 (`packages/mac-app/cua-driver-release.json`). Upstream is v0.56.8. The upstream source
was checked at both tags (`git tag --contains`).

- **#2483: pop-up selection 0/3.**
  - Cause, PROVEN at 0.33: `set_value.rs:504-580` reads only the children of a closed popup, which are
    empty, and never opens the menu.
  - Fixed upstream in v0.35.0 (`848116252`, #4740): `set_value` opens the menu, picks the item and closes it.
    Tron already admits `set_value`.
  - Risk, INFERRED: opening the menu takes key focus for about 0.4 s.
- **#2482: actions take 3–4 s.**
  - Part PROVEN: the 0.33 post-action window watch waits a fixed 1000 ms when nothing changes
    (`window_change_detector.rs:163,341-365`, called from `click.rs:781` and `type_text.rs:391`).
    v0.39.0 (`41591b1b3`) reports after 300 ms and adds a per-call `post_action_wait:"none"`.
  - Part INFERRED: element-addressed `type_text` waits for the cursor-overlay glide (`type_text.rs:318-338`),
    which is still present on upstream main.
  - 1.5–3 s per action is unattributed (UNKNOWN). Measured on 0.28 only: there is **no 0.33 timing in the
    repo**.
  - Not the cause: the Tron console probe (40–80 ms, measured) and CLI spawn (18 ms).
  - Experiment: an isolated daemon on 0.33, then v0.39+, then v0.56.8:
    1. `native-click`/`native-type`, plus 0.33 with `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0`;
    2. AX-addressed versus pixel-addressed `type_text`, to isolate the glide;
    3. one `sample` of the daemon.
- **#2547: Chrome sheet tokens refused (`element_outside_target_window`).**
  - Root cause, on 0.28: an element was mapped to the sheet's own window ID instead of its parent window.
  - Fixed upstream by `030d5a0c0` (#4507), which is an ancestor of the 0.33 tag. **Likely fixed in the
    installed driver** (PROVEN in source; behaviour unverified).
  - Do not land Tron's duplicate fork `8b1d86908`.
  - Residual risk: 0.33 can drop sheet buttons under its walk budget (fixed in v0.52.4, `bc6e85dae`).
    v0.41.0 changes how sheet IDs are reported.
  - The original trigger, personal Chrome's debugging sheet, is obsolete. The row stays because system sheets
    and permission prompts need it.
  - Acceptance: `native-sheet` on an isolated Chrome for Testing sheet or an AppKit sheet fixture.
- **Field F4 (Cua 0.28→0.33 state):**
  - Today, PROVEN: the running daemon (pid 97032, started 11:11) and the bundled binary are both 0.33.0.
  - Which version answered on 2026-11-20 is UNKNOWN; no version appears in the transcript. Experiment:
    `log show --predicate 'process == "cua-driver"' --start 2026-11-20` for the version banner.
- **#2551 (verify does not select the pin's consumer tests).**
  - Root cause, PROVEN: `cua-driver-release.json` is owned by `packages/mac-app/package.module.json`, which
    selects only `test-push-product-config.sh`. Its real consumers, `scripts/test-cua-assets.sh` (line 10) and
    `scripts/test-verify-mac-install.py` (lines 136-139), are owned by `scripts/mac.module.json`.
  - This is a prerequisite of the pin package (WP3).
- **Acceptance:** pin the chosen release. Then `native-select` 3/3; `native-click`/`native-type` ≤ 0.5 s
  (with `post_action_wait:"none"` admitted, RC3); `native-sheet` 3/3; the `ax-read` first read shows page
  content. New-window reporting must survive on a menu-opening click.

### RC3. Tron's Cua adapter: no deadlines, one process per call, mismatched contract

Owner: `packages/gateway/src/machine/cua-client.ts`.

- **N1 (new, #2644): no timeout or abort on any driver call.**
  - PROVEN: `execFileAsync` at `:110`, `:129`, `:155` and `:220` passes neither `timeout` nor `signal`.
  - A hung daemon blocks the turn, and Stop cannot end it.
  - `close()` loops forever on `session_cleanup_pending` (`:218-228`).
- **N1b (new, PROVEN): orphaned test processes.** Four `driver.cjs call end_session` processes from
  `console-admission.integration.test.ts` have been alive since 2026-11-20 22:33 with PPID 1. The fake
  driver handles any non-`start_session` call by writing its dispatch marker and, in `hold` mode, blocking on
  its FIFO (`:78-86`). Its `end_session` therefore blocks forever. It is the test-side image of N1: nothing
  bounds the call.
- **N2: one CLI process per call, plus a `start_session` before each observation.** This is a measurable
  share of RC2's unattributed time (UNKNOWN). Experiment: time `call` against a persistent socket client on
  the same daemon.
- **#2476 comment (help advertises `session`), PROVEN:**
  - Upstream schemas admit `session` on every tool (`cua-driver-core/src/tool.rs:218-222`).
  - Tron forwards `describe` verbatim (`:110`) but reserves `session` (`:17`) and injects its own (`:138`).
  - Fix the projection; keep the reservation.
- **N3: `post_action_wait` is not admitted**, so the v0.39 speed control cannot be used.
- **N4: the daemon has no window-change policy.** `packages/mac-app/Sources/NativeHost/CuaProcessOwner.swift` (line 41-47)
  sets no `CUA_DRIVER_WINDOW_CHANGE_*` variable. Prefer the per-call argument (Gateway-only, so no signed
  rebuild, #2548) over a host environment change.
- **Field: stale tokens give a generic error.** Element tokens go stale after the snapshot is invalidated,
  and the error does not say so. The adapter refuses with "Element reference does not belong to this
  session's latest window observation" only in its own check. Driver-side staleness surfaces as "Computer
  operation unavailable or uncertain".
- **N6: contradictory guidance.** The prompt says "Prefer background AX actions", but for web content
  background delivery is unverifiable. RC1 removes the web case.
- **Acceptance:**
  - `driver-hang` row; Stop during a stalled call returns in ≤ 1 s.
  - The help output has no `session` field.
  - `post_action_wait` is admitted only where the driver schema advertises it.
  - A typed `stale_element` cause is returned.
  - The orphaned fixtures are gone, and the test reaps its children.

### RC4. The browser engine does not send macOS editing commands (#2481)

- Symptom: `replace` 0/3 on agent-browser 0.33.2 and 0.42.0 (`old valuenew value`, 2026-11-15 and 16).
- Cause, PROVEN: the engine's CDP `Input.dispatchKeyEvent` for Meta shortcuts omits `commands`. Upstream
  v0.43.0 still omits it. On macOS, Chromium performs editing shortcuts only from that `commands` field.
- The fix exists only in the local worktree `tron-worktrees/2481-agent-browser-shortcuts`: commits
  `b12cb7f` and `775a666`. It has a non-author ACCEPT, and a debug binary passed 3/3. It is not packaged:
  the bundle has engine 0.42.0, the wrapper's dist has no editing-command code, and the wrapper refuses any
  other engine version.
- Shares the cause with RC1's web path and with the R2 caption requirement.
- Acceptance: the shipped engine passes `web-replace` 3/3 and `caption-exact` 20/20. Needs decision D2.

### RC5. A locked console makes the real desktop unusable

- **Proven facts** (prior probe, `research/computer-use-reliability-20261120`, PLAN.md §1.1):
  - While locked, accessibility returns 0 elements, input is refused, and capture returns the lock screen.
  - CDP browsers keep working locked, headless or headed. A headed window needs
    `--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling`
    for the click to land when the display is asleep. The owned launch has none of these flags (PROVEN:
    absent from `tron.patch`).
- **#1195 is landed and live** (`ca6fed963`; this task's `computer get_desktop_state` returned `mac_locked`).
  Residual gaps, PROVEN from `console-probe.ts`:
  - no `no_console_session` cause (fast user switching, or no GUI login);
  - a probe failure throws an untyped "Console state is unavailable" (`:34`);
  - the display assertion is held only while a `computer` turn runs (`cua-client.ts:116`), not while a task
    that will need the desktop is between turns.
- **Field F5:**
  - The Pinfold worker hit black captures while locked at 18:51Z, before #1195 was live. Detection then was
    by hand, through `ioreg`.
  - The Mac relocked overnight, and the 2026-11-21 resume needed Mohsin to unlock it.
  - Idle locks follow display sleep (loginwindow `reason: 5` at each display-off; INFERRED from matching times).
- **Locked use (L2): the unlock-lease prototype.**
  - `research/unlock-lease-20261120` @ `47a4597e5`, Tart guest on macOS 26.6.2. All 14 rows passed: allow,
    deny, replay, hang, impostor, crash, relock on physical input or expiry or kill, password fallback, and
    uninstall.
  - A lease unlock never unlocks a locked login keychain.
  - Never run on the physical Mac (27.2). Needs a Developer ID certificate and a sudo install (D3).
- **Existing passwordless unlock path (OBSERVED):** the Codex plug-in
  `com.openai.sky.CUAService.AuthorizationPlugin.remote` is still in `system.login.screensaver` today
  (`security authorizationdb read`). Decision D4.
- **#2469 (Gateway children see empty socket tables)** is a separate problem with an UNKNOWN cause. It shares
  RC5 only if the same per-process policy also hides session state from Gateway children.
  - Today the probe, run as a Gateway child, does report the lock correctly (PROVEN by the refusal above).
    The link is therefore unlikely for lock state.
  - Experiment: run `osascript` `CGSessionCopyCurrentDictionary` and the TCC-bound `screencapture` from a
    Gateway child and from Terminal, and compare.
- **Acceptance:** the `locked-refusal`, `asleep-refusal`, `idle-lock-held` and `locked-browser` rows. If D3 is
  approved, also `unlock-and-relock` and `locked-native` (prior PLAN.md §4).

### RC6. Tools are not equally available on every surface

- **#2478 (Home row).** Source is landed (`d3c87b960`, `726e2247f`): Home has `computer` and `agent_browser`
  on every activation.
  - Root cause of "0/25", PROVEN: the scorecard projects declarations from `surfaces.json`. No Home E2E calls
    `computer` (`home-tool-admission.e2e.test.ts` covers lists and refusals only).
  - This is a measurement gap, not a capability gap.
- **#2484 (subagent children lack `computer`).**
  - PR nicobailon/pi-subagents#3281 is **closed, not merged** (2026-11-15). The maintainer said a child can
    already opt in through `subagentOnlyExtensions`/`extensions`.
  - The real root cause, PROVEN: `computer` is not a loadable extension file. It is a Gateway module that
    needs the Gateway's `ConsoleGate` and its Native Host capture binding
    (`display/computer-module.ts`, `machine/cua-client.ts:8,52`). A child cannot load it by path, and
    `tron-core-extension.ts:26` does not pass Gateway-only extensions to children.
  - Pinned pi-subagents `0.76.1-tron.19` has no `toolNames` gating (PROVEN).
  - Whether a child can reach the Gateway's binding over a socket is UNKNOWN. Experiment: a standalone
    `computer` extension file that talks to the Gateway (or Native Host) endpoint, loaded through
    `subagentOnlyExtensions` in a test agent definition.
  - Shared with the browser: `worker.md` loads `agent_browser` from a user git clone
    (`~/.tron/agent/git/github.com/fitchmultz/pi-agent-browser-native/...`), not from the pinned, patched
    package. So **subagents run an unpatched browser without owned-launch admission**. PROVEN: that file
    (wrapper 0.4.1, dated 2026-09-15) differs from the bundled 0.9.19-tron.1 one and contains no `owned_launch_required` or
    `studioPrepare`, while the bundled file does.
- **Acceptance:** `surface-home`, `surface-worker` and `surface-subagent` measured end to end, each ≥ 19/24.
  The subagent browser comes from the pinned package.

### RC7. Owned-browser lifecycle edges

Owner: `packages/gateway/third_party/pi-agent-browser-native/tron.patch`.

- **#2563.1, PROVEN open:** the `known && known.master !== session` branch returns `attached` without
  `AGENT_BROWSER_CDP` (patch `:441-442`, compare `:460`). The re-prepare result after `launchRoot` is not
  checked (INFERRED; read `admit` past `:472`).
- **#2563.2, INFERRED open:** `studioCleanup` (`:973`) does not reuse the ESRCH liveness rule in `live()`.
- **#2563.3, PROVEN open:** `display/README.md:89` still describes `browser-binding.v1`.
- **#2563.4/5:** bench and runner cleanup, status to recheck.
- **#2563.6 and #2574:** a thin `beforeAll` margin (10.4 s against 10 s under load). An aborted `close` leaves
  "Session is running". UNKNOWN cause. Experiment: five attaches under recorded host load, logging the
  `close` exit and the daemon pid file.
- **#2629.1, PROVEN:** `live()` calls `realpath(launch.profile)` eagerly (`:816`). A renamed profile throws
  ENOENT and blocks every owned operation.
- **#2629.2, PROVEN:** `studioPrepare` deletes `DevToolsActivePort` without checking for a live receipt
  (`:920`). A second launch hands off to the running Chrome and times out.
- **Headed flags:** see RC5.
- **Field F3 ("Chrome profile unopenable"): no evidence found.** The transcript has no "unopenable",
  "SingletonLock" or "profile error". Its "in use" and "already running" hits are system-prompt text. It
  matches #2629.2 (a relaunch on a live profile) or a `SingletonLock` from a killed Chrome (the worker killed
  pid 90356 by hand). Both INFERRED; the cause is UNKNOWN.
  - Experiment: on a scratch persistent profile:
    1. `owned-launch prepare` while its Chrome is live;
    2. `kill -9` the Chrome, then relaunch;
    3. record the Chrome stderr and `SingletonLock`.
- **Acceptance:** the `owned-persistent-profile` row 20/20, plus the fail-before/pass-after cases in
  `browser-fork-receipts.integration.test.ts`.

### RC8. Guidance and errors point agents to refused routes

- **New, PROVEN (#2645).** The bundled browser wrapper tells the model to
  `open -a <App> --args --remote-debugging-port=9222 ...; then agent_browser connect 9222`. Sources:
  `Gateway/app/node_modules/pi-agent-browser-native/dist/extensions/agent-browser/index.js:39525-39529`
  (`ELECTRON_EXISTING_AUTH_GUIDANCE`) and the wrapper's `COMMAND_REFERENCE.md` (line 497).
  - Owned admission refuses exactly that route with `owned_launch_required`.
  - This is the route the Pinfold worker followed at 18:50:52Z (`connect 61749`, refused).
- **Field F1:** the refusal names no remedy. The working recipe
  (`owned-launch prepare <dir>` → launch → `record` → `connect`) exists only in a #2476 comment.
  - Shares the owner with RC7.
- **Home brief residue:** briefs still say "if `agent_browser` refuses, use Cua". Under RC1 that is the route
  that garbles text.
- **Acceptance:**
  - The refusal includes the `owned-launch prepare` remedy.
  - The upstream guidance is replaced in the patch.
  - A fresh worker given only "post in the studio profile" reaches `connect` on its first try (one live
    transcript).

### RC9. Measurement is stale and bypasses the product path

- **N2b, PROVEN:** `tools/computer-bench/cua.mjs` (line 25) calls the driver CLI directly. Cua rows therefore skip
  the console gate, the reserved-argument rules and the adapter's timing.
- `SCORECARD.md` (2026-11-15) is agent-browser only, 1 repetition. All Cua numbers are from 0.28.
- Home and subagent rows are projected from declarations.
- There are no locked, caption, persistent-profile or file-dialog rows.
- **Acceptance:** the bench drives `CuaComputerClient` (the product adapter), records the driver version per
  run, and regenerates the full scorecard at each package boundary.

### Not computer-use causes

| Item | Disposition |
|---|---|
| #2479 consented personal-Chrome attach | **Obsolete.** The #2556 ruling (2026-11-15) is that Tron stops attaching to personal Chrome. The bench and source have no `chrome-cdp`/`signed-in-chrome` path left (PROVEN by grep). Close as not planned. |
| #2548 mini Mac signing identity | Separate infrastructure. Blocks only Native Host changes (the signed Mac build). This plan routes around it: every package is Gateway-only except a Native Host environment change, which is avoided via N3. |
| #2469 Gateway-child socket tables | Separate, cause UNKNOWN; experiment in RC5. |
| #2576 one queue, #2502 paused-child timeout | Unrelated to computer use. |
| upstream pi PR #3281 | Closed by upstream, so it is not a path. RC6 replaces it. |

## 4. Work packages in dependency order

Size: S ≤ 2 h, M ≈ one 2–3 h cycle, L = two cycles. All are Gateway or tools changes unless noted. "Desktop"
means it needs an unlocked, idle-enough Mac for a short bench slot.

| WP | Content | Depends on | Tests / proof | Size |
|---|---|---|---|---|
| **WP0** | **Measurement on the product path.** Bench drives `CuaComputerClient`; records driver version; adds rows `caption-exact`, `owned-persistent-profile`, `native-sheet`, `native-file-dialog`, `driver-hang`, `locked-*` (report `needs-locked` unless naturally locked). Take the first 0.33 baseline. | — | `bench.test.mjs`; one full 3-rep run (desktop) | M |
| **WP1** | **Adapter hardening (RC3).** Deadlines and abort on every driver call; bounded `close()`; typed `stale_element`; help strips `session`; reap the orphaned console-admission fixtures and make the fake driver unblockable. | — | `driver-hang` row; extend `console-admission.integration.test.ts` (fail before: hangs) | M |
| **WP2** | **Web goes over CDP (RC1 + RC8).** `computer` guidance and Home briefs route all web work to `agent_browser`; the refusal carries the owned-launch remedy; replace upstream `--remote-debugging-port` guidance in `tron.patch`; headed launches get the three background flags; unattended launches default headless. | — | `caption-exact`, `locked-browser` (natural lock), one fresh-worker transcript; goldens for prompt text need the maintainer (Taste/prompt) | M |
| **WP3** | **Carry the patched engine (RC4, D2).** Package 775a666 as a Tron-owned engine artifact through the existing patch builder and pin gate; add its owning replace test. | D2 | `web-replace` 3/3, `caption-exact` 20/20 on the shipped artifact | M |
| **WP4** | **Owned-browser lifecycle (RC7).** #2563.1–3 and #2629.1–2; F3 experiment first; #2574 load experiment. | — | `browser-fork-receipts.integration.test.ts` fail-before/pass-after; `owned-persistent-profile` 20/20 | M |
| **WP5** | **Verify selection for the pin (#2551).** Pin-only change selects `test-cua-assets.sh` and `test-verify-mac-install.py`. | — | `verify --plan` on a pin-only change | S |
| **WP6** | **Cua upgrade (RC2, D1).** Bench 0.33, v0.39 and v0.56.8 on isolated daemons (desktop); attribute #2482's remaining time; then pin the chosen release; admit `post_action_wait` where advertised (N3); regenerate help-projection checks. | WP0, WP1, WP5, D1 | `native-click/type` ≤ 0.5 s, `native-select` 3/3, `native-sheet` 3/3, new-window reporting kept; closes #2482/#2483/#2547/#2480c | L |
| **WP7** | **Persistent client (RC3 N2)**, only if WP6 still misses 0.5 s: one socket client per session instead of a process per call. | WP6 measurement | same rows | M |
| **WP8** | **Surfaces (RC6).** Home E2E observe+act through `computer`; standalone child-loadable `computer` provider (experiment first) wired via `subagentOnlyExtensions`; subagent browser from the pinned package, not the user git clone. | WP1 | `surface-*` rows; managed-child E2E (explicit child gets it, others do not) | L |
| **WP9** | **Lock avoidance (RC5 L1).** `no_console_session` cause; typed probe failure; hold the display assertion for the life of a task that declared desktop need, not only per turn (bounded, released on settle/Stop/kill). | D5 | `idle-lock-held` (physical, natural), assertion lifecycle integration test | M |
| **WP10** | **Locked use (L2), only if D3 = yes.** Developer ID cert; host install behind the native card; iPhone-approved lease (Gateway card → broker); maintainer-present run on 27.2. | D3, D4, WP9 | `unlock-and-relock`, `locked-native`, uninstall restores rule | L+ |
| **WP11** | **Close-out.** Full scorecard with one locked run; close the epic. | all chosen | §2 all rows | S |

Parallel lanes: WP0, WP1, WP2, WP4 and WP5 are independent, but each needs its own writer. WP2 and WP4 both
touch `tron.patch`, so serialize them. WP3 needs D2. WP6 needs WP0, WP1 and WP5. Nothing reaches users until
the maintainer rebuilds; plan one rebuild checkpoint after WP1–WP5 and one after WP6/WP8.

## 5. Decisions only Mohsin can make

| ID | Decision | Recommendation and why |
|---|---|---|
| D1 | Upgrade the Cua driver from 0.33.0, a prerelease, to a newer upstream release. | **Yes, target the latest (v0.56.8) after WP0 measures it against 0.33 and v0.39.** Four open items (#2482, #2483, #2480c, the #2547 residual) are fixed upstream, so patching 0.33 would duplicate upstream work. The pin path is already qualified (signature, digest). |
| D2 | Carry a Tron-patched agent-browser engine (local fix 775a666, no upstream PR, as you ruled). | **Yes.** It is the only fix for select-all and exact replace on macOS (upstream v0.43 still lacks it). Owned packaging already exists for the wrapper; this extends it to the engine with an exact pin. The alternative, a `fill` workaround, breaks keyboard-faithful editing. |
| D3 | Locked use: may Tron ever unlock the Mac (an iPhone-approved lease)? | **Not now.** CDP covers web work while locked (PROVEN). WP9 keeps an active task from being locked mid-work. L2 changes the system login path, needs a Developer ID certificate and sudo, and leaves the login keychain locked. Revisit only if a real native-app task is blocked by the lock after WP9. |
| D4 | Keep or remove the installed Codex Locked-use plug-in. It is a standing passwordless unlock path for OpenAI-signed code. | **Remove it unless you use ChatGPT Locked use.** It is an unused trust grant on the login path. Its own uninstaller restores the rule. |
| D5 | Hold the display-awake assertion for a whole desktop task, not only during a computer turn. | **Yes, bounded** (task settle, Stop, kill, and a maximum such as 2 h). The screen then stays unlocked and visible while an agent works and you are away. That is the cost; the benefit is no overnight stall like the Pinfold resume. |
| D6 | Prompt and brief copy: "web work never uses `computer`" and the owned-launch remedy text (WP2 goldens). | **Approve the rule.** Garbled X captions came from this exact routing. |

## 6. Open unknowns and the experiments that settle them

| Unknown | Experiment | Needs |
|---|---|---|
| Where #2482's remaining 1.5–3 s goes | WP6 matrix: window-watch off or on, AX vs pixel `type_text`, CLI vs socket, `sample` | unlocked Mac, isolated daemon |
| Exact X caption corruption | `caption-exact` fixture: foreground `type_text` with and without a prior unconfirmed paste, 20 runs | unlocked Mac, local fixture |
| "Chrome profile unopenable" | RC7 F3 experiment on a scratch persistent profile | none (owned Chrome) |
| Cua version on 2026-11-20 | `log show` for the cua-driver version banner | read-only |
| Whether a child can drive the Gateway's computer binding | Standalone provider via `subagentOnlyExtensions` in a test agent | none |
| Chromium background Cmd+A drop point | RC1 three-way matrix with a CDP selection oracle | unlocked Mac |
| #2469 cause and any lock-state link | Gateway-child vs Terminal: `CGSession`, `screencapture`, `pcblist_n` | read-only |
| #2574 aborted close | five-attach batch under recorded load | light |
| 0.33 sheet fix live | `native-sheet` row on an AppKit sheet fixture | unlocked Mac |
