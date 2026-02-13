import SwiftUI

struct AccountSection: View {
    let accounts: [String]
    @Binding var selectedAccount: String?
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    private var displayAccount: String {
        selectedAccount ?? accounts.first ?? "—"
    }

    var body: some View {
        Section {
            HStack {
                Label {
                    Text("Anthropic Account")
                        .foregroundStyle(.white)
                } icon: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.tronEmerald)
                }
                .font(TronTypography.subheadline)
                Spacer()
                Menu {
                    ForEach(accounts, id: \.self) { account in
                        Button {
                            selectedAccount = account
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(anthropicAccount: account))
                            }
                        } label: {
                            if account == selectedAccount {
                                Label(account, systemImage: "checkmark")
                            } else {
                                Text(account)
                            }
                        }
                    }
                } label: {
                    Text(displayAccount)
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("Accounts")
                .font(TronTypography.bodySM)
        }
        .listSectionSpacing(16)
    }
}
