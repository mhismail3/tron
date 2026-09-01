import Foundation
@preconcurrency import UIKit

final class ChatUIKitTranscriptCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatUIKitTranscriptCell"

    private let markdownView = ChatUIKitMarkdownView()
    private let attachmentStack = UIStackView()
    private let toolLabel = UILabel()
    var onAttachmentTapped: ((Int) -> Void)?
    var onToolTapped: (() -> Void)?
    var onThinkingDetails: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(markdownView)

        toolLabel.translatesAutoresizingMaskIntoConstraints = false
        toolLabel.numberOfLines = 0
        toolLabel.font = .preferredFont(forTextStyle: .caption1)
        toolLabel.textColor = .secondaryLabel
        toolLabel.isUserInteractionEnabled = true
        contentView.addSubview(toolLabel)

        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentStack.axis = .vertical
        attachmentStack.spacing = 4
        contentView.addSubview(attachmentStack)

        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            markdownView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            markdownView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            toolLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            toolLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            toolLabel.topAnchor.constraint(equalTo: markdownView.bottomAnchor),
            attachmentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            attachmentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            attachmentStack.topAnchor.constraint(equalTo: toolLabel.bottomAnchor, constant: 4),
            attachmentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toolTapped))
        toolLabel.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: ChatUIKitTranscriptRow) {
        markdownView.render(row)
        markdownView.onThinkingDetails = onThinkingDetails ?? onToolTapped
        markdownView.accessibilityIdentifier = "chat-row-\(row.id)"
        toolLabel.text = row.toolLabel
        toolLabel.isHidden = row.toolLabel == nil
        attachmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, name) in row.attachments.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(name, for: .normal)
            button.contentHorizontalAlignment = .leading
            button.accessibilityLabel = "Attachment \(name)"
            button.tag = index
            button.addTarget(self, action: #selector(attachmentTapped(_:)), for: .touchUpInside)
            attachmentStack.addArrangedSubview(button)
        }
        attachmentStack.isHidden = row.attachments.isEmpty
    }

    @objc private func attachmentTapped(_ sender: UIButton) {
        onAttachmentTapped?(sender.tag)
    }

    @objc private func toolTapped() {
        onToolTapped?()
    }
}
