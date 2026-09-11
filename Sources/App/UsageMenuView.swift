import Cocoa

/// The panel inside the dropdown: one card per provider.
///
/// Each card leads with what is left of the session - the number that runs
/// out first - then the weekly window, then per-model windows folded behind
/// "Model limits". Freshness is per card: a provider that failed keeps its
/// last numbers, dimmed, with the time of the last success next to the error.
///
/// Drawn by hand: the layout is static and a constraint stack would be more
/// code than the drawing.
final class UsageMenuView: NSView {

    private enum Metrics {
        static let width: CGFloat = 320
        static let sidePadding: CGFloat = 12
        static let topPadding: CGFloat = 10
        static let cardPadding: CGFloat = 12
        static let cardGap: CGFloat = 8
        static let cardRadius: CGFloat = 10

        static let headerHeight: CGFloat = 26
        static let headlineHeight: CGFloat = 40
        static let barHeight: CGFloat = 6
        static let barRowHeight: CGFloat = 12
        static let statusHeight: CGFloat = 22
        static let ruleHeight: CGFloat = 13
        static let limitHeight: CGFloat = 36
        static let toggleHeight: CGFloat = 22
        static let noteHeight: CGFloat = 20
        static let footerHeight: CGFloat = 20
        static let panelFooterHeight: CGFloat = 22
    }

    private enum Element {
        case header(title: String, plan: String)
        case headline(remaining: Double, label: String)
        case bar(remaining: Double)
        case status(left: String, leftLevel: RemainingLevel?, right: String)
        case rule
        case limit(UsageRow)
        case toggle(provider: String, expanded: Bool, count: Int)
        case note(String)
        case footer(text: String, stale: Bool)
        case panelFooter(String)
    }

    /// An element with the card it belongs to (nil = outside any card) and
    /// whether the card is showing stale numbers.
    private struct Placed {
        let element: Element
        let card: Int?
        let dimmed: Bool
    }

    private var placed: [Placed] = []
    private var toggleRects: [String: NSRect] = [:]
    private var expanded: Set<String> = []
    private var lastSnapshot: CombinedSnapshot?
    private var lastErrors: [String: String] = [:]

    // MARK: Content

    func render(snapshot: CombinedSnapshot, errors: [String: String]) {
        lastSnapshot = snapshot
        lastErrors = errors

        var items: [Placed] = []
        var card = 0

        for provider in snapshot.providers {
            let error = errors[provider.id]
            let dimmed = error != nil
            func add(_ element: Element) { items.append(Placed(element: element, card: card, dimmed: dimmed)) }

            add(.header(title: provider.title, plan: provider.plan))

            if let session = provider.sessionRow {
                let label = session.isSession ? "session left" : "\(session.title.lowercased()) left"
                add(.headline(remaining: session.remaining, label: label))
                add(.bar(remaining: session.remaining))
                add(.status(left: Self.statusText(for: session),
                            leftLevel: RemainingLevel(remaining: session.remaining),
                            right: Self.resetText(session, capitalized: true) ?? ""))
            }

            if let weekly = provider.weeklyRow {
                add(.rule)
                add(.limit(weekly))
                let models = provider.modelRows
                if !models.isEmpty {
                    let isOpen = expanded.contains(provider.id)
                    add(.toggle(provider: provider.id, expanded: isOpen, count: models.count))
                    if isOpen { models.forEach { add(.limit($0)) } }
                }
            }

            if let credits = provider.credits { add(.note(credits)) }

            if let error {
                add(.footer(text: "Stale · last update \(Self.relativeStamp(provider.fetchedAt))", stale: true))
                add(.note(error))
            } else {
                add(.footer(text: "Updated \(Self.relativeStamp(provider.fetchedAt))", stale: false))
            }
            card += 1
        }

        // Providers that never succeeded: a card with the error, no fake numbers.
        for (id, message) in errors.sorted(by: { $0.key < $1.key })
        where !snapshot.providers.contains(where: { $0.id == id }) {
            items.append(Placed(element: .header(title: id.capitalized, plan: ""), card: card, dimmed: false))
            items.append(Placed(element: .note("No data yet"), card: card, dimmed: false))
            items.append(Placed(element: .note(message), card: card, dimmed: false))
            card += 1
        }

        if items.isEmpty {
            items.append(Placed(element: .note("Loading usage…"), card: nil, dimmed: false))
        } else {
            items.append(Placed(element: .panelFooter("Numbers are what is left in each window"),
                                card: nil, dimmed: false))
        }
        apply(items)
    }

