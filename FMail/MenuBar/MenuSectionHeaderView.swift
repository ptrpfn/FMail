import AppKit

/// A separator label inside the status menu, hosted as a view-based, disabled
/// `NSMenuItem`. Two styles:
///
///   - `.block`: a prominent block divider ("Priority Messages" / "Other
///     Messages") — a semibold label at the content margin with a hairline
///     rule filling the rest of the width.
///   - `.date`: a date sub-header nested inside a block ("Today", "4 Jun 26")
///     — a smaller, indented, subdued label with no rule.
final class MenuSectionHeaderView: NSView {
    enum Style { case block, date }

    private let label = NSTextField(labelWithString: "")
    private let rule = NSBox()

    init(width: CGFloat, style: Style) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: style == .block ? 24 : 20))

        switch style {
        case .block:
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .labelColor
        case .date:
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        // Block dividers extend a rule to the right of the label; date
        // sub-headers are just an indented label.
        let leading: CGFloat = style == .block ? 20 : 30
        var constraints: [NSLayoutConstraint] = [
            widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if style == .block {
            rule.boxType = .separator   // system separator color, light/dark aware
            rule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rule)
            constraints += [
                rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
                rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                rule.centerYAnchor.constraint(equalTo: centerYAnchor),
                rule.heightAnchor.constraint(equalToConstant: 1),
            ]
        }
        NSLayoutConstraint.activate(constraints)
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
