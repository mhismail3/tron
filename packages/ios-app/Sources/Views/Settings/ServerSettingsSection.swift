import SwiftUI

struct ServerSettingsSection: View {
    @Binding var serverHost: String
    @Binding var serverPort: String
    let selectedEnvironment: String
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
                Picker("", selection: Binding(
                    get: { selectedEnvironment },
                    set: { onEnvironmentChange($0) }
                )) {
                    Text("Beta").tag("beta")
                    Text("Prod").tag("prod")
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer()

                TextField("Port", text: $serverPort)
                    .font(TronTypography.subheadline)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .onChange(of: serverPort) { _, newValue in
                        if !newValue.isEmpty {
                            onPortChange(newValue)
                        }
                    }
            }
        } header: {
            Text("Server")
                .font(TronTypography.bodySM)
        }
        .listSectionSpacing(16)
    }
}
