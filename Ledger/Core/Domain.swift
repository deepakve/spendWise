import Foundation
import SwiftUI

// MARK: - Money (integer cents, never Double)

struct Money: Hashable, Comparable, Codable {
    var cents: Int
    init(_ cents: Int) { self.cents = cents }
    init(dollars: Double) { self.cents = Int((dollars * 100).rounded()) }

    static let zero = Money(0)
    var isNegative: Bool { cents < 0 }
    var abs: Money { Money(Swift.abs(cents)) }
    var dollars: Double { Double(cents) / 100 }

    static func + (l: Money, r: Money) -> Money { Money(l.cents + r.cents) }
    static func - (l: Money, r: Money) -> Money { Money(l.cents - r.cents) }
    static func < (l: Money, r: Money) -> Bool { l.cents < r.cents }
    static prefix func - (m: Money) -> Money { Money(-m.cents) }

    func formatted(cents showCents: Bool = true) -> String {
        (Decimal(cents) / 100).formatted(
            .currency(code: "USD").precision(.fractionLength(showCents ? 2 : 0)))
    }

    /// Tolerant parse: "$1,364.00", "-613.88", "(12.50)", "10.28".
    static func parse(_ raw: String) -> Money? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var neg = false
        if s.hasPrefix("(") && s.hasSuffix(")") { neg = true; s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("-") { neg = true; s.removeFirst() }
        s = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard let d = Decimal(string: s) else { return nil }
        var scaled = d * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let c = NSDecimalNumber(decimal: rounded).intValue
        return Money(neg ? -c : c)
    }
}

// MARK: - Category

enum Category: String, CaseIterable, Identifiable {
    case foodAndLiving = "Food & Living", eatOut = "Eat Out", car = "Car"
    case utilities = "Utilities", drinksOrSmokes = "Drinks or Smokes"
    case luxuryPersonal = "Luxury (Personal)", luxuryHome = "Luxury (Home)"
    case mortgageOrEMI = "Mortgage or EMI", interestOrFees = "Interest or Fees"
    case trading = "Trading", movies = "Movies", travel = "Travel"
    case gifts = "Gifts", audit = "Audit", others = "Others"
    case uncategorized = "Uncategorized"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .foodAndLiving: "cart"; case .eatOut: "fork.knife"; case .car: "car"
        case .utilities: "bolt"; case .drinksOrSmokes: "wineglass"
        case .luxuryPersonal: "sparkles"; case .luxuryHome: "house"
        case .mortgageOrEMI: "building.columns"; case .interestOrFees: "percent"
        case .trading: "chart.line.uptrend.xyaxis"; case .movies: "film"
        case .travel: "airplane"; case .gifts: "gift"
        case .audit: "doc.text.magnifyingglass"; case .others: "ellipsis.circle"
        case .uncategorized: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .foodAndLiving: .green; case .eatOut: .orange; case .car: .blue
        case .utilities: .yellow; case .drinksOrSmokes: .purple
        case .luxuryPersonal: .pink; case .luxuryHome: .teal
        case .mortgageOrEMI: .brown; case .interestOrFees: .red
        case .trading: .mint; case .movies: .indigo; case .travel: .cyan
        case .gifts: .red; case .audit: .gray; case .others: .gray
        case .uncategorized: .secondary
        }
    }

    static func lenient(_ raw: String) -> Category {
        let k = raw.lowercased().replacingOccurrences(of: " ", with: "")
                   .replacingOccurrences(of: "&", with: "and")
        for c in allCases where c.rawValue.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "&", with: "and") == k { return c }
        return .uncategorized
    }
}

// MARK: - Payer

enum Payer: String, CaseIterable, Identifiable {
    case us = "Us", deepu = "Deepu", subha = "Subha", friends = "Friends"
    var id: String { rawValue }
    var tint: Color {
        switch self { case .us: .blue; case .deepu: .orange
                      case .subha: .pink; case .friends: .green }
    }
}

// MARK: - Billing cycle (10th → 9th)

struct Cycle: Hashable, Identifiable {
    let start: Date, end: Date, key: String
    var id: String { key }

