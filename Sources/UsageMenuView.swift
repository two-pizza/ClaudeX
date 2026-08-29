import Cocoa

/// Панель внутри выпадающего меню: заголовок, полоски лимитов, время сброса.
/// Рисуется вручную — так проще держать те же пропорции, что в окне /usage,
/// чем собирать стек констрейнтов ради статичной раскладки.
final class UsageMenuView: NSView {

    private enum Metrics {
        static let width: CGFloat = 300
        static let sidePadding: CGFloat = 16
        static let topPadding: CGFloat = 12
        static let headerHeight: CGFloat = 32
        static let sectionHeight: CGFloat = 30
        static let rowHeight: CGFloat = 52
        static let footerHeight: CGFloat = 24
        static let barHeight: CGFloat = 6
    }

    private enum Element {
        case header(title: String, trailing: String)
        case section(String)
        case row(UsageRow)
        case note(String)
        case footer(String)
    }

    private var elements: [Element] = []

    // MARK: Наполнение

    func render(snapshot: UsageSnapshot) {
        var items: [Element] = [.header(title: "Plan usage limits", trailing: snapshot.plan)]
        if let session = snapshot.session { items.append(.row(session)) }
        if !snapshot.weekly.isEmpty {
            items.append(.section("Weekly limits"))
            items.append(contentsOf: snapshot.weekly.map { Element.row($0) })
        }
        if let credits = snapshot.credits { items.append(.note(credits)) }
        items.append(.footer("Обновлено \(Self.relativeStamp(snapshot.fetchedAt))"))
        apply(items)
    }

    func render(error: Error, lastSnapshot: UsageSnapshot?) {
        var items: [Element] = [.header(title: "Plan usage limits", trailing: "")]
        items.append(.note(error.localizedDescription))
        if let last = lastSnapshot {
            if let session = last.session { items.append(.row(session)) }
            items.append(contentsOf: last.weekly.map { Element.row($0) })
            items.append(.footer("Последние данные: \(Self.relativeStamp(last.fetchedAt))"))
        }
        apply(items)
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
        case .section: return Metrics.sectionHeight
        case .row:     return Metrics.rowHeight
        case .note:    return Metrics.footerHeight
        case .footer:  return Metrics.footerHeight
        }
    }

    // MARK: Отрисовка

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
                     color: .labelColor, in: frame, aligned: .left, baselineFromTop: 4)
                if !trailing.isEmpty {
                    draw(trailing, font: .systemFont(ofSize: 12),
                         color: .secondaryLabelColor, in: frame, aligned: .right, baselineFromTop: 5)
                }
            case .section(let title):
                draw(title, font: .systemFont(ofSize: 12, weight: .semibold),
                     color: .secondaryLabelColor, in: frame, aligned: .left, baselineFromTop: 12)
            case .row(let row):
                drawRow(row, in: frame)
            case .note(let text):
                draw(text, font: .systemFont(ofSize: 11),
                     color: .secondaryLabelColor, in: frame, aligned: .left, baselineFromTop: 4)
            case .footer(let text):
                draw(text, font: .systemFont(ofSize: 11),
                     color: .tertiaryLabelColor, in: frame, aligned: .left, baselineFromTop: 4)
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
            // Ниже 2 pt полоска вырождается в точку — держим минимальную видимую ширину.
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

    // MARK: Форматирование

    static func color(for percent: Double) -> NSColor {
        switch percent {
        case 90...:  return .systemRed
        case 75..<90: return .systemOrange
        default:     return .systemBlue
        }
    }

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE HH:mm"
        return f
    }()

    private static func resetText(_ row: UsageRow) -> String? {
        guard let resetsAt = row.resetsAt else { return nil }
        if row.isSession {
            let seconds = max(0, resetsAt.timeIntervalSinceNow)
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "сброс через \(hours) ч \(minutes) мин"
                             : "сброс через \(minutes) мин"
        }
        return "сброс \(weekdayTime.string(from: resetsAt))"
    }

    static func relativeStamp(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:   return "только что"
        case ..<3600: return "\(seconds / 60) мин назад"
        default:      return "\(seconds / 3600) ч назад"
        }
    }
}
