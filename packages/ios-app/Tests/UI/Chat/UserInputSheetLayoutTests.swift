import Foundation
import XCTest

final class UserInputSheetLayoutTests: XCTestCase {
    func testQuestionsUseIndependentScrollablePagesWithFixedProgressAndDirectOptionRows() throws {
        let sheet = try source(pathComponents: [
            "Sources", "UI", "Chat", "Sheets", "UserInputSheet.swift",
        ])

        XCTAssertTrue(sheet.contains("TabView(selection: $currentQuestionIndex)"))
        XCTAssertTrue(sheet.contains(".tabViewStyle(.page(indexDisplayMode: .never))"))
        XCTAssertTrue(sheet.contains("questionPage(question, index: index)"))
        XCTAssertTrue(sheet.contains("fixedQuestionStatus"))
        XCTAssertTrue(sheet.contains("private var pageProgress"))
        XCTAssertTrue(sheet.contains("page == currentQuestionIndex"))
        XCTAssertTrue(sheet.contains("private func questionPage"))
        XCTAssertTrue(sheet.contains("ScrollView"))
        XCTAssertTrue(sheet.contains(".padding(.bottom, 40)"))
        XCTAssertTrue(sheet.contains("VStack(spacing: 10)"))
        XCTAssertFalse(sheet.contains("private func questionSection"))
        XCTAssertFalse(sheet.contains("question.header"))
        let pageFunction = try XCTUnwrap(sheet.range(of: "private func questionPage"))
        let progressProperty = try XCTUnwrap(sheet.range(of: "private var pageProgress"))
        XCTAssertLessThan(pageFunction.lowerBound, progressProperty.lowerBound)
        let pageSource = sheet[pageFunction.lowerBound..<progressProperty.lowerBound]
        XCTAssertFalse(pageSource.contains("pageProgress"))
        XCTAssertTrue(sheet.contains(".sectionFill(accentColor, subtle: !selected"))
        XCTAssertTrue(sheet.contains(".focused($focusedQuestionId, equals: question.id)"))
    }

    func testPendingAndAnsweredStatesOwnColorAndOneChatSurface() throws {
        let sheet = try source(pathComponents: [
            "Sources", "UI", "Chat", "Sheets", "UserInputSheet.swift",
        ])
        let messageContent = try source(pathComponents: [
            "Sources", "Session", "Timeline", "Messages", "MessageContent.swift",
        ])
        let messageBubble = try source(pathComponents: [
            "Sources", "UI", "Chat", "Messages", "MessageBubble.swift",
        ])
        let messaging = try source(pathComponents: [
            "Sources", "Session", "Chat", "ViewModel", "ChatViewModel+Messaging.swift",
        ])

        XCTAssertTrue(sheet.contains("case .pending: .tronWarning"))
        XCTAssertTrue(sheet.contains("case .answered: .tronSuccess"))
        XCTAssertTrue(sheet.contains("UserInputPresentation.chatTitle(for: request)"))
        XCTAssertFalse(sheet.contains("UserInputPresentation.chatDetail"))
        XCTAssertTrue(sheet.contains(".chipStyle(statusColor"))
        XCTAssertTrue(sheet.contains(".contentShape(Capsule())"))
        XCTAssertFalse(sheet.contains(".sectionFill(statusColor"))
        XCTAssertFalse(messageContent.contains("case userInputAnswer"))
        XCTAssertFalse(messageBubble.contains("UserInputAnswerChip"))
        XCTAssertFalse(messaging.contains("content: .userInputAnswer"))
    }

    private func source(pathComponents: [String]) throws -> String {
        var url = try iosAppRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func iosAppRoot() throws -> URL {
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
