# Tron unlock lease: guest prototype (#2476, L2)

Prototype of a general-purpose, Tron-owned screen-unlock path, run only inside a Tart macOS guest.
Host untouched: no host authorizationdb, SecurityAgentPlugins, sudo, TCC or lock change.

## Parts

- `plugin/TronUnlock.c`: SecurityAgent mechanism `TronUnlock:allow`. It allows only after an exact
  `ALLOW\n` from a verified broker within 1 s, on a helper queue with a semaphore deadline. It checks
  that the parent is root-owned and that the run dir and socket are not group/other-writable. It
  checks `getpeereid` against the dir owner, then the audit-token code requirement (compiled in;
  ad-hoc cdhash in the guest, Developer ID team + identifier on a host). Every other path is Deny,
  so `use-login-window-ui` (k-of-n 1) keeps the password screen.
- `broker/main.swift`: Tron-side LaunchAgent. It serves the plug-in socket and a 0600 control socket.
  The approval seam is `ApprovalSource`. `LocalStubApproval` stands in for the iPhone tap, and the
  control `APPROVE` simulates the tap. Each approval is one-shot, lives 30 s, gives a lease of
  1–600 s, and is refused while a lease is active. When a lease starts, the broker shows a shield on
  every display, arms a HID event tap, and writes a lease marker. It relocks with
  `SACLockScreenImmediate` on physical input, expiry, Stop or SIGTERM, and verifies the screen is
  locked, retrying until it is. A stale marker at start causes a relock (SIGKILL case). Fault hooks
  exist only with `-D FAULTS`.
- `guest/install.sh install|uninstall`: refuses to run outside a VM. It backs up
  `system.login.screensaver` (lint-validated) and writes the rule last, after the broker is healthy.
  An ERR trap restores the backup. Uninstall restores the rule, then removes the right, the bundle,
  the broker, the TCC row and the run dir.

## Rows (guest macOS 26.6.2 25G83, Tart 2.42.0, 2026-11-20)

| Row | Result |
| --- | --- |
| allow | approve → key at lock screen → `verdict=allow` 2 ms, `screenLocked:false`, shield visible |
| deny, no approval | `verdict=deny`, password screen stays |
| replay (no fresh approval) | `verdict=deny` |
| double approve while active | `ERR` |
| hang (broker sleeps 5 s) | `verdict=timeout ms=1001`, Deny |
| garbage reply `ALLOWX` | `verdict=deny` |
| broker crash (abort mid-request) | `verdict=closed`, Deny; KeepAlive restarts it |
| impostor socket answering ALLOW | `validity=-2147409622` → `verdict=signature`, Deny |
| broker absent | `verdict=path`, Deny |
| physical input relock | mouse move → `relock reason=physical-input` 1–88 ms |
| expiry / Stop / SIGTERM relock | relocked, 66–79 ms |
| SIGKILL during lease | stale marker → relocked 0.12 s after kill |
| password fallback while installed | typed password unlocks (Deny then `use-login-window-ui`) |
| uninstall | rule `[use-login-window-ui]` (identical except timestamp); right, bundle, run dir, agent, TCC row gone; password unlock works |

Keychain after a lease unlock: loginwindow treats a plug-in Allow as `Unlock succeeded, with
password` and calls `SecKeychainLogin` with no real password. If the login keychain is locked, it
stays locked (`SecKeychainLogin failed: -2147413984`; `SecKeychainGetStatus` unlocked=false). If it
was already unlocked, it stays unlocked. With a test keychain the SecKeychainLogin call returned 0,
and that behaviour was not separated from a keychain already open. Treat the result as "the lease
never unlocks a locked keychain".

## Bringing it to the host (needs A3 + A4; not done)

1. A3: create a Developer ID Application certificate on team MYGKXH6TY4. Sign the bundle with
   hardened runtime and the broker with identifier `com.tron.unlock.broker`. Compile the requirement
   `anchor apple generic and certificate leaf[subject.OU] = "MYGKXH6TY4" and identifier "com.tron.unlock.broker"`.
   Notarize both.
2. A4 (sudo, behind the native card): `security authorizationdb read system.login.screensaver > backup`
   (today `[com.openai.sky.CUAService.AuthorizationPlugin.remote, use-login-window-ui]`, k-of-n 1). Then
   install the bundle to `/Library/Security/SecurityAgentPlugins/` (root:wheel), create the root-owned
   `/Library/Application Support/Tron` and the user-owned `run/`, and write the `com.tron.unlock` right.
   Insert `com.tron.unlock` into the existing rule array, keeping Codex's entry, since A6 left it
   unchanged. Grant Input Monitoring to the broker through the normal TCC prompt, not a TCC.db write.
3. Replace `LocalStubApproval` with a Gateway approval card → Native Host broker (P10), then run the
   rows on the console in a maintainer-present window.
4. Undo: `sudo security authorizationdb write system.login.screensaver < backup`,
   `sudo security authorizationdb remove com.tron.unlock`, and remove the bundle, run dir and agent.
