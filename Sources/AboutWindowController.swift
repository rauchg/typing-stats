import Cocoa
import Sparkle

class AboutWindowController: NSWindowController {
    private let updateChecker: UpdateChecker
    private var updateStatusLabel: NSTextField!
    private var installButton: NSButton!
    private var progressIndicator: NSProgressIndicator!
    private var checkmarkIcon: NSImageView!
    private var statusStack: NSStackView!

    init(updateChecker: UpdateChecker) {
        self.updateChecker = updateChecker

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Typing Stats"
        window.center()

        super.init(window: window)

        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = window else { return }

        // App icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            iconView.image = icon
        }
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .vertical)

        // App name
        let nameLabel = NSTextField(labelWithString: "Typing Stats")
        nameLabel.alignment = .center
        nameLabel.font = NSFont.boldSystemFont(ofSize: 14)

        // Version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let versionString = isDevBuild ? "Version \(version)-dev" : "Version \(version)"
        let versionLabel = NSTextField(labelWithString: versionString)
        versionLabel.alignment = .center
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        // Update status row (spinner/checkmark + label)
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16)
        ])
        progressIndicator.startAnimation(nil)

        checkmarkIcon = NSImageView()
        checkmarkIcon.translatesAutoresizingMaskIntoConstraints = false
        let checkmark = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Up to date")
        checkmarkIcon.image = checkmark
        checkmarkIcon.contentTintColor = .systemGreen
        checkmarkIcon.isHidden = true
        NSLayoutConstraint.activate([
            checkmarkIcon.widthAnchor.constraint(equalToConstant: 16),
            checkmarkIcon.heightAnchor.constraint(equalToConstant: 16)
        ])

        updateStatusLabel = NSTextField(labelWithString: "Checking for updates...")
        updateStatusLabel.font = NSFont.systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor

        installButton = NSButton(title: "Install", target: self, action: #selector(installUpdate))
        installButton.isBordered = false
        installButton.font = NSFont.systemFont(ofSize: 11)
        installButton.contentTintColor = .linkColor
        let title = NSMutableAttributedString(string: "Install")
        title.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: title.length))
        title.addAttribute(.foregroundColor, value: NSColor.linkColor, range: NSRange(location: 0, length: title.length))
        title.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: title.length))
        installButton.attributedTitle = title
        installButton.isHidden = true

        statusStack = NSStackView(views: [progressIndicator, checkmarkIcon, updateStatusLabel, installButton])
        statusStack.orientation = .horizontal
        statusStack.spacing = 6
        statusStack.alignment = .centerY

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Author with link
        let authorLabel = NSTextField()
        authorLabel.isEditable = false
        authorLabel.isBordered = false
        authorLabel.drawsBackground = false
        authorLabel.isSelectable = true
        authorLabel.allowsEditingTextAttributes = true
        authorLabel.alignment = .center

        let authorString = NSMutableAttributedString(string: "By Guillermo Rauch (")
        authorString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: authorString.length))
        authorString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: authorString.length))

        let linkString = NSMutableAttributedString(string: "source")
        linkString.addAttribute(.link, value: "https://github.com/rauchg/typing-stats", range: NSRange(location: 0, length: linkString.length))
        linkString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: linkString.length))

        let closeParen = NSMutableAttributedString(string: ")")
        closeParen.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: closeParen.length))
        closeParen.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: closeParen.length))

        authorString.append(linkString)
        authorString.append(closeParen)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        authorString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: authorString.length))

        authorLabel.attributedStringValue = authorString

        // Main vertical stack
        let mainStack = NSStackView(views: [iconView, nameLabel, versionLabel, statusStack, separator, authorLabel])
        mainStack.orientation = .vertical
        mainStack.spacing = 8
        mainStack.alignment = .centerX
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.setCustomSpacing(4, after: nameLabel)
        mainStack.setCustomSpacing(12, after: versionLabel)
        mainStack.setCustomSpacing(12, after: statusStack)
        mainStack.setCustomSpacing(12, after: separator)

        window.contentView?.addSubview(mainStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            separator.widthAnchor.constraint(equalTo: mainStack.widthAnchor, multiplier: 0.9),
            mainStack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            mainStack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            mainStack.leadingAnchor.constraint(greaterThanOrEqualTo: window.contentView!.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(lessThanOrEqualTo: window.contentView!.trailingAnchor, constant: -20)
        ])
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        checkForUpdates()
    }

    private func checkForUpdates() {
        updateStatusLabel.stringValue = "Checking for updates..."
        updateStatusLabel.textColor = .secondaryLabelColor
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        checkmarkIcon.isHidden = true

        updateChecker.updater.checkForUpdatesInBackground()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateCheckComplete()
        }
    }

    private func updateCheckComplete() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true

        if let version = updateChecker.availableVersion {
            updateStatusLabel.stringValue = "v\(version) available –"
            installButton.isHidden = false
            checkmarkIcon.isHidden = true
        } else {
            updateStatusLabel.stringValue = "Up to date"
            installButton.isHidden = true
            checkmarkIcon.isHidden = false
        }
    }

    @objc private func installUpdate() {
        updateChecker.checkForUpdates()
        NSApp.activate(ignoringOtherApps: true)
    }
}
