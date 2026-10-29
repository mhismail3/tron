import Foundation

package struct TerminalChunk: Codable, Hashable, Sendable {
    package let sequence: Int
    package let data: String

    package init(sequence: Int, data: String) {
        self.sequence = sequence
        self.data = data
    }
}
