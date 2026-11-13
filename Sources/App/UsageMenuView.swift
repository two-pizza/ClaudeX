import Cocoa

/// The panel inside the dropdown: provider sections with limit bars and reset times.
/// Drawn by hand - it is easier to keep the same proportions as the /usage screen
/// than to assemble a constraint stack for a static layout.
final class UsageMenuView: NSView {

    private enum Metrics {
        static let width: CGFloat = 300
        static let sidePadding: CGFloat = 16
        static let topPadding: CGFloat = 12
        static let headerHeight: CGFloat = 34
        static let rowHeight: CGFloat = 52
        static let noteHeight: CGFloat = 24
        static let footerHeight: CGFloat = 24
        static let dividerHeight: CGFloat = 9
        static let barHeight: CGFloat = 6
    }

    private typealias Element = UsagePanelElement
    private var elements: [Element] = []

    func render(snapshot: CombinedSnapshot, errors: [String: String],
                statuses: [String: RefreshStatus]) {
        apply(UsagePanelContent.make(snapshot: snapshot, errors: errors,
                                    statuses: statuses, now: Date()))
    }

    private func apply(_ items: [Element]) {
        elements = items
        let height = items.reduce(Metrics.topPadding * 2) { $0 + Self.height(of: $1) }
        setFrameSize(NSSize(width: Metrics.width, height: height))
        needsDisplay = true
    }

    private static func height(of element: Element) -> CGFloat {
        switch element {
        case .header:  return Metrics.headerHeight
        case .row:     return Metrics.rowHeight
        case .note, .warning: return Metrics.noteHeight
        case .footer:  return Metrics.footerHeight
        case .divider: return Metrics.dividerHeight
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        var y = bounds.height - Metrics.topPadding
        let contentWidth = bounds.width - Metrics.sidePadding * 2

        for element in elements {
            let elementHeight = Self.height(of: element)
            y -= elementHeight
            let frame = NSRect(x: Metrics.sidePadding, y: y, width: contentWidth, height: elementHeight)

            switch element {
            case .header(let title, let trailing):
                draw(title, font: .systemFont(ofSize: 13, weight: .semibold),
                     color: .labelColor, in: frame, aligned: .left, baselineFromTop: 6)
                if !trailing.isEmpty {
                    draw(trailing, font: .systemFont(ofSize: 12),
                         color: .secondaryLabelColor, in: frame, aligned: .right, baselineFromTop: 7)
                }
            case .row(let row):
                drawRow(row, in: frame)
            case .note(let text):
                draw(text, font: .systemFont(ofSize: 11),
                     color: .secondaryLabelColor, in: frame, aligned: .left, baselineFromTop: 4)
            case .warning(let text):
                draw(text, font: .systemFont(ofSize: 11),
                     color: .systemOrange, in: frame, aligned: .left, baselineFromTop: 4)
            case .footer(let text):
                draw(text, font: .systemFont(ofSize: 11),
                     color: .tertiaryLabelColor, in: frame, aligned: .left, baselineFromTop: 6)
            case .divider:
                let lineRect = NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: 1)
                NSColor.separatorColor.setFill()
                lineRect.fill()
            }
        }
    }

    private func drawRow(_ row: UsageRow, in frame: NSRect) {
        draw(row.title, font: .systemFont(ofSize: 12, weight: row.isActive ? .medium : .regular),
             color: .labelColor, in: frame, aligned: .left, baselineFromTop: 2)
        draw(String(format: "%.0f%%", row.percent),
             font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
             color: Self.color(for: row.percent), in: frame, aligned: .right, baselineFromTop: 2)

        let barY = frame.maxY - 23
        let track = NSRect(x: frame.minX, y: barY, width: frame.width, height: Metrics.barHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()

        let fraction = max(0, min(row.percent, 100)) / 100
        if fraction > 0 {
            // Below 2 pt the bar degenerates into a dot - keep a minimum visible width.
            let filledWidth = max(track.width * fraction, Metrics.barHeight)
            let filled = NSRect(x: track.minX, y: track.minY, width: filledWidth, height: track.height)
            Self.color(for: row.percent).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        }

        if let reset = Self.resetText(row) {
            draw(reset, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor,
                 in: frame, aligned: .left, baselineFromTop: 30)
        }
    }

    private func draw(_ text: String, font: NSFont, color: NSColor,
                      in frame: NSRect, aligned: NSTextAlignment, baselineFromTop: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let x = aligned == .right ? frame.maxX - size.width : frame.minX
        let origin = NSPoint(x: x, y: frame.maxY - baselineFromTop - size.height)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    // MARK: Formatting

    static func color(for percent: Double) -> NSColor {
        switch percent {
        case 90...:  return .systemRed
        case 75..<90: return .systemOrange
        default:     return .systemBlue
        }
    }

    private static func resetText(_ row: UsageRow) -> String? { ResetText.make(row) }

}
