#if HOSTED_TEST
import SwiftUI

struct HostedSessionPaginationFixture: View {
    @State private var count = 10
    @State private var header = DashboardHeaderState()

    var body: some View {
        DashboardChrome(header: header, onOpenAutomations: {}, onOpenApps: {},
                        actions: .init(settings: {}, creation: [])) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<count, id: \.self) { index in
                        Text("Session \(index + 1)")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 14)
                            .tronScrollSurface(accent: .tronEmerald)
                    }
                    SessionListExpansionControls(workspaceName: "Example workspace",
                        canShowLess: count > 10, canShowMore: count < 30, isEnabled: true,
                        onShowLess: { count = 10 }, onShowMore: { count += 10 })
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .tronDashboardScroll(header)
        }
        .tronPresentation()
    }
}
#endif
