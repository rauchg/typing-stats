import Cocoa
import Sparkle

class HyperlinkTextField: NSTextField {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

class AboutWindowController: NSWindowController, NSTextFieldDelegate {
    private let updateChecker: UpdateChecker
    private var updateStatusLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var checkmarkIcon: NSImageView!

    init(updateChecker: UpdateChecker) {
        self.updateChecker = updateChecker

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
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

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // App icon
        let iconView = NSImageView(frame: NSRect(x: 115, y: 120, width: 64, height: 64))
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            iconView.image = icon
        }
        contentView.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "Typing Stats")
        nameLabel.frame = NSRect(x: 0, y: 95, width: 300, height: 20)
        nameLabel.alignment = .center
        nameLabel.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(nameLabel)

        // Version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.frame = NSRect(x: 0, y: 75, width: 300, height: 16)
        versionLabel.alignment = .center
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        contentView.addSubview(versionLabel)

        // Update status container (centered)
        let statusContainer = NSView(frame: NSRect(x: 0, y: 55, width: 300, height: 16))
        contentView.addSubview(statusContainer)

        // Progress indicator (left of text)
        progressIndicator = NSProgressIndicator(frame: NSRect(x: 85, y: 0, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.startAnimation(nil)
        statusContainer.addSubview(progressIndicator)

        // Checkmark icon (hidden initially)
        checkmarkIcon = NSImageView(frame: NSRect(x: 85, y: 0, width: 16, height: 16))
        let checkmark = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Up to date")
        checkmarkIcon.image = checkmark
        checkmarkIcon.contentTintColor = .systemGreen
        checkmarkIcon.isHidden = true
        statusContainer.addSubview(checkmarkIcon)

        // Update status label
        updateStatusLabel = NSTextField(labelWithString: "Checking for updates...")
        updateStatusLabel.frame = NSRect(x: 105, y: 0, width: 180, height: 16)
        updateStatusLabel.alignment = .left
        updateStatusLabel.font = NSFont.systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.delegate = self
        statusContainer.addSubview(updateStatusLabel)

        // Separator line
        let separator = NSBox(frame: NSRect(x: 20, y: 38, width: 260, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        // Author
        let authorLabel = HyperlinkTextField()
        authorLabel.frame = NSRect(x: 0, y: 12, width: 300, height: 16)
        authorLabel.alignment = .center
        authorLabel.font = NSFont.systemFont(ofSize: 11)
        authorLabel.isSelectable = true
        authorLabel.allowsEditingTextAttributes = true
        authorLabel.isBezeled = false
        authorLabel.drawsBackground = false
        authorLabel.isEditable = false

        let authorString = NSMutableAttributedString(string: "By Guillermo Rauch (")
        authorString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: authorString.length))
        authorString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: authorString.length))

        let linkString = NSMutableAttributedString(string: "source code")
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
        contentView.addSubview(authorLabel)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        checkForUpdates()
    }

    private func checkForUpdates() {
        updateStatusLabel.stringValue = "Checking for updates..."
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        checkmarkIcon.isHidden = true

        // Check using Sparkle's updater
        let updater = updateChecker.updater

        updater.checkForUpdatesInBackground()

        // Poll for result after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateCheckComplete()
        }
    }

    private func updateCheckComplete() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true

        if let version = updateChecker.availableVersion {
            // Update found - show clickable install link
            let linkString = NSMutableAttributedString(string: "Update available (v\(version)) – Install")
            let installRange = (linkString.string as NSString).range(of: "Install")
            linkString.addAttribute(.link, value: "sparkle://install", range: installRange)
            linkString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: linkString.length))
            linkString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: installRange.location))
            updateStatusLabel.allowsEditingTextAttributes = true
            updateStatusLabel.isSelectable = true
            updateStatusLabel.attributedStringValue = linkString
            checkmarkIcon.isHidden = true
        } else {
            updateStatusLabel.stringValue = "You're up to date"
            checkmarkIcon.isHidden = false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, clickedOnLink link: Any) -> Bool {
        if let url = link as? String, url == "sparkle://install" {
            updateChecker.checkForUpdates()
            return true
        }
        return false
    }
}
