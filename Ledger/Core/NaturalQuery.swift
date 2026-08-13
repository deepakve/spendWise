import Foundation
import CoreData

// Natural-language questions, answered on device.
//
// Why not call an LLM API: it would mean posting your ledger — every merchant,
// every amount, every person's name — to a server, plus an API key in the app
// and a per-question cost, for questions that are almost entirely structured:
// a date range, a card, a category, a person, an aggregate. That's a parsing
// problem, not a reasoning problem. This runs offline, instantly, free, and
// nothing leaves the phone.
//
// The parser handles the shapes you actually ask:
//   "spend from Aug 5 to Aug 15 on Amex"
//   "how much on eat out last month"
//   "what did I spend on Bindu"
//   "biggest purchases this cycle"
//   "how much did I spend at Costco in June"
//   "what do I owe on Bilt"
//
// It answers what it understood before giving the number, so a
// misunderstanding is visible rather than silently wrong.

struct QueryResult {
    var headline: String
    var interpretation: String       // "Amex Gold · Aug 5 – Aug 15 · 12 transactions"
    var total: Money
    var rows: [CDExpense]
    var breakdown: [(label: String, amount: Money)]
    var followUps: [String]
    var understood: Bool
}

struct NaturalQuery {
    let context: NSManagedObjectContext
    let calendar = CycleCalendar(anchorDay: 10)

    func answer(_ raw: String) -> QueryResult {
        let q = raw.lowercased()
        let all = fetchAll()

        var rows = all
        var facets: [String] = []
        var matchedSomething = false

        // --- date range ---
        let range = parseDateRange(q)
        if let range {
            rows = rows.filter { e in
                guard let d = e.date else { return false }
                return d >= range.start && d <= range.end
            }
            facets.append(range.label)
            matchedSomething = true
        }

        // --- card ---
        if let card = matchCard(q, in: all) {
            rows = rows.filter { $0.card?.name == card }
            facets.append(card)
            matchedSomething = true
        }

        // --- category ---
        if let cat = matchCategory(q) {
            rows = rows.filter { Category.lenient($0.category ?? "") == cat }
            facets.append(cat.rawValue)
            matchedSomething = true
        }

        // --- person (Who column) ---
        if let payer = matchPayer(q) {
            rows = rows.filter { $0.payer == payer.rawValue }
            facets.append("for \(payer.rawValue)")
            matchedSomething = true
        }

        // --- free-text merchant / note, e.g. a name like "Bindu" ---
        if let term = matchFreeText(q, alreadyMatched: facets) {
            rows = rows.filter {
                ($0.merchant ?? "").lowercased().contains(term)
                || ($0.notes ?? "").lowercased().contains(term)
            }
            facets.append("\"\(term)\"")
            matchedSomething = true
        }

        rows = rows.filter { !$0.needsReview }

        // Default window when nothing temporal was said: this cycle.
        if range == nil && matchedSomething == false {
            let key = CycleCalendar.key(for: .now)
            rows = rows.filter { $0.cycleKey == key }
            facets.append("this cycle")
        }

        let total = Money(rows.reduce(0) { $0 + Int($1.amountCents) })
        let wantsLargest = q.contains("biggest") || q.contains("largest")
            || q.contains("most expensive") || q.contains("top")

        let sorted = wantsLargest
            ? rows.sorted { $0.amountCents > $1.amountCents }
            : rows.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        // Break down by whichever dimension wasn't pinned in the question.
        let breakdown: [(String, Money)]
        if matchCategory(q) != nil || q.contains("by card") {
            breakdown = group(rows) { $0.card?.name ?? "Unassigned" }
        } else if matchCard(q, in: all) != nil || q.contains("by category") {
            breakdown = group(rows) { $0.category ?? "—" }
        } else {
            breakdown = group(rows) { $0.category ?? "—" }
        }

        let facetLine = facets.isEmpty ? "everything" : facets.joined(separator: " · ")
        let headline = rows.isEmpty
            ? "Nothing found for \(facetLine)."
            : "\(total.formatted()) across \(rows.count) transaction\(rows.count == 1 ? "" : "s")."

        return QueryResult(
            headline: headline,
            interpretation: facetLine,
            total: total,
            rows: Array(sorted.prefix(wantsLargest ? 10 : 40)),
            breakdown: Array(breakdown.prefix(6)),
            followUps: suggestions(facets: facets, hadRows: !rows.isEmpty),
            understood: matchedSomething || range != nil)
    }

