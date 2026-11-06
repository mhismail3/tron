import SwiftUI

/// A static replica of Manage Home's layout for the Sandbox: fake values, no
/// Gateway reads, no actions. Rows open fake detail pages inside the sheet and
/// the playground bar adds and removes rows, so content-driven resizing and
/// in-sheet pushes can be watched. Shared by the fluid sheet and the stock
/// sheet baseline, so the two present identical content.
@Observable @MainActor
final class SandboxManageHomeDemo {
    enum Page: Hashable {
        case row(Int)
    }

    static let maxRows = 14
    /// Profile, Memory, Chapters and Tasks, as Manage Home lists them, then fillers.
    static let namedRows: [(icon: String, title: String, subtitle: String)] = [
        ("person.text.rectangle", "Profile", "12 learned items · updated today"),
        ("brain", "Memory", "Current · 4 summaries this chapter"),
        ("book", "Chapters", "Chapter 18 · 6 summaries"),
        ("checklist", "Tasks", "2 running · 5 completed"),
    ]

    var rowCount = 2
    var showsControls = false
    var page: Page?

    func row(_ index: Int) -> (icon: String, title: String, subtitle: String) {
        index < Self.namedRows.count ? Self.namedRows[index]
            : ("square.dashed", "Sandbox row \(index + 1)", "Fake row added from the playground bar")
    }

    func detailLines(_ page: Page) -> [String] {
        guard case .row(let index) = page else { return [] }
        switch index {
        case 0: return ["Prefers concise status updates", "Works mostly in the Tron repository", "Reviews visuals on iPhone"]
        case 1: return (1...6).map { "Summary \($0): fake memory line for the Sandbox" }
        case 2: return (1...18).reversed().map { "Chapter \($0) · \(3 + $0 % 5) summaries" }
        case 3: return ["Settings sandbox · running", "Gateway audit · running", "Docs sweep · completed",
                        "Release notes · completed"]
        default: return ["A fake detail page", "Its height differs from the list's"]
        }
    }
}

struct SandboxManageHomeHeader: View {
    let demo: SandboxManageHomeDemo
    var showsDone = true
    @Environment(\.tronFluidSheet) private var sheet

