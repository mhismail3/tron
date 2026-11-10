import Foundation
import TronMobileCore

extension AppModel {
    func subagentDetail(sessionID: String, name: String) async throws -> SubagentResourceDetail {
        guard let target = presentationTarget(for: sessionID),
              admitsLiveSessionCommands(target) else { throw CancellationError() }
        struct Params: Encodable {
            let sessionId: String
            let name: String
        }
        let detail: SubagentResourceDetail = try await client.request(
            "session.subagentDetail", Params(sessionId: sessionID, name: name))
        guard presentationTarget(for: sessionID) == target,
              admitsLiveSessionCommands(target) else { throw CancellationError() }
        return try SubagentResourceDetail.admit(detail, matching: name)
    }
}
