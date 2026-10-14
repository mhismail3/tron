#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Hosted journey for the session row's relative-time label. It renders the
/// real `HistoricalSessionRow` for one long-titled in-progress session at a
/// gateway clock slightly ahead of the phone, just now, and seconds and minutes
/// ago, plus the real `SessionRowRelativeTime` label that a button steps
/// through ticking values, so the journey can read its laid-out width.
struct HostedSessionRowClockFixture: View {
    private static let title = "Refactor the gateway reconnect handshake so phones resume cleanly"
    /// Seconds relative to launch; positive is a gateway clock ahead of the phone.
    private static let rowOffsets: [TimeInterval] = [3, 0, -12, -47 * 60]
    private static let probeOffsets: [TimeInterval] = [2, 0, -1, -5, -59, -60, -12 * 60, -3 * 3_600]

    @State private var launchedAt = Date()
    @State private var probeIndex = 0

    var body: some View {
        List {
            Section {
                ForEach(Self.rowOffsets, id: \.self) { offset in
                    HistoricalSessionRow(session: session(offset: offset), activity: .active, showsContext: false)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(SessionDashboardLayout.rowInsets)
                }
            } header: {
                Text("In Progress")
                    .font(TronTypography.code(size: TronTypography.sizeBodyLG, weight: .bold))
                    .foregroundStyle(Color.tronEmerald)
                    .textCase(nil)
                    .listRowInsets(SessionDashboardLayout.headerInsets)
            }
            Section {
                HStack {
                    Button("Next label") { probeIndex = (probeIndex + 1) % Self.probeOffsets.count }
                        .accessibilityIdentifier("row-clock-next")
                    Spacer()
                    SessionRowRelativeTime(text: probeLabel, isWaiting: false)
                        .accessibilityIdentifier("row-clock-label")
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.tronBackground)
        // A covered branch renders each label once instead of running the row
        // clock, which would keep XCUI from ever observing quiescence.
        .environment(\.tronPresentationActivity, .covered)
    }

    private var probeLabel: String {
        GatewayTimestamp.relativeDescription(launchedAt.addingTimeInterval(Self.probeOffsets[probeIndex]), relativeTo: launchedAt)
    }

    private func session(offset: TimeInterval) -> SessionSummary {
        SessionSummary(
            id: "row-clock-\(Int(offset))",
            name: Self.title,
            cwd: "/workspace/fixture-project",
            parentSessionId: nil,
            createdAt: GatewayTimestamp.string(from: launchedAt.addingTimeInterval(-3_600)),
            updatedAt: GatewayTimestamp.preciseString(from: launchedAt.addingTimeInterval(offset)),
            messageCount: 4,
            firstMessage: Self.title,
            phase: .running,
            archivedAt: nil,
            gatewayProfileID: "fixture",
            gatewayProfileLabel: "Fixture Mac"
        )
    }
}
#endif
