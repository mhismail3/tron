import SwiftUI

// MARK: - Remember Tool Subviews

@available(iOS 26.0, *)
extension RememberToolDetailSheet {

    // MARK: - Memory Results (recall, search, memory)

    func memoryResultsSection(_ result: String) -> some View {
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            if entries.isEmpty {
                rawContentSection(result)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if index > 0 {
                            Divider()
                                .background(Color.purple.opacity(0.08))
                                .padding(.horizontal, 8)
                        }
                        memoryEntryRow(entry)
                    }
                }
                .sectionFill(.purple)
            }
        }
    }

    func memoryEntryRow(_ entry: RememberMemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(entry.index).")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint.subtle)
                    .frame(width: 20, alignment: .trailing)

                Text(entry.content)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(tint.body)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let relevance = entry.relevance {
                HStack(spacing: 4) {
                    relevanceBar(relevance)
                    Text("\(relevance)%")
                        .font(TronTypography.pill)
                        .foregroundStyle(relevanceColor(relevance))
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
    }

    func relevanceBar(_ score: Int) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.purple.opacity(0.1))
                Capsule()
                    .fill(relevanceColor(score))
                    .frame(width: geo.size.width * CGFloat(score) / 100)
            }
        }
        .frame(width: 60, height: 4)
    }

    func relevanceColor(_ score: Int) -> Color {
        if score >= 75 { return .tronEmerald }
        if score >= 50 { return .tronAmber }
        return .purple
    }

    // MARK: - Session List (sessions)

    func sessionListSection(_ result: String) -> some View {
        let sessions = RememberDetailParser.parseSessions(from: result)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.heading)

            if sessions.isEmpty {
                rawContentSection(result)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                        if index > 0 {
                            Divider()
                                .background(Color.purple.opacity(0.08))
                                .padding(.horizontal, 8)
                        }
                        sessionRow(session)
                    }
                }
                .sectionFill(.purple)
            }
        }
    }

    func sessionRow(_ session: RememberSessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(accentColor)

                Text(session.title.isEmpty ? session.sessionId : session.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Text(session.sessionId.count > 16 ? String(session.sessionId.prefix(16)) + "..." : session.sessionId)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.subtle)

                if !session.date.isEmpty {
                    Text(RememberDetailParser.formatDate(session.date))
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.subtle)
                }
            }
            .padding(.leading, 20)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    // MARK: - Session Detail (session)

    func sessionDetailSection(_ result: String) -> some View {
        ToolDetailSection(title: "Session", accent: accentColor, tint: tint) {
            Text(result)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - JSON Entries (events, messages, tools, logs)

    func jsonEntriesSection(_ result: String) -> some View {
        let entries = RememberDetailParser.parseJSONEntries(from: result)
        let sectionTitle = action == "messages" ? "Messages" : action == "tools" ? "Tool Calls" : action == "logs" ? "Logs" : "Events"

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sectionTitle)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            if entries.isEmpty {
                rawContentSection(result)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            if index > 0 {
                                Divider()
                                    .background(Color.purple.opacity(0.12))
                                    .padding(.horizontal, 4)
                            }
                            Text(entry)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .sectionFill(.purple)
            }
        }
    }

    // MARK: - Stats (stats)

    func statsSection(_ result: String) -> some View {
        let stats = RememberDetailParser.parseStats(from: result)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Database Stats")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.heading)

            if stats.isEmpty {
                rawContentSection(result)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(stats, id: \.key) { stat in
                        statCard(stat)
                    }
                }
            }
        }
    }

    func statCard(_ stat: RememberStatEntry) -> some View {
        VStack(spacing: 6) {
            Image(systemName: stat.icon)
                .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                .foregroundStyle(accentColor)

            Text(stat.value)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(tint.body)

            Text(stat.label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(tint.subtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(accentColor.opacity(0.08)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Code Section (schema, read_blob)

    func codeSection(_ result: String) -> some View {
        let title = action == "schema" ? "Schema" : "Content"

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .sectionFill(.purple)
        }
    }

    // MARK: - Raw Content Fallback

    func rawContentSection(_ result: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            Text(result)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .sectionFill(.purple)
    }
}
