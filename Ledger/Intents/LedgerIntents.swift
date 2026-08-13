import AppIntents
import CoreData
import Foundation

// Shortcuts support.
//
// Five intents, because capture alone isn't enough — you also want to *ask*
// questions without opening the app. Every one works from Back Tap, Siri,
// a Home Screen widget, an NFC tag, or a location automation.
//
// `openAppWhenRun = false` throughout: the whole point is that logging an
// expense in a parking lot never puts a screen in front of you.

// MARK: - 1. Log an expense

struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log expense"
    static var description = IntentDescription("Add a purchase to your ledger.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount", requestValueDialog: "How much?")
    var amount: Double

    @Parameter(title: "Merchant", requestValueDialog: "Where?")
    var merchant: String

    @Parameter(title: "Card")
    var card: CardEntity?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Who")
    var who: PayerEntity?

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)") {
            \.$card; \.$category; \.$who; \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ctx = Persistence.shared.context

        // Resolve the card: explicit, else the one used last at this merchant,
        // else the most recently used card. Guessing a card is safe (one tap to
        // fix); guessing a category is not, so an unresolved one is flagged.
        var resolved: CDCard?
        if let card {
            let r = NSFetchRequest<CDCard>(entityName: "CDCard")
            r.predicate = NSPredicate(format: "id == %@", card.id as CVarArg)
            r.fetchLimit = 1
            resolved = try? ctx.fetch(r).first
        }

        let key = merchant.lowercased().trimmingCharacters(in: .whitespaces)
        let prior: CDExpense? = {
            let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
            r.predicate = NSPredicate(format: "merchantKey == %@", key)
            r.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            r.fetchLimit = 1
            return try? ctx.fetch(r).first
        }()

        if resolved == nil { resolved = prior?.card }
        if resolved == nil {
            let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
            r.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            r.fetchLimit = 1
            resolved = (try? ctx.fetch(r).first)?.card
        }

        let cat: Category = category?.category
            ?? prior.map { Category.lenient($0.category ?? "") }
            ?? .uncategorized

        let money = Money(dollars: amount)
        let cardName = resolved?.name ?? "no card"

        let outcome = DuplicateGuard.create(
            date: .now, amount: money, merchant: merchant,
            category: cat, card: resolved, payer: who?.payer ?? .us,
            notes: note ?? "", source: "shortcut",
            needsReview: cat == .uncategorized,
            context: ctx)

        switch outcome {
        case .blocked(let match):
            return .result(dialog: "Already logged — \(match.reason) Nothing added.")
        case .flagged(_, let match):
            return .result(dialog: "Logged \(money.formatted()) at \(merchant), but it may duplicate an existing entry: \(match.reason) It's in Needs review.")
        case .created:
            return .result(dialog: "Logged \(money.formatted()) at \(merchant) on \(cardName).")
        }
    }
}

// MARK: - 2. What's on a card this cycle

struct CardTotalIntent: AppIntent {
    static var title: LocalizedStringResource = "Card total"
    static var description = IntentDescription("How much is on a card this cycle.")
    static var openAppWhenRun = false

    @Parameter(title: "Card", requestValueDialog: "Which card?")
    var card: CardEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Total on \(\.$card)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let ctx = Persistence.shared.context
        let key = CycleCalendar.key(for: .now)
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        r.predicate = NSPredicate(format: "card.id == %@ AND cycleKey == %@ AND needsReview == NO",
                                  card.id as CVarArg, key)
        let rows = (try? ctx.fetch(r)) ?? []
        let total = Money(rows.reduce(0) { $0 + Int($1.amountCents) })

