import Foundation
import TronMobileCore

extension HomeTaskHistoryItem: Identifiable {
    var valid: Bool {
        historyText(id, bytes: 200) && GatewayTimestamp.parse(at) != nil && historyID(taskId)
            && (operationId.value.map(historyID) ?? true) && operationNumber > 0
            && ((lifecycle == .terminal) == (outcome != .null)) && (checkin?.valid ?? true)
            && (checkin.map { $0.id == id && $0.at == at && $0.taskId == taskId && $0.operationId == operationId.value } ?? true)
    }
    var operationLabel: String { operationNumber == 1 ? "Original operation" : "Resume \(operationNumber - 1)" }
    var stateLabel: String { HomeTaskPresentation.stateLabel(lifecycle: lifecycle, outcome: outcome.value) }
}

extension HomeTaskHistoryPage {
    static func validated(_ value: JSONValue) throws -> Self {
        let page = try value.decodeWire(Self.decode)
        guard page.items.count <= 50, page.total >= page.items.count, page.items.allSatisfy(\.valid),
              Set(page.items.map(\.id)).count == page.items.count,
              zip(page.items, page.items.dropFirst()).allSatisfy({ GatewayTimestamp.parse($0.at)! >= GatewayTimestamp.parse($1.at)! }),
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
