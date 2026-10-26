#if HOSTED_TEST
import Foundation
import SwiftUI

/// Extra illustrative rows for the native hierarchy review only. Never a live profile.
/// The normal Home fixture and its existing mutation journeys keep their original rows.
enum HostedProfileHierarchyFixture {
    /// Scope the explicit size to this review flag; ordinary fixture journeys keep Large.
    static var typeSize: DynamicTypeSize {
        let arguments = ProcessInfo.processInfo.arguments
        guard let key = arguments.firstIndex(of: "-UIPreferredContentSizeCategoryName"), key + 1 < arguments.count else { return .large }
        switch arguments[key + 1] {
        case "UICTContentSizeCategoryXXL": return .xxLarge
        case "UICTContentSizeCategoryXXXL": return .xxxLarge
        default: return .large
        }
    }

    static let additionalItems: [HostedProfileItem] = [
        item(1, path: "life/identity", text: "Example: Use the name I state, rather than guessing it."),
        item(2, path: "routines/availability", text: "Example: Keep explicitly stated availability separate from assumptions."),
        item(3, path: "engineering/testing/strategy", text: "Example: Prefer tests at the real boundary that changed."),
        item(4, path: "projects/example/pointers", text: "Example: A project entry holds its ownership and canonical pointers, not its rules."),
        item(5, path: "corrections/communication", kind: "correction", text: "Example: A request for a shorter answer did not mean omitting important uncertainty."),
        item(6, path: "prior", text: "Example legacy note awaiting an exact placement review.")
    ]

    private static func item(_ ordinal: Int, path: String, kind: String = "preference", text: String) -> HostedProfileItem {
        HostedProfileItem(id: "profile-hierarchy-example-\(ordinal)", revisionId: "profile-hierarchy-revision-\(ordinal)",
                          kind: kind, path: path, text: text, confirmed: false, status: "active",
                          createdAt: "2026-10-26T08:00:00Z", updatedAt: "2026-10-26T08:00:00Z")
    }
}
#endif