    // MARK: - matchers

    private func fetchAll() -> [CDExpense] {
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        r.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return (try? context.fetch(r)) ?? []
    }

    private func matchCard(_ q: String, in rows: [CDExpense]) -> String? {
        let names = Set(rows.compactMap { $0.card?.name })
        // Longest name first, so "Chase Sapphire" beats "Chase".
        for name in names.sorted(by: { $0.count > $1.count }) {
            if q.contains(name.lowercased()) { return name }
        }
        // Common shorthand.
        let alias: [String: String] = [
            "amex gold": "Amex Gold", "gold card": "Amex Gold",
            "amex blue": "Amex Blue", "blue card": "Amex Blue", "amex": "Amex Blue",
            "sapphire": "Chase Sapphire", "prime": "Chase Prime",
            "freedom": "Chase Freedom", "bilt": "Bilt", "discover": "Discover",
            "citi": "Citi Double", "costco card": "Costco Citi",
            "apple": "Apple Card", "wells": "Wells Fargo", "paypal": "PayPal"
        ]
        for (k, v) in alias.sorted(by: { $0.key.count > $1.key.count })
        where q.contains(k) && names.contains(v) { return v }
        return nil
    }

    private func matchCategory(_ q: String) -> Category? {
        for c in Category.allCases.sorted(by: { $0.rawValue.count > $1.rawValue.count }) {
            if q.contains(c.rawValue.lowercased()) { return c }
        }
        let alias: [String: Category] = [
            "eating out": .eatOut, "restaurants": .eatOut, "dining": .eatOut,
            "groceries": .foodAndLiving, "food": .foodAndLiving,
            "gas": .car, "fuel": .car, "petrol": .car,
            "smokes": .drinksOrSmokes, "drinks": .drinksOrSmokes, "alcohol": .drinksOrSmokes,
            "gift": .gifts, "presents": .gifts,
            "movie": .movies, "utility": .utilities, "bills": .utilities,
            "shopping": .luxuryPersonal, "clothes": .luxuryPersonal,
            "home": .luxuryHome, "travel": .travel, "trip": .travel,
            "interest": .interestOrFees, "fees": .interestOrFees
        ]
        for (k, v) in alias.sorted(by: { $0.key.count > $1.key.count }) where q.contains(k) {
            return v
        }
        return nil
    }

    private func matchPayer(_ q: String) -> Payer? {
        if q.contains("on me") || q.contains("myself") || q.contains("for me") { return .deepu }
        for p in Payer.allCases where q.contains(p.rawValue.lowercased()) { return p }
        return nil
    }

    /// A quoted phrase, or a capitalised-looking name the other matchers missed.
    private func matchFreeText(_ q: String, alreadyMatched: [String]) -> String? {
        if let open = q.firstIndex(of: "\""),
           let close = q.lastIndex(of: "\""), open < close {
            let inner = String(q[q.index(after: open)..<close])
            if !inner.isEmpty { return inner }
        }
        for marker in [" at ", " on ", " for ", " with "] {
            guard let r = q.range(of: marker) else { continue }
            let tail = q[r.upperBound...]
                .split(separator: " ")
                .prefix(2).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ?.,!"))
            let stop: Set<String> = ["my", "the", "this", "last", "card", "me",
                                     "spend", "spent", "total", "much"]
            let first = tail.split(separator: " ").first.map(String.init) ?? ""
            if !tail.isEmpty && !stop.contains(first) && first.count > 2 {
                return first
            }
        }
        return nil
    }

    // MARK: - dates

    struct Range { let start: Date; let end: Date; let label: String }

