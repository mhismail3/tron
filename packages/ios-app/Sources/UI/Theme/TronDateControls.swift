import SwiftUI

/// A date and a time are separate presentation identities even when they edit
/// the same draft. Automations and Home share this exact value/picker treatment.
enum TronDateComponent: String, Identifiable {
    case date, time
    var id: String { rawValue }
    var components: DatePickerComponents { self == .date ? .date : .hourAndMinute }
}

struct TronDateValueButton: View {
    let date: Date
    let component: TronDateComponent
    var accent: Color = .tronEmerald
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TronInlineActionLabel(
                date.formatted(date: component == .date ? .abbreviated : .omitted,
                               time: component == .time ? .shortened : .omitted),
                accent: accent
            )
        }
        .buttonStyle(.plain)
    }
}

/// Extracted from the Automations editor without changing its picker chrome.
/// Callers retain draft and managed-sheet ownership; Home also bounds expiry.
struct TronDatePickerSheet: View {
    let title: String
    let component: TronDateComponent
    @Binding var date: Date
    var earliestDate: Date?
    var accent: Color = .tronEmerald
    @Environment(\.dismiss) private var dismiss

    private var picker: DatePicker<Text> {
        if let earliestDate {
            DatePicker(title, selection: $date, in: earliestDate..., displayedComponents: component.components)
        } else {
            DatePicker(title, selection: $date, displayedComponents: component.components)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if component == .date {
                    picker.datePickerStyle(.graphical)
                } else {
                    picker.datePickerStyle(.wheel)
                        .labelsHidden()
                }
            }
            .padding()
            .tronNavigationTitle(title, accent: accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                        .tronToolbarAction(accent: accent)
                        .accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: accent)
    }
}
