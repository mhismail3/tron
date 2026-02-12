import SwiftUI

struct AccountSection: View {
    let accounts: [String]
    @Binding var selectedAccount: String?
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        Section {
            ForEach(accounts, id: \.self) { account in
                Button {
                    selectedAccount = account
                    updateServerSetting {
                        ServerSettingsUpdate(server: .init(anthropicAccount: account))
                    }
                } label: {
                    HStack {
                        Label(account, systemImage: "person.crop.circle")
                            .font(TronTypography.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        if account == selectedAccount {
                            Image(systemName: "checkmark")
                                .font(TronTypography.caption)
                                .foregroundStyle(.tronEmerald)
                        }
                    }
                }
            }
        } header: {
            Text("Claude Account")
                .font(TronTypography.caption)
        } footer: {
            Text("Switch between Claude accounts. Add accounts by editing ~/.tron/auth.json.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
