#if HOSTED_TEST
import SwiftUI

/// Deterministic, test-only host for the rendered general extension-content
/// sheet. It supplies bounded retained content of all three kinds — a string
/// widget, a retained read-only component frame, and a retained status — so the
/// real sheet can be verified as rendered native layout rather than merely
/// admitted state.
@MainActor
struct HostedExtensionWidgetsFixtureView: View {
    @State private var presented = true

    var body: some View {
        TronPresentationSurface(id: "hosted-extension-widgets-fixture") {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("Extension widgets fixture")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    Text("Fixture only. No Gateway connection is used.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("extension-widgets-fixture-root")
            }
            .tronManagedSheet(
                isPresented: $presented,
                identity: "hosted.extension-widgets"
            ) {
                ExtensionWidgetsSheet(
                    content: ExtensionRetainedContentPolicy.content(
                        widgets: Self.widgets,
                        surfaces: Self.surfaces,
                        statuses: Self.statuses,
                        statusOwners: Self.statusOwners
                    ),
                    omittedContentCount: 1
                )
            }
        }
    }

    private static let widgets: [ExtensionWidget] = [
        ExtensionWidget(
            key: "goal",
            revision: 3,
            lines: ["Goal active", "Used 12k tokens"],
            placement: .belowEditor,
            owner: ExtensionOwner(id: "fixture-goal", title: "Goal", source: "npm:@mocito/pi-goal")
        )
    ]

    // One owned status (the real paused-goal shape) and one unowned status, so the
    // rendered sheet covers status rendering and unknown-producer grouping.
    private static let statuses: [String: String] = [
        "pi-goal": "Goal paused (/goal resume)",
        "unowned-status": "2 background tasks running",
    ]

    private static let statusOwners: [String: ExtensionOwner] = [
        "pi-goal": ExtensionOwner(id: "fixture-goal", title: "Goal", source: "npm:@mocito/pi-goal")
    ]

    private static let surfaces: [ExtensionSurface] = [
        ExtensionSurface(
            id: "widget:fixture-frame",
            kind: .widget,
            placement: .fullscreen,
            lifecycle: .retained,
            targetId: nil,
            provenance: .init(source: "npm:fixture-extension", path: nil),
            revision: 1,
            focused: false,
            inputMode: .none,
            frame: ExtensionFrame(
                width: 32,
                height: 1,
                lines: [ExtensionFrameLine(
                    plainText: "Frame progress 3 of 5",
                    runs: [
                        ExtensionFrameRun(text: "Frame progress ", style: ExtensionFrameStyle(bold: true)),
                        ExtensionFrameRun(text: "3 of 5", style: ExtensionFrameStyle())
                    ]
                )],
                plainText: "Frame progress 3 of 5"
            )
        )
    ]
}
#endif
