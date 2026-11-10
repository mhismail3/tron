import Foundation

package struct UpstreamErrorInfo: Codable, Hashable, Sendable {
    package let message: String
    package let category: String
    package let providerMessage: String?
    package let type: String?
    package let requestId: String?
    package let httpStatus: Int?
}
