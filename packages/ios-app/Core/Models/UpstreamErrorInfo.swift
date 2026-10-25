import Foundation

/// Disposable Gateway classification, not a second provider policy in Swift.
package struct UpstreamErrorInfo: Codable, Hashable, Sendable {
    package let message: String
    package let category: String
    package let providerMessage: String?
    package let type: String?
    package let requestId: String?
    package let httpStatus: Int?
}
