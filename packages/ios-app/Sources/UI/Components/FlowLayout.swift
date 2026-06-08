import SwiftUI

// MARK: - Flow Layout (wrapping layout for tags/pills)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    struct CacheData {
        let size: CGSize
        let positions: [CGPoint]
    }

    func makeCache(subviews: Subviews) -> CacheData? {
        nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData?) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        cache = result
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData?) {
        let result = cache ?? arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> CacheData {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return CacheData(size: CGSize(width: maxWidth, height: totalHeight), positions: positions)
    }
}
