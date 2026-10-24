#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Real Home summary beside an independent code-style reference. Both receive
/// the same available text width so XCUI can compare glyph advances and line
/// metrics, including wrapping, without a font-name diagnostic or golden.
struct HostedHomeSummaryTypographyFixture: View {
    private let cardWidth: CGFloat = 370
    private var textWidth: CGFloat {
        cardWidth - 2 * TronSpacing.xxl - TronSpacing.xlarge - TronSpacing.xl
    }

    var body: some View {
        VStack(spacing: 30) {
            HomeContextSummaryCard(snapshot: SessionContextPresentation(Self.snapshot), read: Self.read)
                .frame(width: cardWidth)
            Text(Self.reference)
                .font(SessionSummaryTypography.usageValue)
                .foregroundStyle(Color.tronTextSecondary)
                .accessibilityIdentifier("home-stats-code-reference")
                .frame(maxWidth: textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tronBackground)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("-home-stats-large-type") ? .xxxLarge : .large)
    }

    private static var reference: String {
        let usage = SessionContextUsagePresentation(snapshot.contextUsage).usedSummary ?? ""
        return "\(usage) · 1.8M\u{00A0}total\u{00A0}tokens · 91.4%\u{00A0}cache\u{00A0}hit"
    }

    private static var read: HomeManageDTO {
        let status = try! JSONDecoder.gateway.decode(HomeStatusDTO.self, from: Data(#"""
        {"phase":"ready","available":true,"enabled":true,"sessionPresent":true,
         "hostPressure":{"level":"normal"},"workers":{"running":0},
         "activation":{"available":false},"readiness":{"gaps":[]},"recovery":{},
         "memory":{"configured":true,"open":true}}
        """#.utf8))
        return HomeManageDTO(status: status, context: HomeContextDTO(activation: status.activation, breakdown: nil),
                             chapters: nil, tasks: nil, permissions: nil)
    }

    private static var snapshot: SessionSnapshot {
        SessionSnapshot(
            sessionId: "home-typography", runtimeGeneration: "fixture", revision: 1, eventSequence: 1,
            phase: .idle, name: nil, cwd: "/fixture", parentSessionId: nil, model: nil,
            thinkingLevel: "off", availableThinkingLevels: [],
            contextUsage: try! JSONDecoder.gateway.decode(ContextUsage.self, from: Data(
                #"{"tokens":30800,"contextWindow":1000000,"percent":3.08}"#.utf8)),
            stats: SessionStats(userMessages: 6, assistantMessages: 6, toolCalls: 4, toolResults: 4, totalMessages: 12,
                tokens: .init(input: 412_000, output: 38_000, cacheRead: 1_230_000, cacheWrite: 96_000, total: 1_776_000),
                latestCacheHitRate: 91.4, cost: 9.37),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true,
            transcript: [], transcriptStart: 0, transcriptTotal: 0, streaming: nil, leafEntryId: nil,
            operation: nil, retry: nil, toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "fixture", revision: 1,
                capabilities: [], diagnostics: [], semanticState: .init(statuses: [:],
                    working: .init(message: nil, visible: false), hiddenThinkingLabel: nil,
                    widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: []), diagnostics: [])
    }
}
#endif