        // Include the carry-forward, since "what do I owe" isn't just this
        // cycle's charges when a balance rolled over.
        var line = "\(card.name) this cycle: \(total.formatted())"
        let cr = NSFetchRequest<CDCard>(entityName: "CDCard")
        cr.predicate = NSPredicate(format: "id == %@", card.id as CVarArg)
        if let c = try? ctx.fetch(cr).first {
            let carried = StatementEngine(context: ctx).carryForwardInto(card: c, cycleKey: key)
            if carried.cents > 0 { line += ", plus \(carried.formatted()) carried in" }
        }
        return .result(value: total.dollars, dialog: "\(line).")
    }
}

// MARK: - 3. Spend this cycle, optionally by category

struct CycleSpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Spend this cycle"
    static var description = IntentDescription("Total spend, optionally for one category.")
    static var openAppWhenRun = false

    @Parameter(title: "Category")
    var category: CategoryEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Spend this cycle on \(\.$category)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let ctx = Persistence.shared.context
        let key = CycleCalendar.key(for: .now)
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        if let category {
            r.predicate = NSPredicate(format: "cycleKey == %@ AND category == %@ AND needsReview == NO",
                                      key, category.category.rawValue)
        } else {
            r.predicate = NSPredicate(format: "cycleKey == %@ AND needsReview == NO", key)
        }
        let rows = (try? ctx.fetch(r)) ?? []
        let total = Money(rows.reduce(0) { $0 + Int($1.amountCents) })
        let label = category?.category.rawValue ?? "Everything"
        return .result(value: total.dollars,
                       dialog: "\(label) this cycle: \(total.formatted()).")
    }
}

// MARK: - 4. Spend on a person

struct PersonSpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Spend on person"
    static var description = IntentDescription("How much has gone to one person this cycle.")
    static var openAppWhenRun = false

    @Parameter(title: "Who", requestValueDialog: "Who?")
    var who: PayerEntity

    static var parameterSummary: some ParameterSummary { Summary("Spend on \(\.$who)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let ctx = Persistence.shared.context
        let key = CycleCalendar.key(for: .now)
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        r.predicate = NSPredicate(format: "cycleKey == %@ AND payer == %@ AND needsReview == NO",
                                  key, who.payer.rawValue)
        let rows = (try? ctx.fetch(r)) ?? []
        let total = Money(rows.reduce(0) { $0 + Int($1.amountCents) })
        return .result(value: total.dollars,
                       dialog: "\(who.payer.rawValue) this cycle: \(total.formatted()).")
    }
}

// MARK: - 5. Search — "how much on Bindu?"

struct SearchSpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Search spend"
    static var description = IntentDescription("Search merchants and notes, and total the matches.")
    static var openAppWhenRun = false

    @Parameter(title: "Search for", requestValueDialog: "Search for what?")
    var term: String

    static var parameterSummary: some ParameterSummary { Summary("Search spend for \(\.$term)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let ctx = Persistence.shared.context
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        r.predicate = NSPredicate(
            format: "(merchant CONTAINS[cd] %@ OR notes CONTAINS[cd] %@) AND needsReview == NO",
            term, term)
        let rows = (try? ctx.fetch(r)) ?? []
        let total = Money(rows.reduce(0) { $0 + Int($1.amountCents) })
        return .result(value: total.dollars,
                       dialog: "\(rows.count) entries matching \"\(term)\", totalling \(total.formatted()).")
    }
}

// MARK: - Entities used as typed Shortcut parameters
//
// A CardEntity means Shortcuts shows a real picker of *your* cards rather than
// a free-text box, so dictation can't mangle "Bilt" into "built".

struct CardEntity: AppEntity, Identifiable {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Card"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = CardQuery()
}

struct CardQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CardEntity] {
        try await allCards().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CardEntity] { try await allCards() }

    @MainActor
    private func allCards() async throws -> [CardEntity] {
        let r = NSFetchRequest<CDCard>(entityName: "CDCard")
        r.predicate = NSPredicate(format: "isClosed == NO")
        r.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
        let cards = (try? Persistence.shared.context.fetch(r)) ?? []
        return cards.compactMap { c in
            guard let id = c.id, let n = c.name else { return nil }
            return CardEntity(id: id, name: n)
        }
    }
}

