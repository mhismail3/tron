import SwiftUI

struct WebSettingsSection: View {
    @Binding var webFetchTimeoutMs: Int
    @Binding var webCacheTtlMs: Int
    @Binding var webCacheMaxEntries: Int
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    static let fetchTimeoutOptions: [(label: String, value: Int)] = [
        ("15s", 15000),
        ("30s", 30000),
        ("60s", 60000),
        ("2min", 120000),
    ]

    static let cacheTtlOptions: [(label: String, value: Int)] = [
        ("5min", 300000),
        ("15min", 900000),
        ("30min", 1800000),
        ("1hr", 3600000),
    ]

    var body: some View {
        Section {
            Picker(selection: $webFetchTimeoutMs) {
                ForEach(Self.fetchTimeoutOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Label("Fetch Timeout", systemImage: "clock")
                    .font(TronTypography.subheadline)
            }
            .onChange(of: webFetchTimeoutMs) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(tools: .init(web: .init(fetch: .init(timeoutMs: newValue))))
                }
            }

            Picker(selection: $webCacheTtlMs) {
                ForEach(Self.cacheTtlOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Label("Cache Duration", systemImage: "timer")
                    .font(TronTypography.subheadline)
            }
            .onChange(of: webCacheTtlMs) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(tools: .init(web: .init(cache: .init(ttlMs: newValue))))
                }
            }

            HStack {
                Label("Max Cached Pages", systemImage: "doc.on.doc")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(webCacheMaxEntries)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 30)
                Stepper("", value: $webCacheMaxEntries, in: 25...500, step: 25)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
            }
            .onChange(of: webCacheMaxEntries) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(tools: .init(web: .init(cache: .init(maxEntries: newValue))))
                }
            }
        } header: {
            Text("Web")
                .font(TronTypography.caption)
        }
        .listSectionSpacing(16)
    }
}
