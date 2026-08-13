import SwiftUI
import CoreData

@main
struct LedgerApp: App {
    @StateObject private var store = Persistence.shared

    init() { Seeder.run(context: Persistence.shared.context) }

    var body: some Scene {
        WindowGroup {
            LockGate {
              TabView {
                DashboardView()
                    .tabItem { Label("Overview", systemImage: "chart.pie.fill") }
                NavigationStack { LedgerView() }
                    .tabItem { Label("Ledger", systemImage: "list.bullet") }
                AskView()
                    .tabItem { Label("Ask", systemImage: "sparkle.magnifyingglass") }
                CardsView()
                    .tabItem { Label("Cards", systemImage: "creditcard.fill") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
              }
              .environment(\.managedObjectContext, store.context)
              .environmentObject(store)
              .task {
                  RecurringStore.shared.postAutopayBills(context: store.context)
                  SnapshotPublisher.refresh(context: store.context)
                  if await BillAlerts.requestPermission() {
                      let r = NSFetchRequest<CDCard>(entityName: "CDCard")
                      let cards = (try? store.context.fetch(r)) ?? []
                      await BillAlerts.schedule(cards: cards, context: store.context)
                  }
              }
            }
        }
    }
}

// MARK: - Seeding
//
// Cards taken from your workbook: APR, statement close day and due day, which
// are the fields the reconcile screen needs. No card numbers — those go in the
// Keychain vault, by hand, on your device.

enum Seeder {
    static func run(context: NSManagedObjectContext) {
        let req = NSFetchRequest<CDCard>(entityName: "CDCard")
        guard (try? context.count(for: req)) == 0 else { return }

        // name, issuer, apr basis points, statement close day, due day, isCash, colour
        let cards: [(String, String, Int32, Int16, Int16, Bool, String)] = [
            ("Bilt",           "Wells Fargo",      3474, 17,  8, false, "#0A84FF"),
            ("Chase Prime",    "Chase",            2749,  0, 20, false, "#FF9F0A"),
            ("Chase Sapphire", "Chase",            2749,  0, 25, false, "#5E5CE6"),
            ("Chase Freedom",  "Chase",            2774,  0,  8, false, "#64D2FF"),
            ("Discover",       "Discover",         1849,  0,  7, false, "#FF375F"),
            ("Citi Double",    "Citi",             2549,  0, 14, false, "#30D158"),
            ("Costco Citi",    "Citi",             2474,  0, 24, false, "#BF5AF2"),
            ("Amex Blue",      "American Express", 2249, 29, 23, false, "#64D2FF"),
            ("Amex Gold",      "American Express",    0,  0,  0, false, "#FFD60A"),
            ("Apple Card",     "Goldman Sachs",    1949,  0, 31, false, "#8E8E93"),
            ("BofA Cash",      "Bank of America",  2449, 18, 15, false, "#FF375F"),
            ("BofA Travel",    "Bank of America",  2524,  0, 23, false, "#AC8E68"),
            ("BofA Debit",     "Bank of America",     0,  0,  0, true,  "#8E8E93"),
            ("BofA Subha",     "Bank of America",     0,  0,  0, true,  "#FF375F"),
            ("Wells Fargo",    "Wells Fargo",      2349,  0, 22, false, "#FFD60A"),
            ("PayPal",         "Synchrony",        2000,  0, 20, false, "#0A84FF"),
            ("Target",         "TD Bank",          2995,  0,  0, false, "#FF375F"),
            ("Best Buy",       "Citi",                0,  0,  5, false, "#FFD60A"),
            ("Carters",        "Comenity",            0,  0,  0, false, "#BF5AF2"),
            ("Wex Benefits",   "WEX",                 0,  0,  0, true,  "#30D158"),
            ("Cash",           "",                    0,  0,  0, true,  "#8E8E93"),
        ]
        // Known identifiers, so receipts and payment confirmations match on
        // first run. card last-4 / bank account last-4.
        let identifiers: [String: (String, String)] = [
            "BofA Debit":     ("9636", "6932"),
            "Bilt":           ("8099", ""),
            "Chase Prime":    ("9205", ""),
            "Chase Sapphire": ("5778", ""),
            "Discover":       ("3807", ""),
            "Costco Citi":    ("8488", ""),
            "BofA Cash":      ("3080", ""),
            "Wells Fargo":    ("1636", ""),
            "PayPal":         ("8166", ""),
            "Target":         ("8128", ""),
            "Best Buy":       ("3829", ""),
            "Carters":        ("0313", ""),
        ]

        for (i, c) in cards.enumerated() {
            let card = CDCard(context: context)
            card.id = UUID(); card.name = c.0; card.issuer = c.1
            card.aprBasisPoints = c.2; card.statementDay = c.3; card.dueDay = c.4
            card.isCash = c.5; card.colorHex = c.6
            card.sortIndex = Int16(i)
            if let ids = identifiers[c.0] {
                card.last4 = ids.0
                card.accountLast4 = ids.1
            }
            card.secretRef = "card.\(card.id!.uuidString)"
        }

        let budget: [(String, Int64, Category)] = [
            ("Housing", 446_600, .mortgageOrEMI), ("Cadillac", 74_000, .car),
            ("Car insurance", 16_700, .car), ("Groceries / Living", 100_000, .foodAndLiving),
            ("CoServ", 20_000, .utilities), ("Mustang water", 15_000, .utilities),
            ("AT&T WiFi", 6_600, .utilities), ("AT&T phone", 10_000, .utilities),
            ("Badminton", 8_600, .luxuryPersonal), ("HOA", 11_900, .utilities),
        ]
        for b in budget {
            let l = CDBudgetLine(context: context)
            l.id = UUID(); l.name = b.0; l.plannedCents = b.1; l.category = b.2.rawValue
        }

        try? context.save()
    }
}

// MARK: - CSV import
//
// Reads the exact file already built from your workbook, including the Cycle
// column. Ambiguous rows import flagged rather than being dropped or guessed.

struct CSVImporter {
    let context: NSManagedObjectContext

