import AppKit

/// A view-based menu item host for a live search field. Embedding an editable
/// control inside a tracking `NSMenu` is the one genuinely fragile part of the
/// menu-bar UI: the menu runs its own event-tracking loop, so the field only
/// receives keystrokes while it is the first responder of the menu's window.
/// We grab first-responder status as soon as the view is shown; on current
/// macOS that's enough for typing to land in the field.
final class MenuSearchFieldView: NSView, NSSearchFieldDelegate {
    let field = FocusKickingSearchField()
    /// Called on every keystroke with the current trimmed-or-raw string.
    var onChange: ((String) -> Void)?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.placeholderString = "Search…"
        field.focusRingType = .none
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    /// Focus the field and show the caret as soon as the menu's window hosts
    /// this view. `selectText` (rather than a bare `makeFirstResponder`)
    /// establishes the field editor the way a click on the search icon does —
    /// which is what reliably brings up the insertion point inside a menu.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKey()
            self.field.selectText(nil)
        }
    }
}

/// `NSSearchField` that re-kicks the insertion-point blink timer every time it
/// gains focus. Inside a menu window the caret otherwise frequently fails to
/// appear on the first focus (only showing after the field is focused a second
/// time), and clicking the text area of an already-focused field doesn't
/// refresh it. Restarting the timer on `becomeFirstResponder` makes the caret
/// appear consistently.
final class FocusKickingSearchField: NSSearchField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeKey()
                if let editor = self?.currentEditor() as? NSTextView {
                    editor.updateInsertionPointStateAndRestartTimer(true)
                }
            }
        }
        return ok
    }
}
