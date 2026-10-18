import SwiftUI
import UIKit

/// Bound only the visible viewport. The original prompt stays available to
/// copy/annotation menus and the shared Markdown reader.
struct PromptTextPreview: View {
    let text: String
    var tone: UserPromptTextTone = .user
    @State private var fullHeight: CGFloat = 0 // view-local: measured text overflow
    @Environment(\.chatTranscriptSheetRoutes) private var sheetRoutes
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fonts = FontSettings.shared // view-local: selected reading font

    private var maximumHeight: CGFloat {
        let _ = (fonts.selectedFamily, dynamicTypeSize)
        let base = TronFontLoader.createUIFont(size: TronTypography.sizeBody * UserPromptTextLayoutPolicy.fontScale)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        return (font.lineHeight + 4) * CGFloat(TronLongContentPolicy.promptVisibleLines)
    }
    private var overflowing: Bool { fullHeight > maximumHeight + 1 }
    private var canOpen: Bool { overflowing && sheetRoutes != nil }

    var body: some View {
        UserPromptText(text: text, tone: tone)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            .frame(maxHeight: maximumHeight, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if overflowing {
                    ChatBottomActivityBlur(isActive: true, height: 52, includesBackgroundTint: false)
                        .clipped()
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded {
                guard canOpen else { return }
                sheetRoutes?.present(.prompt(HomeTextReading(id: UUID().uuidString, title: "Prompt", text: text)))
            }, including: canOpen ? .all : .none)
            .accessibilityAddTraits(canOpen ? .isButton : [])
            .accessibilityHint(canOpen ? "Shows the full prompt" : "")
    }
}
