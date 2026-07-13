import Foundation
import Testing
@testable import TronMobile

@Suite("Context Briefing Button")
struct ContextBriefingButtonTests {
    @Test("Context ring fills in direct proportion to bounded usage")
    @MainActor
    func testProgressFractionClampsAndScalesPercentage() {
        #expect(ContextBriefingButton.boundedPercentage(for: -1) == 0)
        #expect(ContextBriefingButton.boundedPercentage(for: 140) == 100)
        #expect(ContextBriefingButton.progressFraction(for: -1) == 0)
        #expect(ContextBriefingButton.progressFraction(for: 8) == 0.08)
        #expect(ContextBriefingButton.progressFraction(for: 50) == 0.5)
        #expect(ContextBriefingButton.progressFraction(for: 100) == 1)
        #expect(ContextBriefingButton.progressFraction(for: 140) == 1)
    }

    @Test("Context ring yields its slot for the complete voice lifecycle")
    func testContextRingVisibilityUsesRecordingAndTranscriptionState() {
        #expect(InputBarConfig().showsContextBriefingControl)
        #expect(!InputBarConfig(isRecording: true).showsContextBriefingControl)
        #expect(!InputBarConfig(isTranscribing: true).showsContextBriefingControl)
        #expect(!InputBarConfig(isRecording: true, isTranscribing: true).showsContextBriefingControl)
    }

    @Test("Voice lifecycle owns the trailing action even with a nonempty draft")
    func testVoiceLifecycleBlocksDraftSubmission() {
        #expect(InputBarConfig().canSend(hasContent: true))
        #expect(!InputBarConfig(isRecording: true).canSend(hasContent: true))
        #expect(!InputBarConfig(isTranscribing: true).canSend(hasContent: true))
        #expect(!InputBarConfig(isRecording: true, isTranscribing: true).canSend(hasContent: true))
        #expect(!InputBarConfig().canSend(hasContent: false))
    }

    @Test("Trailing composer presentation and action share one voice-state precedence")
    func testTrailingComposerModePrecedence() {
        #expect(
            ComposerTrailingMode(
                showStop: true,
                canSend: true,
                isRecording: true,
                isTranscribing: true
            ) == .stopAgent
        )
        #expect(
            ComposerTrailingMode(
                showStop: false,
                canSend: true,
                isRecording: true,
                isTranscribing: true
            ) == .stopRecording
        )
        #expect(
            ComposerTrailingMode(
                showStop: false,
                canSend: true,
                isRecording: false,
                isTranscribing: true
            ) == .transcribing
        )
        #expect(
            ComposerTrailingMode(
                showStop: false,
                canSend: true,
                isRecording: false,
                isTranscribing: false
            ) == .send
        )
        #expect(
            ComposerTrailingMode(
                showStop: false,
                canSend: false,
                isRecording: false,
                isTranscribing: false
            ) == .record
        )
        #expect(ComposerTrailingMode.transcribing.accessibilityLabel == "Transcribing")
        #expect(
            ComposerTrailingMode.transcribing.accessibilityHint(micDisabled: false)
                == "Wait for transcription to finish."
        )
        #expect(
            ComposerTrailingMode.record.accessibilityHint(micDisabled: true)
                == "Voice input is unavailable while the agent is active or disconnected."
        )
    }

    @Test("Composer embeds a background-free ring beside its trailing action")
    func testComposerGlassAndContextRingSourceContract() throws {
        let iosRoot = try Self.iosAppRoot()
        let inputSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/InputBar.swift"),
            encoding: .utf8
        )
        let buttonSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/ContextBriefingButton.swift"),
            encoding: .utf8
        )
        let attachmentSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/ActionButtons.swift"),
            encoding: .utf8
        )
        let configSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Session/Chat/State/InputBarState.swift"),
            encoding: .utf8
        )
        let oldPillURL = iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/ContextStatusPill.swift")

        let ring = try #require(inputSource.range(of: "ContextBriefingButton("))
        let trailingAction = try #require(inputSource.range(of: "ComposerTrailingButton("))
        let glass = try #require(inputSource.range(of: ".glassEffect("))
        let attachmentMenu = try #require(inputSource.range(of: "ComposerAttachmentButton("))
        #expect(ring.lowerBound < trailingAction.lowerBound)
        #expect(glass.lowerBound < attachmentMenu.lowerBound)
        #expect(inputSource.contains("if !state.attachments.isEmpty"))
        #expect(inputSource.contains(".padding(.horizontal, 4)\n            .glassEffect("))
        #expect(inputSource.contains(".overlay(alignment: .bottomLeading)"))
        #expect(inputSource.contains(".interactive(!config.readOnly)"))
        #expect(inputSource.contains("if !config.readOnly, config.showsContextBriefingControl"))
        #expect(!inputSource.contains(".background {"))
        #expect(!inputSource.contains("ContextStatusPill("))
        #expect(!inputSource.contains("shouldShowStatusPills"))
        #expect(!configSource.contains("let tokenUsage: TokenUsage?"))
        #expect(!configSource.contains("let contextWindow: Int"))
        #expect(!configSource.contains("let lastTurnInputTokens: Int"))
        #expect(!configSource.contains("let animationCoordinator: AnimationCoordinator?"))

        #expect(buttonSource.contains(".trim(from: 0, to: progressFraction)"))
        #expect(buttonSource.contains(".rotationEffect(.degrees(-90))"))
        #expect(buttonSource.contains("private let ringSize: CGFloat = 15"))
        #expect(buttonSource.contains(".frame(width: 40, height: 40)"))
        #expect(!buttonSource.contains(".glassEffect("))
        #expect(!buttonSource.contains(".fill("))
        #expect(buttonSource.contains(".contentShape(Circle())"))
        #expect(buttonSource.contains(".accessibilityIdentifier(\"session-briefing-button\")"))
        #expect(buttonSource.contains(".accessibilityLabel(\"Session Briefing\")"))
        #expect(attachmentSource.contains("Menu {"))
        #expect(attachmentSource.contains("Color.clear"))
        #expect(!attachmentSource.contains(".glassEffect("))
        #expect(!FileManager.default.fileExists(atPath: oldPillURL.path))
    }

    private static func iosAppRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
