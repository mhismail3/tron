# Tron for iPhone

The native SwiftUI client is Tron's primary interface. It pairs with the
always-running Tron agent on a Mac over Tailscale and the authenticated Tron
Gateway protocol.

It owns presentation, local caches and device credentials in the Keychain. It
does not own sessions, settings or provider credentials: those stay canonical on
the Mac, and every cache here is a bounded projection of them.

See:

- [Architecture](docs/architecture.md)
- [Development and focused tests](docs/development.md)
- [Onboarding](docs/onboarding.md)
- [Gateway event policy](docs/events.md)
- [iOS architecture](docs/architecture.md)
- [iOS events and state delivery](docs/events.md)

Generate the project with `scripts/tron ios generate` from the repository root;
it resolves the pinned XcodeGen and keeps `project.yml` as project truth. Run
hosted tests only through `scripts/tron-ios-test`; see the development guide. Provider secrets remain on the Mac, mobile tokens remain in
Keychain, and local snapshots are disposable offline presentation state.

## Signals

Rows of the repository's iOS test tooling (`scripts/`, module `repo/ios`), kept here until it
has a README.

| Signal | Level | Meaning |
|---|---|---|
| `Build resources: <N> jobs, nice <priority>, no queue (pid <PID>)` | Apple build log | `scripts/tron-xcodebuild` names its per-build compiler bound and inherited CPU priority; missing on a source build means the caller bypassed the shared build owner ([resource ownership](docs/development.md#parallel-worker-resource-ownership)) |
| `owned fault proxy exited (<exit code\|signal>)` | command stderr | `scripts/ios-gateway-e2e-test`'s fault proxy exited before readiness; its wait status and the last 20 lines of `proxy.log` |
| `results/<utc>-run.XXXXXX/proxy-link-stats.json` (`clientHeartbeatTimeline`) and `phone-liveness-records.jsonl`, written for every focused boundary case | E2E artifacts | Read a `possibly_sent` or `pong_timeout` from one directory: each proxy ping's `enqueuedAt`, `gatewayPongAt` (absent when the Gateway never answered), `roundTripMs`, `appPongForwardedAt`, and each phone record's probe and last-inbound times. No `gatewayPongAt` means the Gateway or link did not answer; an answered ping with the phone still retiring means the phone stalled |
