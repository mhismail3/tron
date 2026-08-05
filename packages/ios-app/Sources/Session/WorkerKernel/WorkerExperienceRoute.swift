import Foundation

/// Routes only production client experiences with an independent active worker.
/// Retired or unknown worker contracts use the generic console.
enum WorkerExperienceRoute: Equatable {
    case researchSuite
    case delegation
    case genericConsole

    static func resolve(_ worker: WorkerSummaryDTO) -> Self {
        guard let presentation = worker.presentation,
              presentation.contractVersion == 1,
              presentation.primary else {
            return .genericConsole
        }
        switch (
            worker.workerId,
            presentation.experienceId,
            presentation.suiteId,
            presentation.componentRole
        ) {
        case ("research-coordinator", "research-suite", "research-suite", "coordinator"):
            return .researchSuite
        case ("general-delegate", "general-delegate", "delegation", "primary"):
            return .delegation
        default:
            return .genericConsole
        }
    }
}