struct CategoryEntity: AppEntity, Identifiable {
    var id: String { category.rawValue }
    let category: Category

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(category.rawValue)")
    }
    static var defaultQuery = CategoryQuery()
}

struct CategoryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        identifiers.compactMap { Category(rawValue: $0).map(CategoryEntity.init) }
    }
    func suggestedEntities() async throws -> [CategoryEntity] {
        Category.allCases.filter { $0 != .uncategorized }.map(CategoryEntity.init)
    }
}

struct PayerEntity: AppEntity, Identifiable {
    var id: String { payer.rawValue }
    let payer: Payer

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(payer.rawValue)")
    }
    static var defaultQuery = PayerQuery()
}

struct PayerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PayerEntity] {
        identifiers.compactMap { Payer(rawValue: $0).map(PayerEntity.init) }
    }
    func suggestedEntities() async throws -> [PayerEntity] {
        Payer.allCases.map(PayerEntity.init)
    }
}

// MARK: - Siri phrases
//
// `.applicationName` is required in every phrase by App Intents. Several
// wordings per intent because you won't remember one exact form while driving.

struct LedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogExpenseIntent(),
                    phrases: ["Log an expense in \(.applicationName)",
                              "Track an expense in \(.applicationName)",
                              "Add a spend to \(.applicationName)",
                              "New expense in \(.applicationName)"],
                    shortTitle: "Log expense",
                    systemImageName: "plus.circle.fill")

        AppShortcut(intent: CardTotalIntent(),
                    phrases: ["Card total in \(.applicationName)",
                              "What's on my card in \(.applicationName)"],
                    shortTitle: "Card total",
                    systemImageName: "creditcard")

        AppShortcut(intent: CycleSpendIntent(),
                    phrases: ["Spend this cycle in \(.applicationName)",
                              "How much have I spent in \(.applicationName)"],
                    shortTitle: "Spend this cycle",
                    systemImageName: "chart.pie")

        AppShortcut(intent: PersonSpendIntent(),
                    phrases: ["Spend on person in \(.applicationName)"],
                    shortTitle: "Spend on person",
                    systemImageName: "person.2")

        AppShortcut(intent: LogFromAlertIntent(),
                    phrases: ["Log from bank alert in \(.applicationName)"],
                    shortTitle: "Log from alert",
                    systemImageName: "envelope.badge")

        AppShortcut(intent: LogBillPaymentIntent(),
                    phrases: ["Log a bill payment in \(.applicationName)"],
                    shortTitle: "Log bill payment",
                    systemImageName: "doc.text.fill")

        AppShortcut(intent: SearchSpendIntent(),
                    phrases: ["Search spend in \(.applicationName)"],
                    shortTitle: "Search spend",
                    systemImageName: "magnifyingglass")
    }
}

// MARK: - 6. Log from a bank alert
//
// The receiving end of the Shortcuts automation described in AlertParser.
// A Message or Email trigger passes the alert text here; the app parses it,
// matches the card by its last four digits, and files the expense.
//
// Crucially it does NOT log silently when something is unclear. An alert
// parsed at the wrong amount is worse than one that waited for you, because
// you'd never know to look. Anything uncertain is saved flagged and surfaced
// in Needs review with the original text attached, so you can fix it from the
// source rather than from memory.

struct LogFromAlertIntent: AppIntent {
    static var title: LocalizedStringResource = "Log from bank alert"
    static var description = IntentDescription(
        "Reads a bank transaction text or email and adds the expense.")
    static var openAppWhenRun = false

    @Parameter(title: "Alert text")
    var alertText: String

    @Parameter(title: "Ask me if unclear", default: true)
    var askIfUnclear: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Log expense from \(\.$alertText)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = AlertParser.parse(alertText)

        if parsed.isDecline {
            return .result(dialog: "That was a declined transaction, so nothing was logged.")
        }
        guard let amount = parsed.amount else {
            return .result(dialog: "I couldn't find an amount in that alert, so nothing was logged.")
        }