    var body: some View {
        ZStack {
            Text(title)
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .id(title)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("sandbox-sheet-title")
                .padding(.horizontal, 64)
            HStack {
                if demo.page != nil {
                    circleButton("chevron.backward", label: "Back", id: "sandbox-sheet-back") {
                        withAnimation(sheet.motion.spring) { demo.page = nil }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Spacer()
                if showsDone {
                    circleButton("checkmark", label: "Done", id: "sandbox-sheet-done") { sheet.dismiss() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(minHeight: 60)
    }

    private var title: String {
        guard case .row(let index) = demo.page else { return "Manage Home" }
        return demo.row(index).title
    }

    private func circleButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Solid, not glass: controls inside the glass card never stack glass on glass.
        .background(Circle().fill(Color.tronPrimary.opacity(0.12)))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The scrolling body: the root list or one pushed detail page.
struct SandboxManageHomeContent: View {
    let demo: SandboxManageHomeDemo
    @Environment(\.tronFluidSheet) private var sheet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let page = demo.page {
                detail(page)
                    .transition(edgeTransition(.trailing))
            } else {
                root
                    .transition(edgeTransition(.leading))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .top)
        .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
    }

    private func edgeTransition(_ edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var root: some View {
        VStack(spacing: 16) {
            statusCard
            modelCard
            if demo.rowCount > 0 {
                rowsCard
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            if demo.showsControls {
                settingsCard
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                controlsCard
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandbox-manage-home")
    }

    private var statusCard: some View {
        TronGlassCard(accent: .tronPrimary) {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                HStack(spacing: TronSpacing.md) {
                    TronStatusPill(text: "Ready", accent: .tronEmerald)
                    TronStatusPill(text: "2 workers", accent: .tronEmerald)
                }
                HStack(spacing: TronSpacing.xl) {
                    SessionContextProgressRing(fraction: 0.29, accent: .tronPrimary, diameter: TronSpacing.xlarge)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: TronSpacing.xxs) {
                        Text("142K tokens left").font(SessionSummaryTypography.headline)
                        Text("29% used · 3.1M\u{00A0}total\u{00A0}tokens · 92.4%\u{00A0}cache\u{00A0}hit")
                            .font(SessionSummaryTypography.usageValue)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(TronSpacing.xxl)
        }
        .foregroundStyle(Color.tronTextPrimary)
        .accessibilityElement(children: .combine)
    }

    private var modelCard: some View {
        TronGlassCard(accent: .tronPrimary) {
            VStack(spacing: 0) {
                TronSettingsRow(icon: "cpu", title: "Opus 5.5", titleFont: SessionSummaryTypography.headline) {
                    HStack(spacing: 6) {
                        TronInlineActionLabel("", icon: "arrow.uturn.backward", alignment: .leading)
                        TronInlineActionLabel("Switch Model")
                    }
                    .accessibilityHidden(true)
                }
                .lineLimit(1)
                TronSettingsDivider()
                TronSettingsRow(icon: "brain", title: "Effort") {
                    TronStatusPill(text: "High", accent: .tronPrimary)
                }
            }
        }
        .controlSize(.small)
    }

    private var rowsCard: some View {
        TronGlassCard(accent: .tronPrimary) {
            VStack(spacing: 0) {
                ForEach(0..<demo.rowCount, id: \.self) { index in
                    VStack(spacing: 0) {
                        if index > 0 { TronSettingsDivider() }
                        let row = demo.row(index)
                        Button {
                            withAnimation(sheet.motion.spring) { demo.page = .row(index) }
                        } label: {
                            TronSettingsRow(icon: row.icon, title: row.title, subtitle: row.subtitle)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sandbox-row-\(index)")
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
    }

    private var settingsCard: some View {
        TronGlassCard(accent: .tronPrimary) {
            TronSettingsRow(icon: "slider.horizontal.3", title: "Home Settings",
                            subtitle: "Assistant profile and worker launch choices")
        }
    }

    private var controlsCard: some View {
        TronGlassCard(accent: .tronSlate) {
            VStack(spacing: 0) {
                TronSettingsRow(icon: "pause.fill", title: "Pause memory",
                                subtitle: "New responses are blocked while paused", accent: .tronSlate)
                TronSettingsDivider(accent: .tronSlate)
                TronSettingsRow(icon: "house.slash", title: "Disable Home",
                                subtitle: "Stops activations; history is preserved",
                                accent: .tronError, titleColor: .tronError, subtitleColor: .tronError)
            }
        }
    }

    private func detail(_ page: SandboxManageHomeDemo.Page) -> some View {
        let lines = demo.detailLines(page)
        let icon = switch page { case .row(let index): demo.row(index).icon }
        return TronGlassCard(accent: .tronPrimary) {
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if index > 0 { TronSettingsDivider() }
                    TronSettingsRow(icon: icon, title: line)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandbox-detail")
    }
}

/// The playground bar: the controls that change the sheet's content, pinned at
/// the card's bottom so they stay under the finger while the card resizes.
struct SandboxPlaygroundBar: View {
    let demo: SandboxManageHomeDemo
    @Environment(\.tronFluidSheet) private var sheet

    var body: some View {
        HStack(spacing: 10) {
            barButton("minus", label: "Remove row", id: "sandbox-rows-remove", enabled: demo.rowCount > 0) {
                demo.rowCount -= 1
            }
            Text("\(demo.rowCount) \(demo.rowCount == 1 ? "row" : "rows")")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.tronTextSecondary)
                .contentTransition(.numericText(value: Double(demo.rowCount)))
                .accessibilityIdentifier("sandbox-rows-count")
            barButton("plus", label: "Add row", id: "sandbox-rows-add", enabled: demo.rowCount < SandboxManageHomeDemo.maxRows) {
                demo.rowCount += 1
            }
            Spacer(minLength: 8)
            barButton(demo.showsControls ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                      label: demo.showsControls ? "Hide sections" : "Show sections", id: "sandbox-sections-toggle",
                      enabled: true) {
                demo.showsControls.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playground")
    }

    private func barButton(_ icon: String, label: String, id: String, enabled: Bool,
                           change: @escaping () -> Void) -> some View {
        Button {
            TronHaptics.shared.play(.selectionChanged)
            withAnimation(sheet.motion.spring) {
                demo.page = nil
                change()
            }
        } label: {
            Image(systemName: icon)
                .font(TronTypography.buttonSM)
                .foregroundStyle(enabled ? Color.tronPrimary : Color.tronTextDisabled)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Color.tronPrimary.opacity(enabled ? 0.12 : 0.05)))
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
