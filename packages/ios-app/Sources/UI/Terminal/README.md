# Terminal

## Purpose

Mac Terminal reaches macOS built-in Remote Login over Tailscale. One stable tmux
session preserves the same shell across dismissal, backgrounding and reconnect;
neither Tron.app nor the Gateway owns its process or connection.

## Owns

`MacTerminalSheet`, `TerminalSheetChrome`, `TerminalSurface` and `TerminalRenderer`
(SwiftTerm). State and enrollment belong to `MacTerminalController` and
`MacTerminalEnrollmentStore`; SSH transport belongs to `MacTerminalSSH`.

## Contract

- Settings › System › **Mac Terminal** is the only entry point. The Gateway is
  needed only to enroll or revoke this iPhone's key, not to reconnect.
- The physical iPhone uses a non-exportable Secure Enclave P-256 key with
  `AfterFirstUnlockThisDeviceOnly`; only the Simulator uses a software key.
  Enrollment pins host keys; they are never silently replaced.
- The client accepts numeric Tailscale IPv4/IPv6 destinations, validates the
  endpoint/session name and verifies a pinned host key before authentication.
  Unreachable Mac, refused key and changed host key have distinct errors.
- An SSH PTY executes tmux `new-session -A` on the dedicated `tron-mobile`
  socket, without loading user tmux configuration. The stable session name is
  derived from the Mac/device IDs. Missing tmux is an explicit setup error;
  there is no plain-shell fallback or custom shell-host protocol.
- Done/background closes the SSH attachment, not the tmux shell. Foreground or
  **Reconnect** opens a new attachment and uses tmux's authoritative repaint.
  Input is never replayed. Shell exit ends that shell; reconnect starts another.
- Each connection is generation-fenced. Output retained by the controller is
  bounded to 1 MiB; the SSH event stream is bounded and disconnects rather than
  silently continuing an emulator after lost bytes.
- Keyboard, emulator and alerts are presentation-scoped. Within an attachment,
  a rebuilt sheet adopts the same emulator; a new attachment gets a fresh one.
  SwiftTerm reads the active screen, including tmux's alternate screen.
- A one-time forward migration removes only the obsolete endpoint `hostCommand`
  property from `macTerminal.enrollments.v1`. It copies every surviving byte,
  completes and verifies an original-record backup before the rewrite, then marks
  completion. A failed backup blocks reads/mutations without touching keys or
  pins. Subsequent launches do not repeat the migration.
- Removal revokes the authorized key on the Mac before deleting local enrollment.
  Already-running tmux shells are not terminated by key removal.
- The maintainer owns Remote Login and the selected PF exposure policy. Client
  address checks and authorized-key source restrictions do not prove a server
  firewall boundary or fail-closed boot behavior.

## Verify

```bash
scripts/tron-ios-test build
scripts/ios-mac-terminal-journey
scripts/tron test gateway --config vitest.mac-terminal.config.ts
```

The journey uses real sshd and the app's SSH client. Physical-device Secure
Enclave, radio interruption, and privileged PF/reboot/rollback remain separate
qualification boundaries; simulator screenshots are not device proof.