        let ctx = Persistence.shared.context
        let cardReq = NSFetchRequest<CDCard>(entityName: "CDCard")
        let cards = (try? ctx.fetch(cardReq)) ?? []
        let matched = parsed.last4.flatMap { last4 in
            cards.first { ($0.last4 ?? "").hasSuffix(last4) }
        }

        // Category from the last visit to this merchant, if known.
        var category = Category.uncategorized
        if let merchant = parsed.merchant {
            let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
            r.predicate = NSPredicate(format: "merchantKey == %@", merchant.lowercased())
            r.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            r.fetchLimit = 1
            if let prior = try? ctx.fetch(r).first {
                category = Category.lenient(prior.category ?? "")
            }
        }

        var problems: [String] = []
        if matched == nil {
            problems.append(parsed.last4.map { "card •••• \($0) isn't in your wallet" }
                            ?? "no card identified")
        }
        if parsed.merchant == nil { problems.append("merchant unclear") }
        if category == .uncategorized { problems.append("category not set") }

        let signed = parsed.isRefund ? -amount : amount

        // sourceText means the same SMS re-firing can never create a second row.
        let outcome = DuplicateGuard.create(
            date: .now, amount: signed,
            merchant: parsed.merchant ?? "Unknown merchant",
            category: category, card: matched, payer: .us,
            notes: problems.isEmpty ? ""
                : "Needs a look — \(problems.joined(separator: ", ")). Original alert: \(alertText)",
            source: "bankAlert", sourceText: alertText,
            needsReview: !problems.isEmpty && askIfUnclear,
            context: ctx)

        switch outcome {
        case .blocked(let match):
            return .result(dialog: "Already logged — \(match.reason) Nothing added.")
        case .flagged(_, let match):
            return .result(dialog: "Logged \(signed.formatted()), but it may duplicate an existing entry: \(match.reason) It's in Needs review.")
        case .created:
            break
        }

        if problems.isEmpty {
            return .result(dialog: "Logged \(signed.formatted()) at \(parsed.merchant ?? "") on \(matched?.name ?? "no card").")
        } else {
            return .result(dialog: "Logged \(signed.formatted()), but \(problems.joined(separator: " and ")). It's waiting in Needs review.")
        }
    }
}

// MARK: - 7. Log a bill payment from an email
//
// Utility and loan payment confirmations are a different shape from card
// alerts. The body reliably contains the amount, but the merchant is rarely
// stated in a parseable way — CoServ's email says "your recent payment of
// $180.29" and never names CoServ in the body at all.
//
// That's fine, because the *sender* identifies the biller, and the Shortcuts
// Email trigger already filters by sender. So one automation per biller, with
// merchant, category and card fixed rather than guessed. Only the amount is
// parsed, which is the part that changes.
//
// One subtlety worth knowing: these emails often contain more than one dollar
// figure — Mustang's shows a $166.38 subtotal, a $1.25 fee and a $167.63 total.
// `preferTotal` picks whichever you actually want on the ledger.

