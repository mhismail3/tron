import SwiftUI

@available(iOS 26.0, *)
struct TagFilterSheet: View {
    let allTags: [String]
    @Binding var selectedTags: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(allTags, id: \.self) { tag in
                        Button {
                            if selectedTags.contains(tag) {
                                selectedTags.remove(tag)
                            } else {
                                selectedTags.insert(tag)
                            }
                        } label: {
                            HStack {
                                Text(tag)
                                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                                    .foregroundStyle(selectedTags.contains(tag) ? .purple : .white.opacity(0.7))

                                Spacer()

                                if selectedTags.contains(tag) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.purple)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .glassEffect(
                                selectedTags.contains(tag)
                                    ? .regular.tint(Color.purple.opacity(0.2)).interactive()
                                    : .regular.tint(Color.white.opacity(0.05)).interactive(),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Filter by Tag")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selectedTags.isEmpty {
                        Button("Clear") {
                            selectedTags.removeAll()
                        }
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.purple)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .tint(.purple)
        .preferredColorScheme(.dark)
    }
}