    var label: String { start.formatted(.dateTime.month(.wide).year()) }
    var shortLabel: String { start.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) }
    var rangeLabel: String {
        "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }
    func contains(_ d: Date) -> Bool { d >= start && d <= end }
    func progress(asOf now: Date = .now) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }
}

struct CycleCalendar {
    let anchorDay: Int
    private let cal: Calendar

    init(anchorDay: Int = 10, calendar: Calendar = .autoupdatingCurrent) {
        self.anchorDay = min(max(anchorDay, 1), 28)   // clamp: every month has it
        self.cal = calendar
    }

    /// Stable sortable key, e.g. "2026-06".
    static func key(for date: Date, anchorDay: Int = 10,
                    calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard var y = c.year, var m = c.month, let d = c.day else { return "" }
        if d < anchorDay { m -= 1; if m == 0 { m = 12; y -= 1 } }
        return String(format: "%04d-%02d", y, m)
    }

    func cycle(containing date: Date) -> Cycle {
        let k = Self.key(for: date, anchorDay: anchorDay, calendar: cal)
        return cycle(key: k)
    }

    func cycle(key: String) -> Cycle {
        let parts = key.split(separator: "-")
        let y = Int(parts.first ?? "2026") ?? 2026
        let m = Int(parts.last ?? "1") ?? 1
        var c = DateComponents(); c.year = y; c.month = m; c.day = anchorDay
        c.hour = 0; c.minute = 0; c.second = 0
        let start = cal.date(from: c) ?? .distantPast
        let nextStart = cal.date(byAdding: .month, value: 1, to: start) ?? start
        let end = cal.date(byAdding: .second, value: -1, to: nextStart) ?? nextStart
        return Cycle(start: start, end: end, key: key)
    }

    func next(_ c: Cycle) -> Cycle {
        cycle(containing: cal.date(byAdding: .month, value: 1, to: c.start) ?? c.start)
    }
    func previous(_ c: Cycle) -> Cycle {
        cycle(containing: cal.date(byAdding: .month, value: -1, to: c.start) ?? c.start)
    }

    /// Oldest first, ending with the cycle containing `date`.
    func recent(_ count: Int, endingAt date: Date = .now) -> [Cycle] {
        var out: [Cycle] = [], c = cycle(containing: date)
        for _ in 0..<max(count, 0) { out.append(c); c = previous(c) }
        return out.reversed()
    }
}

// MARK: - Per-card statement dates

struct StatementDates {
    private let cal = Calendar.autoupdatingCurrent

    func clamped(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        guard let first = cal.date(from: c),
              let range = cal.range(of: .day, in: .month, for: first) else { return .distantPast }
        c.day = min(day, range.count); c.hour = 0
        return cal.date(from: c) ?? .distantPast
    }

    func nextDue(dueDay: Int, after date: Date = .now) -> Date? {
        guard dueDay > 0 else { return nil }
        let c = cal.dateComponents([.year, .month], from: date)
        guard let y = c.year, let m = c.month else { return nil }
        var cand = clamped(year: y, month: m, day: dueDay)
        if cand <= cal.startOfDay(for: date) {
            let nm = cal.date(byAdding: .month, value: 1, to: cand) ?? cand
            let n = cal.dateComponents([.year, .month], from: nm)
            cand = clamped(year: n.year ?? y, month: n.month ?? m, day: dueDay)
        }
        return cand
    }

    func daysUntilDue(dueDay: Int, from date: Date = .now) -> Int? {
        guard let due = nextDue(dueDay: dueDay, after: date) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: date), to: due).day
    }

    /// The statement window that is currently open for this card.
    func openWindow(statementDay: Int, asOf date: Date = .now) -> (start: Date, end: Date)? {
        guard statementDay > 0 else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        let thisClose = clamped(year: y, month: m, day: statementDay)
        if d > statementDay {
            let next = cal.date(byAdding: .month, value: 1, to: thisClose) ?? thisClose
            return (cal.date(byAdding: .day, value: 1, to: thisClose) ?? thisClose, next)
        } else {
            let prev = cal.date(byAdding: .month, value: -1, to: thisClose) ?? thisClose
            return (cal.date(byAdding: .day, value: 1, to: prev) ?? prev, thisClose)
        }
    }
}