struct LogBillPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log bill payment"
    static var description = IntentDescription(
        "Reads a bill payment confirmation email and logs the amount.")
    static var openAppWhenRun = false

    @Parameter(title: "Email text")
    var emailText: String

    @Parameter(title: "Biller", requestValueDialog: "Which biller?")
    var merchant: String

    @Parameter(title: "Card")
    var card: CardEntity?

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Use the total rather than the subtotal", default: true)
    var preferTotal: Bool

    @Parameter(title: "Only log if already paid", default: true)
    var requirePaid: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$merchant) bill from \(\.$emailText)") {
            \.$card; \.$category; \.$preferTotal; \.$requirePaid
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ctx = Persistence.shared.context
        let low = emailText.lowercased()

        // "will be processed on 08/15" is a schedule notice, not a payment.
        // Logging it would put a future transaction in the ledger and then
        // duplicate when the real confirmation arrives.
        let isScheduled = low.contains("will be processed")
            || low.contains("is scheduled")
            || low.contains("scheduled to occur")
            || low.contains("payment reminder")
        if requirePaid && isScheduled {
            return .result(dialog: "That's a scheduled-payment notice, not a confirmation. Nothing logged.")
        }

        guard let amount = BillEmailParser.amount(from: emailText, preferTotal: preferTotal) else {
            return .result(dialog: "I couldn't find an amount in that email. Nothing logged.")
        }

        var resolved: CDCard?
        if let card {
            let r = NSFetchRequest<CDCard>(entityName: "CDCard")
            r.predicate = NSPredicate(format: "id == %@", card.id as CVarArg)
            r.fetchLimit = 1
            resolved = try? ctx.fetch(r).first
        }

        let date = BillEmailParser.paidDate(from: emailText) ?? .now

        let outcome = DuplicateGuard.create(
            date: date, amount: amount, merchant: merchant,
            category: category?.category ?? .utilities,
            card: resolved, payer: .us,
            notes: BillEmailParser.confirmation(from: emailText).map { "Conf \($0)" } ?? "",
            source: "billEmail", sourceText: emailText,
            needsReview: resolved == nil,
            context: ctx)

        switch outcome {
        case .blocked(let m):
            return .result(dialog: "Already logged — \(m.reason) Nothing added.")
        case .flagged(_, let m):
            return .result(dialog: "Logged \(amount.formatted()) for \(merchant), but check it: \(m.reason)")
        case .created:
            return .result(dialog: "Logged \(amount.formatted()) for \(merchant).")
        }
    }
}

enum BillEmailParser {

    /// Bill emails carry several figures — subtotal, convenience fee, total.
    /// Which one belongs on the ledger depends on whether you want the fee
    /// counted, so it's a choice rather than a guess.
    static func amount(from text: String, preferTotal: Bool) -> Money? {
        let labels = preferTotal
            ? ["total", "payment amount", "amount paid", "payment of", "amount"]
            : ["subtotal", "payment amount", "payment of", "amount"]

        for label in labels {
            let pattern = "(?i)\(NSRegularExpression.escapedPattern(for: label))\\s*:?\\s*\\$\\s?([\\d,]+\\.\\d{2})"
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
            // Skip a "Convenience Fee: $0.00" style line matching "fee".
            for m in matches {
                let value = ns.substring(with: m.range(at: 1))
                if let money = Money.parse(value), money.cents > 0 { return money }
            }
        }
        // Fall back to the first dollar figure that isn't a balance or a fee.
        guard let rx = try? NSRegularExpression(pattern: #"\$\s?([\d,]+\.\d{2})"#) else { return nil }
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: max(m.range.location - 25, 0)).lowercased()
            if before.contains("balance") || before.contains("fee")
                || before.contains("available") { continue }
            if let money = Money.parse(ns.substring(with: m.range(at: 1))), money.cents > 0 {
                return money
            }
        }
        return nil
    }

    static func paidDate(from text: String) -> Date? {
        let patterns = [
            #"(?i)(?:applied to your account[^0-9]{0,20}|made on|posted on|processed on)\s*(\d{1,2}/\d{1,2}/\d{2,4})"#
        ]
        let ns = text as NSString
        for p in patterns {
            guard let rx = try? NSRegularExpression(pattern: p) else { continue }
            guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            let raw = ns.substring(with: m.range(at: 1))
            for fmt in ["M/d/yyyy", "M/d/yy"] {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = fmt
                if let d = df.date(from: raw) { return d }
            }
        }
        return nil
    }

    static func confirmation(from text: String) -> String? {
        guard let rx = try? NSRegularExpression(
            pattern: #"(?i)confirmation\s*(?:number|#)?\s*:?\s*([A-Z0-9]{6,20})"#) else { return nil }
        let ns = text as NSString
        guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
