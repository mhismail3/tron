import SwiftUI

/// Stable sheet destination for unbounded JSON and other technical payloads.
struct WorkerJSONDetailSheet: View {
    let title: String
    let value: AnyCodable
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                WorkerJSONBlock(value: value, accent: accent)
                    .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(accent)
    }
}
