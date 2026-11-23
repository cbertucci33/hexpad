import AppKit

/// First-launch "Welcome to Hexpad" splash.
///
/// Shown once on a fresh install. The checkbox at the bottom opts into showing
/// it again on every launch. The persistence rule lives in
/// ``shouldShow(defaults:)`` so it is testable without AppKit:
///
/// - no `welcomeSplashShowAgain` value at all  -> first launch, show
/// - `false` (the default the first close writes) -> do not show
/// - `true` (the user checked the box)            -> show again
///
/// The copy is the approved welcome text, verbatim, including paragraph
/// breaks. The GitHub URL is a live link in the read-only text view.
final class WelcomeWindowController: NSWindowController, NSTextViewDelegate {

    /// UserDefaults boolean. Absence means "never launched before"; the first
    /// close writes an explicit `false` unless the user checked the box.
    static let showAgainDefaultsKey = "welcomeSplashShowAgain"

    static let githubURLString = "https://github.com/cbertucci33/hexpad"

    /// Approved copy. Do not paraphrase or reflow; the blank lines are the
    /// paragraph breaks the card specifies.
    static let copyText = """
    Thank you for downloading!

    Hexpad is a fast and focused text and source code editor. Get your work done easily and cleanly. And more importantly, it's free!

    I built Hexpad because Notepad++ doesn't have a native MacOS version and I just wasn't happy with the alternatives. I hope this app helps your work.

    Remember to check my GitHub for updates, post issues or requests, or find other useful software. https://github.com/cbertucci33/hexpad
    """

    /// "Start Editing" primary button. Exposed for tests to drive the same
    /// action the user clicks.
    let startEditingButton = NSButton(title: "Start Editing", target: nil, action: nil)

    /// "Show this again on next launch" checkbox. Exposed so tests can toggle
    /// the state and then close through the real action.
    let showAgainCheckbox = NSButton(checkboxWithTitle: "Show this again on next launch",
                                     target: nil, action: nil)

    private let defaults: UserDefaults

    /// The window's last presentation request (key vs. order-front only).
    /// Test seam for the "do not steal focus on a restored session" rule.
    private(set) var lastPresentationRequestedKey = false

    // MARK: - First-launch rule

    /// Whether the splash should appear for this defaults store. A missing key
    /// is the only "first launch" signal; after the first close the key always
    /// exists (true or false).
    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showAgainDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: showAgainDefaultsKey)
    }

    // MARK: - Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Welcome to Hexpad"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Presentation

    /// Orders the splash front when the first-launch rule allows it. Returns
    /// whether the window was presented.
    ///
    /// `makeKey` is false when a session was restored: the splash is brought
    /// forward without taking key status from the editor the user is returning
    /// to. When it is a true first launch there is no session to protect, so
    /// the splash becomes key and Return activates Start Editing.
    @discardableResult
    func presentIfNeeded(makeKey: Bool) -> Bool {
        guard Self.shouldShow(defaults: defaults) else { return false }
        lastPresentationRequestedKey = makeKey
        // Deliberately not `showWindow(nil)`: that makes the window key. The
        // order-front path must leave a restored editor's key status alone.
        if makeKey {
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
        return true
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        // No Assets.xcassets ships an app icon yet, so the top mark is a large
        // text glyph. Swap this for an NSImageView once an icon asset exists.
        let iconLabel = NSTextField(labelWithString: "H")
        iconLabel.font = NSFont.systemFont(ofSize: 40, weight: .semibold)
        iconLabel.textColor = .controlAccentColor
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 20, y: 286, width: 380, height: 40)
        content.addSubview(iconLabel)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 88, width: 380, height: 190))
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 190))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.textStorage?.setAttributedString(makeAttributedCopy())
        scrollView.documentView = textView

        content.addSubview(scrollView)

        startEditingButton.bezelStyle = .rounded
        startEditingButton.keyEquivalent = "\r"
        startEditingButton.target = self
        startEditingButton.action = #selector(startEditing(_:))
        startEditingButton.frame = NSRect(x: 150, y: 46, width: 120, height: 32)
        content.addSubview(startEditingButton)

        showAgainCheckbox.state = defaults.bool(forKey: Self.showAgainDefaultsKey) ? .on : .off
        showAgainCheckbox.target = self
        showAgainCheckbox.action = #selector(showAgainChanged(_:))
        showAgainCheckbox.frame = NSRect(x: 20, y: 16, width: 380, height: 20)
        content.addSubview(showAgainCheckbox)
    }

    /// The approved copy as a non-editable attributed string. The URL gets an
    /// `.link` attribute so a click routes through ``textView(_:clickedOnLink:at:)``.
    private func makeAttributedCopy() -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: Self.copyText)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)
        let linkRange = (Self.copyText as NSString).range(of: Self.githubURLString)
        if linkRange.location != NSNotFound, let url = URL(string: Self.githubURLString) {
            attributed.addAttribute(.link, value: url, range: linkRange)
        }
        return attributed
    }

    // MARK: - Actions

    /// Start Editing and the window's red close button both persist the
    /// checkbox so the first-launch rule settles after one showing.
    @objc func startEditing(_ sender: Any?) {
        persistShowAgainPreference()
        window?.orderOut(nil)
    }

    /// Writes the current checkbox state. Called by the button and by
    /// `windowWillClose`, so closing with the red button also counts as "seen".
    private func persistShowAgainPreference() {
        defaults.set(showAgainCheckbox.state == .on, forKey: Self.showAgainDefaultsKey)
    }

    /// Persist the moment the box is toggled, so a Cmd+Q with the splash still
    /// open keeps the user's opt-in instead of dropping it.
    @objc func showAgainChanged(_ sender: Any?) {
        persistShowAgainPreference()
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let linkURL = link as? URL {
            url = linkURL
        } else if let linkString = link as? String {
            url = URL(string: linkString)
        } else {
            url = nil
        }
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

// MARK: - NSWindowDelegate

extension WelcomeWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        persistShowAgainPreference()
    }
}
