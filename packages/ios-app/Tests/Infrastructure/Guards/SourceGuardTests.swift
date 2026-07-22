import Testing
import Foundation

/// Regression guard: iOS source code and tests must contain no hardcoded
/// personal-info literals. User identity belongs in runtime state outside the
/// shipped client source.
@Suite("Source Guards")
struct SourceGuardTests {}
