import SwiftUI
import UIKit

/// Bound only the visible viewport. The original prompt stays available to
/// copy/annotation menus and the shared Markdown reader.
struct PromptTextPreview: View {
    let text: String
    var tone: UserPromptTextTone = .user
    @State private var fullHeight: CGFloat = 0 // view-local: measured text overflow
    @PresentationState private var showingFullText = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fonts = FontSettings.shared // view-local: selected reading font

    private var maximumHeight: CGFloat {
        let _ = fonts.selectedFamily
        let base = TronFontLoader.createUIFont(size: TronTypography.sizeBody * UserPromptTextLayoutPolicy.fontScale)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        return (font.lineHeight + 4) * CGFloat(TronLongContentPolicy.promptVisibleLines)
    }
    private var overflowing: Bool { fullHeight > maximumHeight + 1 }

    var body: some View {
        UserPromptText(text: text, tone: tone)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            .frame(maxHeight: maximumHeight, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if overflowing {
                    ChatBottomActivityBlur(isActive: true)
                        .frame(height: 52)
                        .clipped()
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { showingFullText = true }, including: overflowing ? .all : .none)
            .accessibilityAddTraits(overflowing ? .isButton : [])
            .accessibilityHint(overflowing ? "Shows the full prompt" : "")
            .tronManagedSheet(isPresented: $showingFullText, identity: "chat.prompt.full-text") {
                HomeTextReader(reading: HomeTextReading(id: "prompt", title: "Prompt", text: text))
                    .tronSettingsVisualTheme(accent: .tronEmerald)
            }
    }
}