    private func apply(_ items: [Placed]) {
        placed = items
        var height = Metrics.topPadding * 2
        var lastCard: Int? = nil
        for item in items {
            if item.card != lastCard {
                if lastCard != nil { height += Metrics.cardPadding + Metrics.cardGap }
                if item.card != nil { height += Metrics.cardPadding }
                lastCard = item.card
            }
            height += Self.height(of: item.element)
        }
        if lastCard != nil { height += Metrics.cardPadding }
        setFrameSize(NSSize(width: Metrics.width, height: height))
        needsDisplay = true
    }

    private static func height(of element: Element) -> CGFloat {
        switch element {
        case .header:      return Metrics.headerHeight
        case .headline:    return Metrics.headlineHeight
        case .bar:         return Metrics.barRowHeight
        case .status:      return Metrics.statusHeight
        case .rule:        return Metrics.ruleHeight
        case .limit:       return Metrics.limitHeight
        case .toggle:      return Metrics.toggleHeight
        case .note:        return Metrics.noteHeight
        case .footer:      return Metrics.footerHeight
        case .panelFooter: return Metrics.panelFooterHeight
        }
    }

    // MARK: Interaction

    /// The only interactive piece: the "Model limits" disclosure. A custom
    /// menu item view receives mouse events itself and the menu stays open.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = toggleRects.first(where: { $0.value.contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        if expanded.contains(hit.key) { expanded.remove(hit.key) } else { expanded.insert(hit.key) }
        if let lastSnapshot { render(snapshot: lastSnapshot, errors: lastErrors) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        toggleRects = [:]

        // Pass 1: lay out, remembering each card's extent.
        var frames: [(Placed, NSRect)] = []
        var cardBounds: [Int: NSRect] = [:]
        var y = bounds.height - Metrics.topPadding
        var lastCard: Int? = nil
        let outerWidth = bounds.width - Metrics.sidePadding * 2

        for item in placed {
            if item.card != lastCard {
                if lastCard != nil { y -= Metrics.cardPadding + Metrics.cardGap }
                if item.card != nil { y -= Metrics.cardPadding }
                lastCard = item.card
            }
            let h = Self.height(of: item.element)
            y -= h
            let inset = item.card == nil ? 0 : Metrics.cardPadding
            let frame = NSRect(x: Metrics.sidePadding + inset, y: y, width: outerWidth - inset * 2, height: h)
            frames.append((item, frame))
            if let card = item.card {
                let padded = frame.insetBy(dx: -Metrics.cardPadding, dy: 0)
                    .union(NSRect(x: frame.minX - Metrics.cardPadding, y: y - Metrics.cardPadding,
                                  width: 1, height: h + Metrics.cardPadding * 2))
                cardBounds[card] = cardBounds[card].map { $0.union(padded) } ?? padded
            }
        }

        // Pass 2: card backgrounds, then content.
        for (_, rect) in cardBounds {
            let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        for (item, frame) in frames {
            let alpha: CGFloat = item.dimmed ? 0.45 : 1
            draw(item.element, in: frame, alpha: alpha)
        }
    }

    private func draw(_ element: Element, in frame: NSRect, alpha: CGFloat) {
        switch element {
        case .header(let title, let plan):
            text(title, font: .systemFont(ofSize: 13, weight: .semibold),
                 color: .labelColor.withAlphaComponent(alpha), in: frame, aligned: .left, baselineFromTop: 4)
            if !plan.isEmpty {
                text(plan, font: .systemFont(ofSize: 12),
                     color: .secondaryLabelColor.withAlphaComponent(alpha), in: frame, aligned: .right, baselineFromTop: 5)
            }

        case .headline(let remaining, let label):
            let big = String(format: "%.0f%%", remaining)
            let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
            let bigColor = Self.color(remaining: remaining).withAlphaComponent(alpha)
            let bigSize = text(big, font: bigFont, color: bigColor, in: frame, aligned: .left, baselineFromTop: 2)
            let labelFrame = NSRect(x: frame.minX + bigSize.width + 8, y: frame.minY,
                                    width: frame.width - bigSize.width - 8, height: frame.height)
            text(label, font: .systemFont(ofSize: 12),
                 color: .secondaryLabelColor.withAlphaComponent(alpha), in: labelFrame, aligned: .left, baselineFromTop: 17)

        case .bar(let remaining):
            let track = NSRect(x: frame.minX, y: frame.midY - Metrics.barHeight / 2,
                               width: frame.width, height: Metrics.barHeight)
            bar(track, remaining: remaining, alpha: alpha)

        case .status(let left, let level, let right):
            let leftColor: NSColor
            switch level {
            case .critical?: leftColor = .systemRed
            case .low?:      leftColor = .systemOrange
            default:         leftColor = .secondaryLabelColor
            }
            text(left, font: .systemFont(ofSize: 11, weight: level == .fine || level == nil ? .regular : .medium),
                 color: leftColor.withAlphaComponent(alpha), in: frame, aligned: .left, baselineFromTop: 4)
            text(right, font: .systemFont(ofSize: 11),
                 color: .tertiaryLabelColor.withAlphaComponent(alpha), in: frame, aligned: .right, baselineFromTop: 4)

        case .rule:
            let line = NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: 1)
            NSColor.separatorColor.withAlphaComponent(alpha).setFill()
            line.fill()

        case .limit(let row):
            text(row.title, font: .systemFont(ofSize: 12, weight: row.isActive ? .medium : .regular),
                 color: .labelColor.withAlphaComponent(alpha), in: frame, aligned: .left, baselineFromTop: 2)
            text(String(format: "%.0f%% left", row.remaining),
                 font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                 color: Self.color(remaining: row.remaining).withAlphaComponent(alpha),
                 in: frame, aligned: .right, baselineFromTop: 2)
            if let reset = Self.resetText(row, capitalized: true) {
                text(reset, font: .systemFont(ofSize: 11),
                     color: .tertiaryLabelColor.withAlphaComponent(alpha), in: frame, aligned: .left, baselineFromTop: 19)
            }

        case .toggle(let provider, let isExpanded, let count):
            let glyph = isExpanded ? "▾" : "▸"
            let suffix = count == 1 ? "1 model" : "\(count) models"
            text("\(glyph) Model limits · \(suffix)", font: .systemFont(ofSize: 11, weight: .medium),
                 color: .secondaryLabelColor.withAlphaComponent(alpha), in: frame, aligned: .left, baselineFromTop: 4)
            toggleRects[provider] = frame

        case .note(let message):
            text(message, font: .systemFont(ofSize: 11),
                 color: .secondaryLabelColor, in: frame, aligned: .left, baselineFromTop: 3)

        case .footer(let message, let stale):
            text(message, font: .systemFont(ofSize: 11, weight: stale ? .medium : .regular),
                 color: stale ? .systemOrange : .tertiaryLabelColor, in: frame, aligned: .left, baselineFromTop: 3)

        case .panelFooter(let message):
            text(message, font: .systemFont(ofSize: 10),
                 color: .tertiaryLabelColor, in: frame, aligned: .center, baselineFromTop: 8)
        }
    }

