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
            "Label(action.title, systemImage: action.systemImage)",
            ".labelStyle(.titleAndIcon)",
            ".controlSize(.small)",
            "NotificationCenter.default.post(name: .attachmentMenuAction, object: action)",
            ".onReceive(NotificationCenter.default.publisher(for: .attachmentMenuAction))",
            ".matchedGeometryEffect(id: \"attachmentMorph\"",
            "includeRecentInputs: shouldShowRecentInputsMenuAction",
            ".sheet(isPresented: $showCamera)",
            ".sheet(isPresented: $showFilePicker)",
            ".photosPicker(",
            "selection: $state.selectedImages",
        ]
        let forbiddenFragments = [
            "Add " + "Skill",
            "Prompt " + "Library",
            "Draft a " + "Plan",
            "draft" + "Plan" + "Requested",
            "Queued" + "Message",
            "Pending" + "Queue" + "Item",
            "show" + "Skill",
            "skill" + "Mention",
            "prompt" + "Library",
            "pending" + "Attachment" + "Menu" + "Action",
            "present" + "Pending" + "Attachment" + "Menu" + "Action",
            "onDismiss: present" + "Pending" + "Attachment" + "Menu" + "Action",
            "AttachmentNativeMenuOverlay",
            "UIViewRepresentable",
            "preferredElementSize",
            "AttachmentMenuPopup",
            "AttachmentMenuSheet",
            "GlassRecentInputsButton",
            ".overlay(alignment: .bottomLeading)",
            ".popover(isPresented: $showAttachmentMenu",
            ".sheet(isPresented: $showAttachmentMenu",
            "compactHeightSheetPresentation(height: CompactActionSheetLayout.sheetHeight",
            ".font(.system(size: 28",
            ".frame(width: 300, alignment: .leading)",
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

        for fragment in forbiddenFragments {
            #expect(
                !combined.contains(fragment),
                "composer attachment menu must not restore Phase 2/review-only affordance `\(fragment)`"
            )
        }
    }

    @Test("Attachment menu preserves composer keyboard focus")
    func testAttachmentMenuPreservesComposerKeyboardFocus() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/InputBar.swift"),
            encoding: .utf8
        )
        let attachmentButtonRange = try #require(source.range(of: "GlassAttachmentButton("))
        let textFieldRange = try #require(source.range(of: "// Text field with glass background"))
        let attachmentButtonSource = String(source[attachmentButtonRange.lowerBound..<textFieldRange.lowerBound])

        #expect(
            !attachmentButtonSource.contains("isFocused = false"),
            "Opening the attachment menu must not clear composer text focus or dismiss the keyboard"
        )
        #expect(
            source.contains("GlassAttachmentButton(") &&
                source.contains("attachmentCapability: config.attachmentCapability") &&
                source.contains("includeRecentInputs: shouldShowRecentInputsMenuAction"),
            "The attachment action menu should stay attached to the composer plus button with the current model capability"
        )
        #expect(
            !source.contains(".popover(isPresented: $showAttachmentMenu") &&
                !source.contains(".sheet(isPresented: $showAttachmentMenu"),
            "The attachment action menu must not use a SwiftUI presentation that steals composer focus"
        )
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
            ".listRowSeparator(.hidden)",
            "actions.onHistoryNavigate?(selected)",
            "onPromptSent?(text)",
            "inputHistory.addToHistory(sentText)",
            "UserDefaults.standard.removeObject(forKey: storageKey)",
        ]
        let forbiddenFragments = [
            "Prompt" + "Library",
            "Prompt" + "Snippet",
            "Prompt" + "Template",
            "Prompt" + "Library" + "Client",
            "prompt" + "_library::",
            "prompt" + "Library",
            "agent::" + "queue_prompt",
            "skills::" + "activate",
            "ui::" + "submit_action",
            "artifact:prompt",
            "addToHistory(viewModel.inputText)",
        ]

        for fragment in requiredFragments {
            #expect(combined.contains(fragment), "recent input history should keep local behavior `\(fragment)`")
        }

        for fragment in forbiddenFragments {
            #expect(
                !combined.contains(fragment),
                "recent input history must not restore backend prompt-history or routing behavior `\(fragment)`"
            )
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
        let receiverEnd = try #require(source[receiverStart.upperBound...].range(of: ".onAppear"))
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
