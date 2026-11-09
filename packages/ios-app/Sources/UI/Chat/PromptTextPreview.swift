import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The delivery state a prompt bubble reports to accessibility as its
    /// value: "Sending" or "Queued" from the row that owns that state, none
    /// once the message is sent.
    @Entry var chatMessageDeliveryState: String?
}

/// Bound only the visible viewport. The original prompt stays available to
/// copy/annotation menus and the shared Markdown reader.
struct PromptTextPreview: View {
    let text: String
    var tone: UserPromptTextTone = .user
    var onOpen: (() -> Void)?
    @State private var fullHeight: CGFloat = 0 // view-local: measured text overflow
    @Environment(\.chatTranscriptSheetRoutes) private var sheetRoutes
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatMessageDeliveryState) private var deliveryState
    @State private var fonts = FontSettings.shared // view-local: selected reading font

    private var maximumHeight: CGFloat {
        let _ = (fonts.selectedFamily, dynamicTypeSize)
        let base = TronFontLoader.createUIFont(size: TronTypography.sizeBody * UserPromptTextLayoutPolicy.fontScale)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        return (font.lineHeight + 4) * CGFloat(TronLongContentPolicy.promptVisibleLines)
    }
    private var overflowing: Bool { fullHeight > maximumHeight + 1 }
    private var canOpen: Bool { overflowing && (onOpen != nil || sheetRoutes != nil) }

    var body: some View {
        UserPromptText(text: text, tone: tone)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            .frame(maxHeight: maximumHeight, alignment: .top)
            .clipped()
            // Fade only the prompt's ink. A backdrop blur samples the glass
            // behind it and creates a second, inset rectangular surface.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    if overflowing {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 52)
                    }
                }
            }
            // One element: the message's text and its delivery state. The
            // copy menu hosts this view in a nested UIHostingController whose
            // UIKit label was exposed to accessibility only in some launches.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityValue(deliveryState ?? "")
            .accessibilityAddTraits(.isStaticText)
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded {
                guard canOpen else { return }
                if let onOpen { onOpen() }
                else { sheetRoutes?.present(.prompt(HomeTextReading(id: UUID().uuidString, title: "Prompt", text: text))) }
            }, including: canOpen ? .all : .none)
            .accessibilityAddTraits(canOpen ? .isButton : [])
            .accessibilityHint(canOpen ? (onOpen == nil ? "Shows the full prompt" : "Opens the full text") : "")
    }
}
