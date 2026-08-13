import Foundation
import CoreData

// The balance model, which is the part your "Budget Appu" sheet tracks by hand.
//
//   closing = previousBalance + charges + interest + fees − payments
//
// If you pay the closing in full, next month's previousBalance is 0. If you pay
// part, the remainder carries. That single recurrence is what answers all three
// of your questions at bill time:
//
//   "what accumulated this month"  → charges
//   "what should I pay"            → closing (or minimum, if you're carrying)
//   "what carries to next month"   → closing − payments
//
// `statedClosing` is what the bank's statement actually says. `charges` is what
// the app computed from your logged expenses. The gap between them is the thing
// you go hunting for — a fee you missed, a subscription you forgot. Surfacing
// that difference explicitly is the whole point of the reconcile screen.

struct StatementMath {
    var previousBalance: Money
    var charges: Money          // computed from expenses in the window
    var interest: Money
    var fees: Money
    var payments: Money
    var statedClosing: Money    // typed in from the bank statement; zero = not entered

    /// What the bank's statement would show as the closing balance for this
    /// cycle: the balance before any payment made against *this* statement is
    /// applied. Payments are accounted for separately, in `carryForward` and
    /// `isFullyPaid` — a statement's own closing balance doesn't change based
    /// on when you pay it.
    var computedClosing: Money {
        previousBalance + charges + interest + fees
    }

    /// What you still owe after payments recorded so far.
    var carryForward: Money {
        let closing = statedClosing.cents != 0 ? statedClosing : computedClosing
        let remaining = closing - payments
        return remaining.cents > 0 ? remaining : .zero
    }

    /// Positive means the bank says you owe more than the app knows about —
    /// i.e. there are transactions you haven't logged.
    var unreconciled: Money {
        guard statedClosing.cents != 0 else { return .zero }
        return statedClosing - computedClosing
    }

    var isFullyPaid: Bool {
        let closing = statedClosing.cents != 0 ? statedClosing : computedClosing
        return payments >= closing && closing.cents > 0
    }

    /// Rough interest cost of carrying this balance one more month, so the app
    /// can say what the carry actually costs rather than just its size.
    func monthlyInterestCost(aprBasisPoints: Int) -> Money {
        guard aprBasisPoints > 0, carryForward.cents > 0 else { return .zero }
        let monthlyRate = Double(aprBasisPoints) / 10_000.0 / 12.0
        return Money(Int((Double(carryForward.cents) * monthlyRate).rounded()))
    }
}

@MainActor
struct StatementEngine {
    let context: NSManagedObjectContext
    let calendar = CycleCalendar(anchorDay: 10)
    let dates = StatementDates()

    /// Fetch or create the statement record for a card and cycle.
    func statement(for card: CDCard, cycleKey: String) -> CDStatement {
        let req = NSFetchRequest<CDStatement>(entityName: "CDStatement")
        req.predicate = NSPredicate(format: "card == %@ AND cycleKey == %@", card, cycleKey)
        req.fetchLimit = 1
        if let found = try? context.fetch(req).first { return found }

        let s = CDStatement(context: context)
        s.id = UUID()
        s.card = card
        s.cycleKey = cycleKey
        let cycle = calendar.cycle(key: cycleKey)
        s.openedOn = cycle.start
        s.closedOn = cycle.end

        let comps = Calendar.current.dateComponents([.year, .month], from: cycle.end)
        if card.dueDay > 0, let y = comps.year, let m = comps.month {
            s.dueOn = dates.clamped(year: y, month: m, day: Int(card.dueDay))
        }
        // Carry the prior cycle's unpaid balance forward automatically.
        s.previousBalanceCents = Int64(carryForwardInto(card: card, cycleKey: cycleKey).cents)
        return s
    }

    /// Unpaid remainder of the cycle immediately before `cycleKey`.
    func carryForwardInto(card: CDCard, cycleKey: String) -> Money {
        let prev = calendar.previous(calendar.cycle(key: cycleKey)).key
        let req = NSFetchRequest<CDStatement>(entityName: "CDStatement")
        req.predicate = NSPredicate(format: "card == %@ AND cycleKey == %@", card, prev)
        req.fetchLimit = 1
        guard let s = try? context.fetch(req).first else { return .zero }
        return math(for: s).carryForward
    }

