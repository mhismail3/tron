# Builds

`Builds.swift` is a real interpreted SwiftUI mini-app, installed through
Tron's reviewed Apps flow. It reads the declared `ios-builds` feed, not the
network. The existing static Builds page/publisher on `:8443` is unchanged.

From a trusted repository session, ask Tron to offer
`tools/web/apps/builds/Builds.swift` as app id `builds`, with
`feeds: ["ios-builds"]`. On iPhone, enable the existing **Run Swift files**
experiment, open the inline card, review exact source/hash, target and access,
then choose **Install App**. No offer is an installation by itself.

Apps → Builds opens fresh committed publisher metadata from that Gateway's home.
Search/mode persist in the app's Mac-side SQLite state. Pull the actual List
down to refresh after publication. Open a build for full metadata/notes;
**Install Build** hands its exact admitted manifest to iOS only after that
explicit action. iOS owns its confirmation and outcome.

An offered source update preserves data/instance identity after fresh review.
A v1 app requires the explicit backed-up v2-upgrade toggle. Manage supports the
existing confirmed rename, clear data and removal; full history browsing and HTML
apps are separate scope.

The [Gateway contract](../../../../packages/gateway/docs/swift-apps.md) defines
feeds, versions, backups and receipts. The
[iPhone runner](../../../../packages/ios-app/docs/swift-apps.md) defines execution
and link boundaries. Real-Gateway `testBuildsInstallLight/Dark/LightXXXL/DarkXXXL`
journeys copy these exact bytes and synthetic publisher records; they never tap
Install Build, contact a production Gateway or prove physical-device installation.
