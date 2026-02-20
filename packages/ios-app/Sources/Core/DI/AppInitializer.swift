import Foundation

@Observable
@MainActor
final class AppInitializer {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .loading

    var isReady: Bool { state == .ready }

    func initialize(_ work: () async throws -> Void) async {
        guard state != .ready else { return }
        state = .loading
        do {
            try await work()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
