import AppKit

/// A date-group separator inside the status menu, hosted as a view-based,
/// disabled `NSMenuItem`. A left-aligned label (e.g. "Today", "4 Jun 26") sits
/// at the menu's content margin with a hairline rule filling the rest of the
/// width — a lightweight section divider rather than a selectable row.
final class MenuSectionHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let rule = NSBox()

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        rule.boxType = .separator   // system separator color, light/dark aware
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            rule.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.stringValue = title
    }

    /// Not interactive — fall through so the menu never treats the header as a
    /// selectable item.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
