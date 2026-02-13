import SwiftUI

struct ServerSettingsSection: View {
    @Binding var serverHost: String
    @Binding var serverPort: String
    let selectedEnvironment: String
    let effectivePort: String
    let onHostSubmit: () -> Void
    let onPortChange: (String) -> Void
    let onEnvironmentChange: (String) -> Void

    var body: some View {
        Section {
            TextField("Host", text: $serverHost)
                .font(TronTypography.subheadline)
                .textContentType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onSubmit { onHostSubmit() }

            HStack {
                TextField("Custom Port", text: $serverPort)
                    .font(TronTypography.subheadline)
                    .keyboardType(.numberPad)
                    .onChange(of: serverPort) { _, newValue in
                        if !newValue.isEmpty {
                            onPortChange(newValue)
                        }
                    }

                Picker("", selection: Binding(
                    get: { selectedEnvironment },
                    set: { onEnvironmentChange($0) }
                )) {
                    Text("Beta").tag("beta")
                    Text("Prod").tag("prod")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 120)
            }
        } header: {
            Text("Server")
                .font(TronTypography.bodySM)
        }
        .listSectionSpacing(16)
    }
}
