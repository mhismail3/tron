import Foundation

// MARK: - Image Content

struct ImageContent: Equatable, Identifiable {
    let id: UUID
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
    }
}
