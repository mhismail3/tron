import Foundation
@preconcurrency import UIKit

/// UIKit's transcript renderer is deliberately a row-local view tree. The
/// installed physical row remains the authority; this view only consumes its
/// immutable payload and keeps media work leased to ChatMediaLoader.
@MainActor
final class ChatUIKitHistoryCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatUIKitHistoryCell"
    private let button = UIButton(type: .system)
    private let spinner = ChatUIKitPulseLoadingView(accent: ChatUIKitTheme.emerald)
    private var action: (() -> Void)?
    private var presentationActive = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        button.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -24),
            spinner.widthAnchor.constraint(equalToConstant: 18),
            spinner.heightAnchor.constraint(equalToConstant: 18)
        ])
        button.addTarget(self, action: #selector(pressed), for: .primaryActionTriggered)
        button.titleLabel?.font = ChatUIKitFont.sans(12, .semibold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ state: ChatUIKitHistoryState, onLoad: @escaping () -> Void) {
        action = onLoad
        spinner.stopAnimating()
        spinner.isHidden = true
        button.setImage(nil, for: .normal)
        switch state {
        case .hidden: button.setTitle(nil, for: .normal); button.isHidden = true
        case .available:
            button.isHidden = false
            button.setTitle("Load earlier messages", for: .normal)
            button.isEnabled = true
        case .loading:
            button.isHidden = false
            button.setTitle("Loading earlier messages…", for: .normal)
            button.isEnabled = false
            spinner.isHidden = false
            if presentationActive { spinner.startAnimating() }
        case .failed(let message):
            button.isHidden = false
            button.setTitle(message.isEmpty ? "Retry earlier messages" : "Retry: \(message)", for: .normal)
            button.isEnabled = true
        }
    }

    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActive = activity.isActive
        if presentationActive && !spinner.isHidden { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        action = nil
        presentationActive = false
        spinner.stopAnimating()
        spinner.isHidden = true
        button.setTitle(nil, for: .normal)
        button.isHidden = false
    }

    @objc private func pressed() { action?() }
}
