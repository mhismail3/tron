import SwiftUI

@available(iOS 26.0, *)
struct ContainerDetailSheet: View {
    let container: ContainerDTO
    let tailscaleIp: String?
    var onOpenURL: ((URL) -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// URL for the "Open" button: http://{tailscaleIp}:{firstHostPort}
    private var openURL: URL? {
        guard container.status == "running",
              let ip = tailscaleIp,
              let firstPort = container.ports.first else { return nil }
        let hostPort = firstPort.split(separator: ":").first.map(String.init) ?? firstPort
        return URL(string: "http://\(ip):\(hostPort)")
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    statusHeader
                        .padding(.horizontal)

                    if !container.ports.isEmpty {
                        portsSection
                            .padding(.horizontal)
                    }

                    detailsSection
                        .padding(.horizontal)

                    rawJSONSection
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let url = openURL, let onOpenURL {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                onOpenURL(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(.system(size: 14))
                                Text("Open")
                            }
                        }
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronIndigo)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(container.name)
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronIndigo)
                        .lineLimit(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronIndigo)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(.tronIndigo)
        .preferredColorScheme(.dark)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 16) {
            // Status badge
            Text(container.status)
                .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.15))
                .clipShape(Capsule())

            // Image
            HStack(spacing: 4) {
                Image(systemName: "shippingbox")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                Text(container.image)
                    .font(TronTypography.codeSM)
            }
            .foregroundStyle(.white.opacity(0.5))

            Spacer()

            // Created date
            Text(relativeDate(container.createdAt))
                .font(TronTypography.codeSM)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Ports

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ports")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronIndigo.opacity(0.7))

            ForEach(container.ports, id: \.self) { port in
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronIndigo.opacity(0.6))

                    Text(port)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))

                    if let ip = tailscaleIp {
                        let hostPort = port.split(separator: ":").first.map(String.init) ?? port
                        Text("http://\(ip):\(hostPort)")
                            .font(TronTypography.mono(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronIndigo.opacity(0.6))
                    }

                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronIndigo.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronIndigo.opacity(0.7))

            if let purpose = container.purpose {
                detailRow(icon: "text.justify.left", label: "Purpose", value: purpose)
            }

            detailRow(icon: "folder", label: "Directory", value: container.workingDirectory)
            detailRow(icon: "cpu", label: "Session", value: String(container.createdBySession.prefix(12)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronIndigo.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronIndigo.opacity(0.6))
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(TronTypography.mono(size: TronTypography.sizeSM))
                    .foregroundStyle(.white.opacity(0.4))
                Text(value)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()
        }
    }

    // MARK: - Raw JSON

    private var rawJSONSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Container Record")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(prettyPrintContainer())
                    .font(TronTypography.mono(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronIndigo.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch container.status {
        case "running": .green
        case "stopped": .gray
        case "gone": .red
        default: .white.opacity(0.5)
        }
    }

    private func relativeDate(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else {
            return timestamp
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private func prettyPrintContainer() -> String {
        let dict: [String: Any] = [
            "name": container.name,
            "image": container.image,
            "status": container.status,
            "ports": container.ports,
            "purpose": container.purpose ?? "null",
            "createdAt": container.createdAt,
            "createdBySession": container.createdBySession,
            "workingDirectory": container.workingDirectory,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
