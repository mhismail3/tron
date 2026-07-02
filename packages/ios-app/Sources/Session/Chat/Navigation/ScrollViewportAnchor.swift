import CoreGraphics
import Foundation

/// A stable viewport anchor for preserving position across history prepends.
///
/// SwiftUI's `ScrollViewReader.scrollTo(_:anchor:)` anchor is a point inside the
/// target view, not a viewport-relative offset. The safe invariant is therefore
/// to preserve the first visible message identity and restore it to `.top`.
/// Trying to replay a viewport pixel/fraction as a target-view anchor can land a
/// lazy stack in empty space after rows are inserted above the viewport.
struct ScrollViewportAnchor: Equatable {
    let messageId: UUID
}

/// Pure resolver for choosing the user's current reading anchor from measured rows.
enum ScrollViewportAnchorResolver {
    static func capture(
        frames: [UUID: CGRect],
        viewportHeight: CGFloat,
        orderedMessageIds: [UUID]
    ) -> ScrollViewportAnchor? {
        guard viewportHeight > 0 else { return nil }

        for id in orderedMessageIds {
            guard let frame = frames[id], frame.height > 0 else { continue }
            guard frame.maxY > 0, frame.minY < viewportHeight else { continue }

            return ScrollViewportAnchor(messageId: id)
        }

        return nil
    }
}
