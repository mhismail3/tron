import SwiftUI

struct ServerSettingsSection: View {
    @Binding var serverHost: String
    @Binding var serverPort: String
    let onHostSubmit: () -> Void
    let onPortChange: (String) -> Void

    var body: some View {
        Section {
            HStack {
                Label("Host Address", systemImage: "globe")
                    .font(TronTypography.subheadline)
                Spacer()
                TextField("localhost", text: $serverHost)
                    .font(TronTypography.subheadline)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onSubmit { onHostSubmit() }
            }

            HStack {
                Label("Port", systemImage: "number")
                    .font(TronTypography.subheadline)
                Spacer()
                TextField("9847", text: $serverPort)
                    .font(TronTypography.subheadline)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
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
