import SwiftUI

/// Pill-style cycle picker used by settings rows that toggle between a
/// short fixed list of raw values (queue drain mode, merge strategy,
/// isolation mode, branch policy, ...).
///
/// Tapping the pill advances to the next option and invokes `onCycle`
/// with the new raw value. Use parallel `[(value, label)]` tuples so the
/// raw value (sent to the server) and the visible label can't drift
/// apart by indexing into mismatched arrays. `Value` is any `Hashable`
/// raw type — typically `String`, but also `UInt32` for numeric presets.
struct SettingsCycleToggle<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let current: Value
    let onCycle: (Value) -> Void

    var body: some View {
        // Empty `options` would index-trap `options[idx]` and divide by
        // zero on `% options.count`. Render an empty view defensively;
        // every production caller passes ≥2 options.
        if options.isEmpty {
            EmptyView()
        } else {
            cycleButton
        }
    }

    private var cycleButton: some View {
        let idx = options.firstIndex(where: { $0.value == current }) ?? 0
        let label = options[idx].label

        return Button {
            let next = options[(idx + 1) % options.count].value
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                onCycle(next)
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            }
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tronEmerald.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
