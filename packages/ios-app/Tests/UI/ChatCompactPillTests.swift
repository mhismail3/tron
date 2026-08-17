import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Chat compact pill and prompt typography")
struct ChatCompactPillTests {
    @Test("prompt lines use logical leading alignment inside a right-anchored bound")
    func promptAlignment() {
        #expect(UserPromptTextLayoutPolicy.alignment(layoutDirection: .leftToRight) == .left)
        #expect(UserPromptTextLayoutPolicy.alignment(layoutDirection: .rightToLeft) == .right)
    }

    @Test("prompt bound, response-matched type scale, and glass geometry are explicit")
    func promptGeometry() {
        #expect(UserPromptTextLayoutPolicy.maximumWidth == 364)
        #expect(UserPromptTextLayoutPolicy.fontScale == 1)
        #expect(ChatPromptContainerStyle.cornerRadius == 18)
        #expect(ChatPromptContainerStyle.horizontalPadding == 12)
        #expect(ChatPromptContainerStyle.topPadding == 8)
        #expect(ChatPromptContainerStyle.userPromptBottomPadding == 8)
        #expect(ChatPromptContainerStyle.queuedMessageBottomPadding == 12)
        #expect(ChatPromptContainerStyle.tintOpacity == 0.16)
    }

    @Test("short prompts keep their intrinsic width while long prompts stop at the bound")
    func promptFittedWidth() {
        #expect(UserPromptTextLayoutPolicy.fittedWidth(measured: 96, proposed: 364) == 96)
        #expect(UserPromptTextLayoutPolicy.fittedWidth(measured: 520, proposed: 364) == 364)
    }

    @Test("bottom activity blur follows keyboard focus without changing layout")
    func bottomActivityBlurGeometry() {
        #expect(ChatBottomActivityBlurLayout.height(keyboardVisible: false) == 68)
        #expect(ChatBottomActivityBlurLayout.translation(keyboardVisible: false) == 44)
        #expect(ChatBottomActivityBlurLayout.height(keyboardVisible: true) == 80)
        #expect(ChatBottomActivityBlurLayout.translation(keyboardVisible: true) == 24)
        #expect(
            ChatBottomActivityBlurLayout.height(keyboardVisible: true)
                - ChatBottomActivityBlurLayout.translation(keyboardVisible: true)
                == 56
        )
    }

    @Test("compact transcript pills retain pre-shared vertical rhythm")
    func compactPillGeometry() {
        #expect(ChatCompactPillLayoutPolicy.horizontalPadding == 11)
        #expect(ChatCompactPillLayoutPolicy.verticalPadding == 6)
        #expect(ChatCompactPillLayoutPolicy.itemSpacing == 7)
        #expect(ChatCompactPillLayoutPolicy.standardIconSize == 10)
        #expect(ChatCompactPillLayoutPolicy.toolIconSize == 11)
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
