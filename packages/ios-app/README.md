# Tron for iPhone

The native SwiftUI client is Tron's primary interface. It pairs with the
always-running Tron agent on a Mac over Tailscale and the authenticated Tron
Gateway protocol.

See:

- [Architecture](docs/architecture.md)
- [Development and focused tests](docs/development.md)
- [Onboarding](docs/onboarding.md)
- [Gateway event policy](docs/events.md)
- [iOS hardening plan](docs/hardening-plan.md)

Generate the project with `scripts/tron ios generate` from the repository root;
it resolves the pinned XcodeGen and keeps `project.yml` as project truth. Run
hosted tests only through `scripts/tron-ios-test`; see the development guide. Provider secrets remain on the Mac, mobile tokens remain in
Keychain, and local snapshots are disposable offline presentation state.
