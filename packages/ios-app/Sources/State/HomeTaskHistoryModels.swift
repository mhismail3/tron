import Foundation
import TronMobileCore

/// Bounded read projection; the Gateway reconstructs this from canonical evidence.
struct HomeTaskHistoryPageDTO: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let at: String
        let taskId: String
        let operationId: String?
        let operationNumber: Int
        let lifecycle: HomeTaskLifecycle
        let outcome: HomeTaskOutcome?
        let checkin: HomeTaskCheckinDTO?
        var valid: Bool {
            historyText(id, bytes: 200) && HomeChapterPresentation.parse(at) != nil && historyID(taskId)
                && (operationId.map(historyID) ?? true) && operationNumber > 0
                && ((lifecycle == .terminal) == (outcome != nil)) && (checkin?.valid ?? true)
                && (checkin.map { $0.id == id && $0.at == at && $0.taskId == taskId && $0.operationId == operationId } ?? true)
        }
        var operationLabel: String { operationNumber == 1 ? "Original operation" : "Resume \(operationNumber - 1)" }
        var stateLabel: String { HomeTaskPresentation.stateLabel(lifecycle: lifecycle, outcome: outcome) }
    }
    let items: [Item]
    let total: Int
    let complete: Bool
    let nextCursor: String?
    static func decode(_ value: JSONValue) throws -> Self {
        let page = try value.decode(Self.self)
        guard page.items.count <= 50, page.total >= page.items.count, page.items.allSatisfy(\.valid),
              Set(page.items.map(\.id)).count == page.items.count,
              zip(page.items, page.items.dropFirst()).allSatisfy({ HomeChapterPresentation.parse($0.at)! >= HomeChapterPresentation.parse($1.at)! }),
              page.nextCursor.map({ historyText($0, bytes: 1024) && !page.items.isEmpty }) ?? true else {
            throw GatewayFailure(code: "invalid_response", message: "Home returned invalid check-in history. Reload history.", retryable: false, details: nil)
        }
        return page
    }
}

private func historyText(_ text: String, bytes: Int) -> Bool { !text.isEmpty && !text.contains("\0") && text.utf8.count <= bytes }
private func historyID(_ text: String) -> Bool {
    text.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$", options: .regularExpression) != nil
}

enum HomeTaskFilter: String, CaseIterable, Sendable {
    case open, finished, all
    var title: String { switch self { case .open: "In progress"; case .finished: "Finished"; case .all: "All tasks" } }
}