    private func bar(_ track: NSRect, remaining: Double, alpha: CGFloat) {
        NSColor.quaternaryLabelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()

        let fraction = max(0, min(remaining, 100)) / 100
        // Nothing left draws nothing; anything left keeps a visible sliver.
        guard fraction > 0 else { return }
        let filledWidth = max(track.width * fraction, Metrics.barHeight)
        let filled = NSRect(x: track.minX, y: track.minY, width: filledWidth, height: track.height)
        Self.color(remaining: remaining).withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
    }

    @discardableResult
    private func text(_ string: String, font: NSFont, color: NSColor,
                      in frame: NSRect, aligned: NSTextAlignment, baselineFromTop: CGFloat) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        let x: CGFloat
        switch aligned {
        case .right:  x = frame.maxX - size.width
        case .center: x = frame.midX - size.width / 2
        default:      x = frame.minX
        }
        let origin = NSPoint(x: x, y: frame.maxY - baselineFromTop - size.height)
        (string as NSString).draw(at: origin, withAttributes: attributes)
        return size
    }

    // MARK: Formatting

    static func color(remaining: Double) -> NSColor {
        switch RemainingLevel(remaining: remaining) {
        case .critical: return .systemRed
        case .low:      return .systemOrange
        case .fine:     return .systemBlue
        }
    }

    private static func statusText(for row: UsageRow) -> String {
        let what = row.isSession ? "Session" : row.title
        switch RemainingLevel(remaining: row.remaining) {
        case .critical: return row.remaining <= 0 ? "\(what) used up" : "\(what) almost used up"
        case .low:      return "\(what) running low"
        case .fine:     return "\(what) available"
        }
    }

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    private static func resetText(_ row: UsageRow, capitalized: Bool) -> String? {
        guard let resetsAt = row.resetsAt else { return nil }
        let verb = capitalized ? "Resets" : "resets"
        if row.isSession {
            let seconds = max(0, resetsAt.timeIntervalSinceNow)
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "\(verb) in \(hours) h \(minutes) min" : "\(verb) in \(minutes) min"
        }
        return "\(verb) \(weekdayTime.string(from: resetsAt))"
    }

    static func relativeStamp(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:   return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        default:      return "\(seconds / 3600) h ago"
        }
    }
}
