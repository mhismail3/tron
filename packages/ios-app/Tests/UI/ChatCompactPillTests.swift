import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Chat compact pill and prompt typography")
struct ChatCompactPillTests {
    @Test("single visual line stays trailing while multiline text justifies")
    func promptAlignment() {
        #expect(UserPromptTextLayoutPolicy.alignment(
            text: "Short prompt",
            measuredSingleLineWidth: 80,
            availableWidth: 220,
            layoutDirection: .leftToRight
        ) == .right)
        #expect(UserPromptTextLayoutPolicy.alignment(
            text: "Short prompt",
            measuredSingleLineWidth: 80,
            availableWidth: 220,
            layoutDirection: .rightToLeft
        ) == .left)
        #expect(UserPromptTextLayoutPolicy.alignment(
            text: "A long prompt that wraps",
            measuredSingleLineWidth: 360,
            availableWidth: 220,
            layoutDirection: .leftToRight
        ) == .justified)
        #expect(UserPromptTextLayoutPolicy.alignment(
            text: "Explicit\nline",
            measuredSingleLineWidth: 50,
            availableWidth: 220,
            layoutDirection: .rightToLeft
        ) == .justified)
    }

    @Test("right-side prompt separation remains explicit")
    func promptInset() {
        #expect(UserPromptTextLayoutPolicy.leadingInset == 28)
    }

    @Test("compact transcript pills retain pre-shared vertical rhythm")
    func compactPillGeometry() {
        #expect(ChatCompactPillLayoutPolicy.horizontalPadding == 11)
        #expect(ChatCompactPillLayoutPolicy.verticalPadding == 6)
        #expect(ChatCompactPillLayoutPolicy.itemSpacing == 7)
    }

    @Test("small warning and neutral text keeps accessible contrast")
    @MainActor func compactToneContrast() {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightBackground = UIColor(hex: "#F7F8FA")
        let darkBackground = UIColor(hex: "#090A0C")

        for tone in [ChatNotificationTone.warning, .neutral] {
            for color in [tone.primaryColor, tone.secondaryColor] {
                #expect(contrastRatio(
                    UIColor(color).resolvedColor(with: lightTraits),
                    lightBackground
                ) >= 4.5)
                #expect(contrastRatio(
                    UIColor(color).resolvedColor(with: darkTraits),
                    darkBackground
                ) >= 4.5)
            }
        }
    }

    @Test("notification material exposes details only through glass buttons")
    func notificationDetailPolicy() {
        let flat = ChatNotificationPresentation(
            id: "flat", semanticID: nil, icon: "info.circle", title: "Status",
            detail: nil, body: nil, tone: .information, material: .flat
        )
        let glass = ChatNotificationPresentation(
            id: "glass", semanticID: "entry", icon: "arrow.triangle.branch",
            title: "Branch summary", detail: nil, body: "Summary",
            tone: .accent, material: .glass
        )
        let emptyGlass = ChatNotificationPresentation(
            id: "empty", semanticID: nil, icon: "info.circle", title: "Empty",
            detail: nil, body: nil, tone: .accent, material: .glass
        )

        #expect(!flat.hasDetailSheet)
        #expect(glass.hasDetailSheet)
        #expect(!emptyGlass.hasDetailSheet)
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
