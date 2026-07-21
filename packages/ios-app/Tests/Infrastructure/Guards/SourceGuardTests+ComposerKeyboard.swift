import Testing
import Foundation

extension SourceGuardTests {
    @Test("Composer attachment menu stays functional-only")
    func testComposerAttachmentMenuStaysFunctionalOnly() throws {
        let iosRoot = iosAppRoot()
        let checkedPaths = [
            "Sources/UI/Chat/Composer/ActionButtons.swift",
            "Sources/UI/Chat/Composer/InputBar.swift",
            "Sources/UI/Chat/Composer/RecentInputHistorySheet.swift",
        ]
        let requiredCommands = [
            "Take Photo",
            "Select Photos",
            "Attach Files",
            "Recent Inputs",
        ]
        let requiredLayoutFragments = [
            "Menu {",
            ".overlay {",
            "Color.clear",
            "Label(action.title, systemImage: action.systemImage)",
            ".labelStyle(.titleAndIcon)",
            ".controlSize(.small)",
            "NotificationCenter.default.post(name: .attachmentMenuAction, object: action)",
            ".onReceive(NotificationCenter.default.publisher(for: .attachmentMenuAction))",
            "ComposerAttachmentButton(",
            "ComposerTrailingButton(",
            ".glassEffect(",
            ".overlay(alignment: .bottomLeading)",
            "includeRecentInputs: shouldShowRecentInputsMenuAction",
            ".sheet(isPresented: $showCamera)",
            ".sheet(isPresented: $showFilePicker)",
            ".photosPicker(",
            "selection: $state.selectedImages",
        ]
        let combined = try checkedPaths.map { relativePath in
            try String(
                contentsOf: iosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        for command in requiredCommands {
            #expect(combined.contains(command), "composer attachment menu must expose \(command)")
        }

        for fragment in requiredLayoutFragments {
            #expect(combined.contains(fragment), "composer attachment menu must keep keyboard-preserving native menu layout `\(fragment)`")
        }
    }

    @Test("Attachment menu preserves composer keyboard focus")
    func testAttachmentMenuPreservesComposerKeyboardFocus() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/InputBar.swift"),
            encoding: .utf8
        )
        let attachmentButtonRange = try #require(source.range(of: "ComposerAttachmentButton("))
        let dragHintRange = try #require(source.range(
            of: ".overlay(alignment: .top)",
            range: attachmentButtonRange.lowerBound..<source.endIndex
        ))
        let attachmentButtonSource = String(source[attachmentButtonRange.lowerBound..<dragHintRange.lowerBound])

        #expect(
            !attachmentButtonSource.contains("isFocused = false"),
            "Opening the attachment menu must not clear composer text focus or dismiss the keyboard"
        )
        #expect(
            source.contains("ComposerAttachmentButton(") &&
                source.contains("attachmentSupport: config.attachmentSupport") &&
                source.contains("includeRecentInputs: shouldShowRecentInputsMenuAction"),
            "The attachment action menu should stay attached to the composer plus button with the current model support"
        )
        #expect(
            !source.contains(".popover(isPresented: $showAttachmentMenu") &&
                !source.contains(".sheet(isPresented: $showAttachmentMenu"),
            "The attachment action menu must not use a SwiftUI presentation that steals composer focus"
        )
    }

    @Test("Composer owns one integrated control surface")
    func testComposerOwnsOneIntegratedControlSurface() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/InputBar.swift"),
            encoding: .utf8
        )
        let glassRange = try #require(source.range(of: ".glassEffect("))
        let attachmentMenuRange = try #require(source.range(of: "ComposerAttachmentButton("))

        #expect(source.contains("ComposerAttachmentButton("))
        #expect(source.contains("ComposerTrailingButton("))
        #expect(source.contains("inputField"))
        #expect(source.components(separatedBy: ".glassEffect(").count - 1 == 1)
        #expect(glassRange.lowerBound < attachmentMenuRange.lowerBound)
        #expect(source.contains(".overlay(alignment: .bottomLeading)"))
        #expect(source.contains("The native Menu itself is overlaid after the material"))
        #expect(source.contains(".interactive(!config.readOnly)"))
        #expect(!source.contains("ContextStatusPill("))
        #expect(!source.contains("shouldShowStatusPills"))
        #expect(!source.contains("GlassAttachmentButton("))
        #expect(!source.contains("GlassActionButton("))
        #expect(!source.contains("GlassMicButton("))
        #expect(!source.contains("attachmentMorph"))
        #expect(!source.contains("actionMorph"))
    }

    @Test("Composer recent input history stays local and non-routing")
    func testComposerRecentInputHistoryStaysLocalAndNonRouting() throws {
        let iosRoot = iosAppRoot()
        let checkedPaths = [
            "Sources/UI/Chat/Composer/InputBar.swift",
            "Sources/UI/Chat/Composer/RecentInputHistorySheet.swift",
            "Sources/UI/Chat/Shell/ChatView+MessageList.swift",
            "Sources/Session/Chat/Coordinators/MessagingCoordinator.swift",
            "Sources/Support/Storage/InputHistoryStore.swift",
        ]
        let combined = try checkedPaths.map { relativePath in
            try String(
                contentsOf: iosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        let requiredFragments = [
            "Recent Inputs",
            "InputHistoryStore",
            "clearHistory()",
            "case .recentInputs:",
            "showRecentInputs = true",
            "preview(for: input)",
            ".listRowInsets(EdgeInsets(",
            ".listRowSeparator(.hidden)",
            "actions.onHistoryNavigate?(selected)",
            "onPromptSent?(text)",
            "inputHistory.addToHistory(sentText)",
            "defaults.removeObject(forKey: storageKey)",
        ]
        for fragment in requiredFragments {
            #expect(combined.contains(fragment), "recent input history should keep local behavior `\(fragment)`")
        }
    }

    @Test("Pending share text send uses recent input success callback")
    func testPendingShareTextSendUsesRecentInputSuccessCallback() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ChatView.swift"),
            encoding: .utf8
        )
        let receiverStart = try #require(source.range(of: ".onReceive(NotificationCenter.default.publisher(for: .pendingShareMessage))"))
        let receiverEnd = try #require(
            source[receiverStart.upperBound...].range(of: ".onChange(of: scenePhase)")
        )
        let receiverSource = String(source[receiverStart.lowerBound..<receiverEnd.lowerBound])

        #expect(
            receiverSource.contains("viewModel.inputText = payload.prompt"),
            "Pending share text should still route through the chat input text before sending"
        )
        #expect(
            receiverSource.contains("viewModel.sendMessage(") &&
                receiverSource.contains("onPromptSent: { sentText in") &&
                receiverSource.contains("inputHistory.addToHistory(sentText)"),
            "Pending share text sends must persist recent input history only through the successful prompt callback"
        )
        #expect(
            !receiverSource.contains("viewModel.sendMessage()") &&
                !receiverSource.contains("inputHistory.addToHistory(payload.prompt)") &&
                !receiverSource.contains("inputHistory.addToHistory(viewModel.inputText)"),
            "Pending share text must not persist attempted text before the successful send boundary"
        )
    }
}