    /// Charges logged against this card inside the cycle window.
    func charges(card: CDCard, cycleKey: String) -> Money {
        let req = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        req.predicate = NSPredicate(format: "card == %@ AND cycleKey == %@ AND needsReview == NO",
                                    card, cycleKey)
        let rows = (try? context.fetch(req)) ?? []
        return Money(rows.reduce(0) { $0 + Int($1.amountCents) })
    }

    func math(for s: CDStatement) -> StatementMath {
        let paid = (s.payments as? Set<CDPayment>) ?? []
        return StatementMath(
            previousBalance: Money(Int(s.previousBalanceCents)),
            charges: s.card.map { charges(card: $0, cycleKey: s.cycleKey ?? "") } ?? .zero,
            interest: Money(Int(s.interestCents)),
            fees: Money(Int(s.feesCents)),
            payments: Money(paid.reduce(0) { $0 + Int($1.amountCents) }),
            statedClosing: Money(Int(s.statedClosingCents)))
    }

    func recordPayment(_ amount: Money, on date: Date, to s: CDStatement, note: String = "") {
        let p = CDPayment(context: context)
        p.id = UUID(); p.amountCents = Int64(amount.cents); p.paidOn = date
        p.note = note; p.statement = s
    }
}

// MARK: - Analytics

struct CategoryTotal: Identifiable { let category: Category; let total: Money; let count: Int
    var id: String { category.rawValue } }
struct CardTotal: Identifiable { let name: String; let total: Money; let count: Int
    var id: String { name } }
struct PayerTotal: Identifiable { let payer: Payer; let total: Money; let count: Int
    var id: String { payer.rawValue } }
struct MerchantTotal: Identifiable { let name: String; let total: Money; let count: Int
    var id: String { name } }

struct Analytics {
    let calendar = CycleCalendar(anchorDay: 10)

    func inCycle(_ all: [CDExpense], _ key: String) -> [CDExpense] {
        all.filter { $0.cycleKey == key && !$0.needsReview }
    }

    func total(_ rows: [CDExpense]) -> Money {
        Money(rows.reduce(0) { $0 + Int($1.amountCents) })
    }

    func byCategory(_ rows: [CDExpense]) -> [CategoryTotal] {
        Dictionary(grouping: rows, by: { Category.lenient($0.category ?? "") })
            .map { CategoryTotal(category: $0.key,
                                 total: Money($0.value.reduce(0) { $0 + Int($1.amountCents) }),
                                 count: $0.value.count) }
            .sorted { $0.total > $1.total }
    }

    func byCard(_ rows: [CDExpense]) -> [CardTotal] {
        Dictionary(grouping: rows, by: { $0.card?.name ?? "Unassigned" })
            .map { CardTotal(name: $0.key,
                             total: Money($0.value.reduce(0) { $0 + Int($1.amountCents) }),
                             count: $0.value.count) }
            .sorted { $0.total > $1.total }
    }

    func byPayer(_ rows: [CDExpense]) -> [PayerTotal] {
        Dictionary(grouping: rows, by: { Payer(rawValue: $0.payer ?? "Us") ?? .us })
            .map { PayerTotal(payer: $0.key,
                              total: Money($0.value.reduce(0) { $0 + Int($1.amountCents) }),
                              count: $0.value.count) }
            .sorted { $0.total > $1.total }
    }

    func topMerchants(_ rows: [CDExpense], limit: Int = 8) -> [MerchantTotal] {
        Dictionary(grouping: rows, by: { $0.merchant ?? "" })
            .map { MerchantTotal(name: $0.key,
                                 total: Money($0.value.reduce(0) { $0 + Int($1.amountCents) }),
                                 count: $0.value.count) }
            .sorted { $0.total > $1.total }
            .prefix(limit).map { $0 }
    }

    /// Simple pace projection. Deliberately naive — a confidently wrong forecast
    /// is worse than an obviously rough one.
    func projected(_ rows: [CDExpense], cycle: Cycle, asOf now: Date = .now) -> Money {
        let p = cycle.progress(asOf: now)
        guard p > 0.05 else { return total(rows) }
        return Money(Int(Double(total(rows).cents) / p))
    }
}
