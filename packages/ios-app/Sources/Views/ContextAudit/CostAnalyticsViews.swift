import SwiftUI

// MARK: - Shared Cost Formatting

func formatCost(_ cost: Double) -> String {
    if cost < 0.00001 { return "$0.00" }
    if cost < 0.0001 { return String(format: "$%.5f", cost) }
    if cost < 0.001 { return String(format: "$%.4f", cost) }
    if cost < 0.01 { return String(format: "$%.3f", cost) }
    return String(format: "$%.2f", cost)
}
