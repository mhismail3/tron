import Foundation

/// Pure-value planner for the bundled `SMAppService` agent. Has no side
/// effects; the View validates the bundled files and registers the
/// LaunchAgent through `LaunchAgentManaging`.
///
/// Tests in `Tests/Support/Onboarding/InstallPlannerTests.swift` cover
/// missing packaged inputs and the paths carried by a successful plan.
enum InstallPlanner {
    enum Failure: Error, Equatable, Sendable {
        case helperMissing(URL)
        case plistMissing(URL)
    }

    /// Produces a fully-formed `InstallPlan` ready to be applied.
    static func plan(paths: TargetPaths) -> Result<InstallPlan, Failure> {
        guard FileManager.default.fileExists(atPath: paths.helperBinary.path) else {
            return .failure(.helperMissing(paths.helperBinary))
        }
        guard FileManager.default.fileExists(atPath: paths.plistPath.path) else {
            return .failure(.plistMissing(paths.plistPath))
        }

        return .success(InstallPlan(
            plistPath: paths.plistPath,
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary
        ))
    }

    struct TargetPaths: Equatable, Sendable {
        var helperBundle: URL
        var helperBinary: URL
        var plistPath: URL
    }
}
