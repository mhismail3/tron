import SwiftUI

// MARK: - Wrapping HStack Layout

/// A horizontal stack that wraps items to new rows when they exceed available width
/// Items wrap from bottom to top (newest rows appear at top)
@available(iOS 16.0, *)
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)

        // Place rows from bottom to top (so overflow rows appear above)
        var y = bounds.maxY
        for row in rows.reversed() {
            y -= row.height
            var x = bounds.minX

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y -= lineSpacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        let maxWidth = proposal.width ?? .infinity

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)

            // Check if item fits in current row
            let newWidth = currentRow.width + (currentRow.indices.isEmpty ? 0 : spacing) + size.width
            if newWidth > maxWidth && !currentRow.indices.isEmpty {
                // Start new row
                rows.append(currentRow)
                currentRow = Row()
            }

            // Add item to current row
            currentRow.indices.append(index)
            currentRow.width += (currentRow.indices.count > 1 ? spacing : 0) + size.width
            currentRow.height = max(currentRow.height, size.height)
        }

        // Add final row
        if !currentRow.indices.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

// MARK: - Line Break for WrappingHStack

/// Invisible full-width element that forces a line break in WrappingHStack
struct LineBreak: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 0)
    }
}
