import SwiftUI

/// Shared formatting for ledger entry display.
///
/// Single source of truth for entry-type colors and file-op colors,
/// used by `LedgerEntryRow`, `MemoryDashboardDetailSheet`, and any
/// future view that renders ledger data.
enum LedgerFormatting {

    /// Color for a ledger entry type string.
    static func colorForEntryType(_ type: String) -> Color {
        switch type.lowercased() {
        case "feature": .green
        case "bugfix": .red
        case "refactor": .cyan
        case "docs": .blue
        case "config": .orange
        case "research": .yellow
        case "conversation": .purple
        case "personal": .pink
        case "preference": .mint
        case "knowledge": .indigo
        default: .tronTextSecondary
        }
    }

    /// Color for a file operation code (C/M/D).
    static func colorForFileOp(_ op: String) -> Color {
        switch op.uppercased() {
        case "C": .green
        case "M": .yellow
        case "D": .red
        default: .tronTextMuted
        }
    }
}
