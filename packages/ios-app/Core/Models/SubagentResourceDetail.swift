import Foundation

package struct SubagentResourceDetail: Decodable, Hashable, Sendable {
    package let name: String
    package let description: String?
    package let content: String?
    package let contentBytes: Int?
    package let contentTruncated: Bool?

    package static func admit(_ detail: SubagentResourceDetail, matching name: String) throws -> SubagentResourceDetail {
        let projectedBytes = detail.content?.utf8.count
        guard detail.name == name,
              projectedBytes.map({ $0 <= CommandResourceDetailPolicy.maximumContentBytes }) ?? true,
              projectedBytes == nil || detail.contentBytes.map({ $0 >= projectedBytes! }) == true else {
            throw GatewayFailure(code: "invalid_response", message: "The selected subagent detail from the Mac is invalid or too large.",
                                 retryable: true, details: nil)
        }
        return detail
    }
}
