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
