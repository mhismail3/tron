import Foundation

enum ProviderAuthActionResult: Equatable {
    case succeeded
    case failed

    var shouldCommitLocalFormChanges: Bool {
        self == .succeeded
    }
}
