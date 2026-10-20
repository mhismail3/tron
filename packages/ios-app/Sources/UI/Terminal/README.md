# Terminal

## Purpose

Terminal sheets: the session terminal over a Gateway-retained PTY, and Mac Terminal, which reaches
login shells on the paired Mac over SSH without the Gateway.

## Owns

`TerminalSheet`, `MacTerminalSheet`, `TerminalPresentationController`, `TerminalRenderer`
(SwiftTerm), and the shared `TerminalSheetChrome`/`TerminalSurface` chrome both sheets use.

## Contract

- **Session terminal.** `TerminalCoordinator` and its `TerminalReducer` (State) own wire, intents,
  shared attachment leases and a global 16-terminal / 256-chunk / 1 MiB event quarantine.
  `terminal.open` requires the exact installed session subscription. Open and attach install one
  strictly contiguous replay; duplicates, reordering or a missing middle trigger a bounded
  follow-up. A reset advances the replay revision so SwiftTerm is recreated. Resize is debounced
  120 ms per presentation within 20–400 columns and 5–200 rows.
- **Presentation.** The controller owns one active start/show/open flight and one latest pending
  route; possibly-sent attach/open phases finish under their revoked intent so stale receipts reach
  compensating cleanup. Switching or dismissing revokes intake synchronously; presentations sharing
  a terminal keep the subscription until the last closes. After exit the emulator is
  non-interactive with a steady cursor, and menus separate live from exited terminals. Quit asks
  for confirmation and waits for Gateway-observed process-group exit; Done only detaches.
- **Closed by the Gateway.** An idle or restart-closed terminal (#479) carries
  `TerminalSummary.closedReason`, shown as its Recent terminals subtitle and the replay's last line;
  the idle period is the Gateway's `setup.terminalIdleMinutes` setting.
- **Mac Terminal.** Settings › System › **Mac Terminal**. Only enrollment and removal
  use the Gateway ([contract](../../../../gateway/README.md#mac-terminal)), so shells work while
  Tron.app or the Gateway is down.
  - *Key:* `MacTerminalEnrollmentStore` keeps one Secure Enclave P-256 key per Mac
    (`AfterFirstUnlockThisDeviceOnly`); the Simulator uses a software key.
  - *Enrollment:* reads `macTerminal.status`, sends the public key as
    `permissions.macTerminalKey[device]` through `settings.change`, and pins host keys, which are
    never replaced silently.
  - *Shells live on the Mac* (#1075): `MacTerminalHostLink` speaks the host's line protocol;
    closing the sheet only closes the link. `AppModel.macTerminal` is app-scoped, so a reopened
    sheet shows retained output (≤ 1 MiB) and reattaches after the last sequence. ⋯ › New Shell
    opens another; Open and Recent shells are shared by every enrolled iPhone of that Mac user.
  - *Connection* (`MacTerminalSSH`) refuses specifically: no Tailscale address, Mac unreachable,
    Remote Login off, unpinned host key (with its `SHA256:` fingerprint), refused key, stalled
    handshake. A dropped link says the shell still runs and reattaches on foreground.
  - *Lifeline:* without a host command the terminal opens a plain PTY login shell that ends with
    its connection. *Removal* unsets the key on the Mac first.
- Keyboard, emulator and alerts are presentation-scoped; only dismissal detaches
  ([presentation-scoped state](../../../docs/presentation-parity.md#presentation-scoped-state)).

## Invariants

- No second terminal lifecycle: Home's terminal button reuses `TerminalSheet(sessionID:)` and
  requires `terminal.v1`.
- Output is never replayed into a rebuilt sheet; `TerminalEmulatorHost` keeps the SwiftTerm view.

## Entry points

`TerminalSheet.swift`, `MacTerminalSheet.swift`, `TerminalPresentationController.swift`.

## Signals

None of its own.

## Verify

```bash
scripts/tron-ios-test run --only-testing TronMobileUITests/TronSessionTerminalUITests
scripts/ios-mac-terminal-journey   # TronMacTerminalUITests against real sshd; after build, Mac on its tailnet
scripts/tron test gateway --config vitest.mac-terminal.config.ts
```

Interactive PTY input, the native keyboard and the shortcut surfaces remain a device check.

## Not here

Terminal state owners: [State](../../State/README.md). The SSH client: `MacTerminalSSH`.