    struct Result { var imported = 0; var flagged = 0; var skipped = 0 }

    func run(_ text: String) throws -> Result {
        var result = Result()
        let rows = Self.parse(text)
        guard let header = rows.first else { return result }

        var index: [String: Int] = [:]
        for (i, h) in header.enumerated() {
            let k = h.trimmingCharacters(in: .whitespaces).lowercased()
                     .replacingOccurrences(of: "?", with: "")
            index[k == "store" ? "merchant" : k] = i
        }

        var cardsByName: [String: CDCard] = [:]
        for c in (try? context.fetch(NSFetchRequest<CDCard>(entityName: "CDCard"))) ?? [] {
            cardsByName[(c.name ?? "").lowercased()] = c
        }
        let existing = (try? context.fetch(NSFetchRequest<CDExpense>(entityName: "CDExpense"))) ?? []
        var seen = Set(existing.map { fingerprint($0) })

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")

        for row in rows.dropFirst() {
            func f(_ n: String) -> String {
                guard let i = index[n], i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespaces)
            }

            let merchant = f("merchant"), amountRaw = f("amount"), dateRaw = f("date")
            if merchant.isEmpty && amountRaw.isEmpty && dateRaw.isEmpty { continue }

            var flagged = false
            var reasons: [String] = []

            var date = Date()
            var parsed = false
            for fmt in ["MMM d, yyyy", "MMMM d, yyyy", "M/d/yyyy", "yyyy-MM-dd"] {
                df.dateFormat = fmt
                if let d = df.date(from: dateRaw) { date = d; parsed = true; break }
            }
            if !parsed { flagged = true; reasons.append("Date unreadable: \(dateRaw)") }

            let money = Money.parse(amountRaw)
            if money == nil { flagged = true; reasons.append("Amount missing") }

            var card: CDCard?
            let cardName = f("card")
            if cardName.isEmpty {
                flagged = true; reasons.append("No card")
            } else if let c = cardsByName[cardName.lowercased()] {
                card = c
            } else {
                let c = CDCard(context: context)
                c.id = UUID(); c.name = cardName; c.sortIndex = 99
                c.secretRef = "card.\(c.id!.uuidString)"
                cardsByName[cardName.lowercased()] = c
                card = c
            }

            var category = Category.lenient(f("category"))
            if category == .uncategorized && !f("category").isEmpty {
                flagged = true; reasons.append("Category unclear: \(f("category"))")
            }
            if f("category").isEmpty { category = .uncategorized; flagged = true
                                       reasons.append("No category") }

            let e = CDExpense(context: context)
            e.id = UUID()
            e.date = date
            e.amountCents = Int64(money?.cents ?? 0)
            e.merchant = merchant
            e.merchantKey = merchant.lowercased()
            e.category = category.rawValue
            e.payer = f("who").isEmpty ? "Us" : f("who")
            e.notes = f("notes")
            e.isRecurring = !f("recurring").isEmpty
            e.card = card
            e.cycleKey = f("cycle").isEmpty ? CycleCalendar.key(for: date) : f("cycle")
            e.source = "csvImport"
            e.createdAt = .now; e.updatedAt = .now

            let fp = fingerprint(e)
            if seen.contains(fp) { context.delete(e); result.skipped += 1; continue }
            seen.insert(fp)

            e.needsReview = flagged
            if flagged { e.notes = (reasons + [e.notes ?? ""]).joined(separator: " · ") }

            result.imported += 1
            if flagged { result.flagged += 1 }
        }

        try context.save()
        return result
    }

    private func fingerprint(_ e: CDExpense) -> String {
        DuplicateGuard.fingerprint(date: e.date ?? .distantPast,
                                   cents: Int(e.amountCents),
                                   merchant: e.merchant ?? "",
                                   cardName: e.card?.name ?? "")
    }

    /// RFC 4180 parser — the Notes column contains commas and wrapped newlines.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var it = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        while let ch = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let nxt = it.next() {
                        if nxt == "\"" { field.append("\"") } else { inQuotes = false; pending = nxt }
                    } else { inQuotes = false }
                } else { field.append(ch) }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",":  endField()
                case "\n": endRow()
                case "\r": break
                default:   field.append(ch)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
