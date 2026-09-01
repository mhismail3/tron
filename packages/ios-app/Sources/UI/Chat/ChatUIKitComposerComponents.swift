import Foundation
@preconcurrency import UIKit

@MainActor
final class ChatUIKitComposerEditor: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard isScrollEnabled, let range = selectedTextRange else { return }
        scrollRangeToVisible(NSRange(location: offset(from: beginningOfDocument, to: range.end), length: 0))
    }
}

@MainActor
final class ChatUIKitComposerSurface: UIView {
    private let blur = UIVisualEffectView(effect: ChatUIKitTheme.material())
    private let tint = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = ChatUIKitComposerColors.border.resolvedColor(with: traitCollection).cgColor
        clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur); addSubview(tint)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor), blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor), tint.trailingAnchor.constraint(equalTo: trailingAnchor), tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var tintColor: UIColor! { didSet { tint.backgroundColor = tintColor } }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = ChatUIKitComposerColors.border.resolvedColor(with: traitCollection).cgColor
    }
}

@MainActor
final class ChatUIKitComposerAttachmentChip: UIView {
    var onPreview: (() -> Void)?
    var onRemove: (() -> Void)?
    private let preview = UIButton(type: .system)
    init(attachment: PendingAttachment) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true
        preview.frame = bounds
        preview.translatesAutoresizingMaskIntoConstraints = false
        let image = attachment.preparedThumbnail.map { UIImage(cgImage: $0.image) }
        preview.setImage(image ?? UIImage(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text"), for: .normal)
        preview.tintColor = ChatUIKitComposerColors.blue
        preview.backgroundColor = ChatUIKitComposerColors.blue.withAlphaComponent(0.10)
        preview.imageView?.contentMode = .scaleAspectFill
        preview.layer.cornerRadius = 14; preview.layer.cornerCurve = .continuous; preview.clipsToBounds = true
        preview.accessibilityLabel = "Preview \(attachment.name)"
        var facts = [attachment.mimeType]
        facts.append(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
        preview.accessibilityValue = facts.joined(separator: ", ")
        preview.accessibilityHint = attachment.mimeType.hasPrefix("image/") ? "Opens a photo preview" : "Opens the file preview"
        preview.addTarget(self, action: #selector(previewPressed), for: .primaryActionTriggered)
        addSubview(preview)
        NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.topAnchor.constraint(equalTo: topAnchor), preview.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark"), for: .normal)
        remove.tintColor = ChatUIKitComposerColors.primary
        remove.backgroundColor = ChatUIKitComposerColors.background.withAlphaComponent(0.92)
        remove.layer.cornerRadius = 11
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.accessibilityLabel = "Remove \(attachment.name)"
        remove.addTarget(self, action: #selector(removePressed), for: .primaryActionTriggered)
        addSubview(remove)
        NSLayoutConstraint.activate([remove.widthAnchor.constraint(equalToConstant: 22), remove.heightAnchor.constraint(equalToConstant: 22), remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 7), remove.topAnchor.constraint(equalTo: topAnchor, constant: -7)])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func previewPressed() { onPreview?() }
    @objc private func removePressed() { onRemove?() }
}

@MainActor
final class ChatUIKitComposerResourceChip: UIView {
    var onDetails: (() -> Void)?
    var onRemove: (() -> Void)?
    init(resource: ComposerResourceEntry) {
        super.init(frame: .zero)
        let accent = resource.kind == .skill ? ChatUIKitComposerColors.cyan : ChatUIKitComposerColors.purple
        let details = UIButton(type: .system)
        details.setTitle("  \(resource.friendlyName)  ", for: .normal)
        details.setImage(UIImage(systemName: resource.kind == .skill ? "sparkles" : "command"), for: .normal)
        details.tintColor = accent; details.setTitleColor(accent, for: .normal)
        details.titleLabel?.font = ChatUIKitComposerFonts.chip
        details.accessibilityLabel = "\(resource.kind == .skill ? "Skill" : "Command"), \(resource.friendlyName)"
        details.accessibilityHint = "Opens details"
        details.addTarget(self, action: #selector(detailsPressed), for: .primaryActionTriggered)
        details.translatesAutoresizingMaskIntoConstraints = false
        addSubview(details)
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        remove.tintColor = ChatUIKitComposerColors.muted
        remove.accessibilityLabel = "Remove \(resource.friendlyName)"
        remove.addTarget(self, action: #selector(removePressed), for: .primaryActionTriggered)
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([details.leadingAnchor.constraint(equalTo: leadingAnchor), details.topAnchor.constraint(equalTo: topAnchor), details.bottomAnchor.constraint(equalTo: bottomAnchor), remove.leadingAnchor.constraint(equalTo: details.trailingAnchor, constant: 2), remove.trailingAnchor.constraint(equalTo: trailingAnchor), remove.centerYAnchor.constraint(equalTo: details.centerYAnchor), remove.widthAnchor.constraint(equalToConstant: 30), remove.heightAnchor.constraint(equalToConstant: 30), heightAnchor.constraint(equalToConstant: 34)])
        backgroundColor = accent.withAlphaComponent(0.15); layer.cornerRadius = 16; layer.cornerCurve = .continuous
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func detailsPressed() { onDetails?() }
    @objc private func removePressed() { onRemove?() }
}

@MainActor
final class ChatUIKitComposerContextButton: UIButton {
    private var presentation = SessionContextProgressPresentation(contextPercentage: 0, modelName: nil, isCompacting: false, isEnabled: false)
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(track)
        layer.addSublayer(progress)
        track.fillColor = UIColor.clear.cgColor
        progress.fillColor = UIColor.clear.cgColor
        track.lineWidth = 2
        progress.lineWidth = 2.5
        track.lineCap = .round
        progress.lineCap = .round
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(1, min(bounds.width, bounds.height) * 0.20)
        let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true).cgPath
        track.path = path; progress.path = path
        track.frame = bounds; progress.frame = bounds
    }

    func apply(_ value: SessionContextProgressPresentation, reduceMotion: Bool) {
        presentation = value
        let bounded = min(max(value.contextPercentage, 0), 100)
        let accent = value.isEnabled
            ? (bounded >= 95 ? ChatUIKitComposerColors.error : bounded >= 80 ? ChatUIKitComposerColors.amber : ChatUIKitComposerColors.emerald)
            : ChatUIKitComposerColors.muted
        track.strokeColor = ChatUIKitComposerColors.muted.withAlphaComponent(0.34).cgColor
        progress.strokeColor = accent.cgColor
        progress.strokeEnd = CGFloat(bounded) / 100
        isEnabled = value.isEnabled; alpha = value.isEnabled ? 1 : 0.56
        accessibilityLabel = "Manage Session"
        var parts = value.modelName.map { [$0] } ?? []
        parts.append(value.isEnabled ? "\(bounded)% context used" : "Session context loading")
        if value.isCompacting { parts.append("compacting") }
        accessibilityValue = parts.joined(separator: ", ")
        accessibilityHint = "Shows context usage, model selection, and session actions"
        if !reduceMotion {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
            progress.strokeEnd = CGFloat(bounded) / 100
            CATransaction.commit()
        }
    }
}

@MainActor
final class ChatUIKitResourcePickerView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onSelect: ((ComposerResourceEntry) -> Void)?
    var onDetails: ((ComposerResourceEntry) -> Void)?
    var onDismiss: (() -> Void)?
    private let titleLabel = UILabel()
    private let queryLabel = UILabel()
    private let dismissButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .plain)
    private var entries: [ComposerResourceEntry] = []
    private var kind: ComposerResourceEntry.Kind = .command
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16; layer.cornerCurve = .continuous; clipsToBounds = true
        backgroundColor = ChatUIKitComposerColors.background.withAlphaComponent(0.94)
        titleLabel.font = ChatUIKitComposerFonts.title; queryLabel.font = ChatUIKitComposerFonts.caption; queryLabel.textColor = ChatUIKitComposerColors.secondary
        dismissButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal); dismissButton.tintColor = ChatUIKitComposerColors.muted; dismissButton.accessibilityLabel = "Dismiss resource picker"; dismissButton.addTarget(self, action: #selector(dismissPressed), for: .primaryActionTriggered)
        let header = UIStackView(arrangedSubviews: [titleLabel, queryLabel, UIView(), dismissButton]); header.axis = .horizontal; header.alignment = .center; header.spacing = 6; header.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self; table.delegate = self; table.rowHeight = 48; table.separatorStyle = .none; table.backgroundColor = .clear; table.register(UITableViewCell.self, forCellReuseIdentifier: "resource")
        table.translatesAutoresizingMaskIntoConstraints = false; addSubview(header); addSubview(table)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7), header.topAnchor.constraint(equalTo: topAnchor, constant: 6), dismissButton.widthAnchor.constraint(equalToConstant: 36), dismissButton.heightAnchor.constraint(equalToConstant: 36), table.leadingAnchor.constraint(equalTo: leadingAnchor), table.trailingAnchor.constraint(equalTo: trailingAnchor), table.topAnchor.constraint(equalTo: header.bottomAnchor), table.bottomAnchor.constraint(equalTo: bottomAnchor), heightAnchor.constraint(greaterThanOrEqualToConstant: 54)])
        heightConstraint = heightAnchor.constraint(equalToConstant: 54); heightConstraint?.isActive = true
        accessibilityLabel = "Resource picker"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(kind: ComposerResourceEntry.Kind?, query: String, entries: [ComposerResourceEntry], keyboardVisible: Bool, reduceMotion: Bool) {
        guard let kind else { return }
        self.kind = kind; self.entries = entries
        titleLabel.text = kind == .skill ? "Skills" : "Commands"; queryLabel.text = query.isEmpty ? nil : "· \"\(query)\""; queryLabel.isHidden = query.isEmpty
        table.reloadData()
        let rows = ComposerResourcePanelPolicy.visibleRows(entryCount: entries.count, keyboardVisible: keyboardVisible)
        heightConstraint?.constant = CGFloat(54 + max(rows, entries.isEmpty ? 0 : 1) * 48)
        if !reduceMotion { alpha = 0; UIView.animate(withDuration: 0.18) { self.alpha = 1 } }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "resource", for: indexPath)
        let entry = entries[indexPath.row]; cell.backgroundColor = .clear; cell.textLabel?.text = entry.friendlyName; cell.textLabel?.font = ChatUIKitComposerFonts.body; cell.textLabel?.textColor = ChatUIKitComposerColors.primary; cell.imageView?.image = UIImage(systemName: kind == .skill ? "sparkles" : "command"); cell.imageView?.tintColor = kind == .skill ? ChatUIKitComposerColors.cyan : ChatUIKitComposerColors.purple; cell.accessibilityLabel = "\(kind == .skill ? "Skill" : "Command"), \(entry.displayName)"; cell.accessibilityHint = "Selects resource"; return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); onSelect?(entries[indexPath.row]) }
    @objc private func dismissPressed() { onDismiss?() }
}

enum ChatUIKitComposerColors {
    static let background = ChatUIKitTheme.background
    static let primary = ChatUIKitTheme.primary
    static let secondary = ChatUIKitTheme.secondary
    static let muted = ChatUIKitTheme.muted
    static let emerald = ChatUIKitTheme.emerald
    static let cyan = ChatUIKitTheme.cyan
    static let purple = ChatUIKitTheme.purple
    static let amber = ChatUIKitTheme.amber
    static let error = ChatUIKitTheme.error
    static let blue = ChatUIKitTheme.blue
    static let border = ChatUIKitTheme.border
}

@MainActor
enum ChatUIKitComposerFonts {
    static var input: UIFont { UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeBodyLG, weight: .regular)) }
    static var body: UIFont { UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeBody, weight: .regular)) }
    static var title: UIFont { UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeTitle, weight: .semibold)) }
    static var caption: UIFont { UIFontMetrics(forTextStyle: .caption1).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeCaption, weight: .regular)) }
    static var chip: UIFont { UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12, weight: .bold)) }
}
