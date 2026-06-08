import Testing
import Foundation

/// Regression guard: iOS source code and tests must contain no hardcoded
/// personal-info literals. User identity belongs in `MEMORY.md` on the server
/// (auto-injected into every session's context via the `memory.content` engine protocol
/// field); the iOS client never needs to encode it in code.
///
/// Needles are assembled from substrings so this test file itself doesn't
/// contain them.
@Suite("Source Guards")
struct SourceGuardTests {}
