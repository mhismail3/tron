#if HOSTED_TEST
import Foundation

/// Bounded test evidence for the independent process-sheet route. Transcript,
/// viewport, composer, and geometry probes were retired with the SwiftUI chat
/// owners; native integration tests inspect their UIKit controllers directly.
struct ChatHostedObservation: Sendable {
    let processRoutes: [String]
}

@MainActor
final class ChatHostedProbe {
    private var processRoutes: [String] = []

    var observation: ChatHostedObservation {
        ChatHostedObservation(processRoutes: processRoutes)
    }

    func recordProcessRoute() {
        processRoutes.append("processes")
        if processRoutes.count > 32 {
            processRoutes.removeFirst(processRoutes.count - 32)
        }
    }
}
#endif