    private func parseDateRange(_ q: String) -> Range? {
        let cal = Calendar.current
        let now = Date()

        if q.contains("this cycle") || q.contains("this month") {
            let c = calendar.cycle(containing: now)
            return Range(start: c.start, end: c.end, label: c.label)
        }
        if q.contains("last cycle") || q.contains("last month") {
            let c = calendar.previous(calendar.cycle(containing: now))
            return Range(start: c.start, end: c.end, label: c.label)
        }
        if q.contains("this week") {
            let start = cal.date(byAdding: .day, value: -7, to: now)!
            return Range(start: start, end: now, label: "last 7 days")
        }
        if q.contains("this year") {
            let start = cal.date(from: DateComponents(year: cal.component(.year, from: now),
                                                      month: 1, day: 1))!
            return Range(start: start, end: now, label: "this year")
        }
        if q.contains("last year") {
            let y = cal.component(.year, from: now) - 1
            return Range(start: cal.date(from: DateComponents(year: y, month: 1, day: 1))!,
                         end: cal.date(from: DateComponents(year: y, month: 12, day: 31))!,
                         label: "\(y)")
        }

        // "from aug 5 to aug 15", "between june 1 and june 30"
        let dates = extractDates(q)
        if dates.count >= 2 {
            let a = min(dates[0], dates[1]), b = max(dates[0], dates[1])
            let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: b) ?? b
            return Range(start: a, end: end,
                         label: "\(a.formatted(.dateTime.month(.abbreviated).day())) – \(b.formatted(.dateTime.month(.abbreviated).day()))")
        }

        // A bare month name: "in june", "june spending"
        let months = ["january","february","march","april","may","june","july",
                      "august","september","october","november","december"]
        for (i, m) in months.enumerated() where q.contains(m) || q.contains(String(m.prefix(3))) {
            let year = extractYear(q) ?? cal.component(.year, from: now)
            guard let start = cal.date(from: DateComponents(year: year, month: i + 1, day: 1)),
                  let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)
            else { continue }
            let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            return Range(start: start, end: endOfDay,
                         label: "\(m.capitalized) \(year)")
        }
        return nil
    }

    private func extractYear(_ q: String) -> Int? {
        guard let m = q.range(of: #"20\d{2}"#, options: .regularExpression) else { return nil }
        return Int(q[m])
    }

    /// Pulls "aug 5", "august 5", "8/5", "8/5/2026" out of free text.
    private func extractDates(_ q: String) -> [Date] {
        let cal = Calendar.current
        let defaultYear = cal.component(.year, from: Date())
        var found: [Date] = []

        let months = ["jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
                      "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12]

        let pattern = #"([a-z]{3,9})\s+(\d{1,2})|(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = q as NSString
        for m in rx.matches(in: q, range: NSRange(location: 0, length: ns.length)) {
            var comps = DateComponents()
            comps.year = extractYear(q) ?? defaultYear
            if m.range(at: 1).location != NSNotFound {
                let name = ns.substring(with: m.range(at: 1)).prefix(3).lowercased()
                guard let mo = months[String(name)] else { continue }
                comps.month = mo
                comps.day = Int(ns.substring(with: m.range(at: 2)))
            } else if m.range(at: 3).location != NSNotFound {
                comps.month = Int(ns.substring(with: m.range(at: 3)))
                comps.day = Int(ns.substring(with: m.range(at: 4)))
                if m.range(at: 5).location != NSNotFound {
                    let y = Int(ns.substring(with: m.range(at: 5))) ?? defaultYear
                    comps.year = y < 100 ? 2000 + y : y
                }
            }
            if let d = cal.date(from: comps) { found.append(d) }
        }
        return found
    }

    // MARK: - helpers

    private func group(_ rows: [CDExpense],
                       by key: (CDExpense) -> String) -> [(String, Money)] {
        Dictionary(grouping: rows, by: key)
            .map { ($0.key, Money($0.value.reduce(0) { $0 + Int($1.amountCents) })) }
            .sorted { $0.1 > $1.1 }
    }

    private func suggestions(facets: [String], hadRows: Bool) -> [String] {
        guard hadRows else {
            return ["Spend this cycle", "Biggest purchases this month",
                    "How much on groceries last month"]
        }
        return ["Break that down by card", "Same thing last month",
                "Biggest ones", "How much on gifts this year"]
    }
}
