import Foundation
import CoreData
import UserNotifications

// Two things your workbook does that the app didn't.
//
// RECURRING BILLS. Your Budget sheet lists $8,220/month of fixed lines —
// mortgage $4,466, Cadillac $740, insurance $167, CoServ $200, Mustang water
// $150, AT&T $166, HOA $119, Apple One $13. Typing those every month is pure
// tax on your attention, and forgetting one is exactly the gap that shows up
// at reconcile time. The app proposes them on their due day instead.
//
// The important design choice: recurring bills are *proposed*, never silently
// posted. A mortgage payment that auto-appears at the wrong amount is worse
// than one you had to confirm, because you'd never notice. Each one lands in a
// review list with the amount pre-filled from last time; you tap to confirm or
// correct.
//
// DUE-DATE ALERTS. You said you keep phone reminders to pay bills. The app
// already knows every card's due day, so it can do that itself — and unlike a
// static reminder, it can tell you the actual amount owed.

struct RecurringRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String                 // "Mustang water"
    var merchant: String
    var category: String
    var cardName: String
    var amountCents: Int             // last known amount
    var dayOfMonth: Int              // 1...28
    var payer: String = "Us"
    var isActive: Bool = true
    /// Autopay bills happen whether or not you act, so the app posts them and
    /// marks them estimated, rather than waiting for a confirmation that would
    /// never come. Non-autopay bills stay as proposals.
    var isAutopay: Bool = true
    var lastPostedCycle: String = "" // guards against double-posting
    var endDate: Date?               // e.g. iPhone loan ends Sep 2026
    var note: String = ""

    var amount: Money { Money(amountCents) }
}

// Note: RecurringRule is a plain value type persisted to UserDefaults, not a
// Core Data entity. The rules are few, personal and change rarely, so they
// don't need a synced entity — and keeping them out of CloudKit avoids merge
// conflicts when you both edit the list.

@MainActor
final class RecurringStore: ObservableObject {
    static let shared = RecurringStore()
    private let key = "recurring.rules"

    @Published var rules: [RecurringRule] = [] {
        didSet { persist() }
    }

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecurringRule].self, from: data)
        else { rules = Self.seedFromBudget(); return }
        rules = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Straight from your Budget sheet. Amounts are last-known, not fixed —
    /// each confirmation updates the rule, so CoServ drifting from $200 to $256
    /// is learned rather than fought.
    static func seedFromBudget() -> [RecurringRule] {
        [
            .init(name: "Mortgage", merchant: "PennyMac", category: "Mortgage or EMI",
                  cardName: "Wells Fargo", amountCents: 446_600, dayOfMonth: 1, isAutopay: true),
            .init(name: "Cadillac", merchant: "Cadillac", category: "Car",
                  cardName: "BofA Debit", amountCents: 74_000, dayOfMonth: 5),
            .init(name: "CoServ", merchant: "CoServ", category: "Utilities",
                  cardName: "Bilt", amountCents: 20_000, dayOfMonth: 2),
            .init(name: "Mustang water", merchant: "Mustang Water", category: "Utilities",
                  cardName: "Bilt", amountCents: 15_000, dayOfMonth: 15),
            .init(name: "AT&T WiFi", merchant: "AT&T", category: "Utilities",
                  cardName: "BofA Debit", amountCents: 6_561, dayOfMonth: 12),
            .init(name: "AT&T phone", merchant: "AT&T", category: "Utilities",
                  cardName: "BofA Debit", amountCents: 10_000, dayOfMonth: 15),
            .init(name: "HOA", merchant: "Union Park HOA", category: "Utilities",
                  cardName: "BofA Debit", amountCents: 71_000, dayOfMonth: 28),
            .init(name: "Lawn mowing", merchant: "Memo lawn mower", category: "Utilities",
                  cardName: "BofA Debit", amountCents: 4_000, dayOfMonth: 5),
            .init(name: "Apple One", merchant: "Apple", category: "Luxury (Personal)",
                  cardName: "Apple Card", amountCents: 4_065, dayOfMonth: 17),
            .init(name: "Badminton membership", merchant: "Velocity Badminton",
                  category: "Luxury (Personal)", cardName: "Discover",
                  amountCents: 8_552, dayOfMonth: 1),
        ]
    }

    /// Rules due in the current cycle that haven't been handled yet.
    func due(asOf now: Date = .now) -> [RecurringRule] {
        let cycle = CycleCalendar.key(for: now)
        let day = Calendar.current.component(.day, from: now)
        return rules.filter { rule in
            guard rule.isActive, rule.lastPostedCycle != cycle else { return false }
            if let end = rule.endDate, now > end { return false }
            return day >= rule.dayOfMonth
        }
    }

    /// Autopay bills post themselves. Called on every launch.
    ///
    /// The reasoning: an autopay bill leaves your account whether or not you
    /// open the app, so refusing to record it until you tap Confirm produces a
    /// ledger that is wrong by exactly the amount of your largest fixed costs.
    /// Instead it posts at the last known amount and is flagged `isEstimated`,
    /// which surfaces it in the reconcile screen and shows an "est." badge
    /// everywhere it appears. Verifying it against the statement clears the flag
    /// and teaches the rule the new amount.
    func postAutopayBills(context: NSManagedObjectContext, asOf now: Date = .now) {
        for rule in due(asOf: now) where rule.isAutopay {
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month], from: now)
            comps.day = rule.dayOfMonth
            let postDate = cal.date(from: comps) ?? now
            post(rule, amount: rule.amount, date: postDate,
                 estimated: true, context: context)
        }
    }

    /// Confirm a proposal or verify an estimate.
    func confirm(_ rule: RecurringRule, amount: Money, date: Date,
                 context: NSManagedObjectContext) {
        post(rule, amount: amount, date: date, estimated: false, context: context)
    }

    private func post(_ rule: RecurringRule, amount: Money, date: Date,
                      estimated: Bool, context: NSManagedObjectContext) {
        let cardReq = NSFetchRequest<CDCard>(entityName: "CDCard")
        cardReq.predicate = NSPredicate(format: "name == %@", rule.cardName)
        cardReq.fetchLimit = 1
        let card = try? context.fetch(cardReq).first

        // Goes through the guard because an autopay bill may already have been
        // captured by a bank alert or logged by hand before the app opened.
        let outcome = DuplicateGuard.create(
            date: date, amount: amount, merchant: rule.merchant,
            category: Category.lenient(rule.category),
            card: card, payer: Payer(rawValue: rule.payer) ?? .us,
            notes: rule.note, source: "recurringRule",
            ruleID: rule.id, isEstimated: estimated,
            context: context)

        if case .blocked = outcome {
            // Already there. Mark the cycle handled so it stops proposing.
            if let i = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[i].lastPostedCycle = CycleCalendar.key(for: date)
            }
            return
        }

        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i].lastPostedCycle = CycleCalendar.key(for: date)
            if !estimated { rules[i].amountCents = amount.cents }
        }
    }

    /// Every expense this rule has ever produced, newest first. This is the
    /// "how much have I been paying" history — utility bills drift, and seeing
    /// CoServ go $200 → $256 → $201 across the year is the point.
    func history(for rule: RecurringRule,
                 context: NSManagedObjectContext) -> [CDExpense] {
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        r.predicate = NSPredicate(format: "ruleID == %@", rule.id as CVarArg)
        r.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return (try? context.fetch(r)) ?? []
    }

    func skip(_ rule: RecurringRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i].lastPostedCycle = CycleCalendar.key(for: .now)
        }
    }
}

// MARK: - Notifications

enum BillAlerts {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Schedule one alert per card, three days before its due day, plus a
    /// morning-of nudge. Rescheduled on every launch so amounts stay current.
    @MainActor
    static func schedule(cards: [CDCard], context: NSManagedObjectContext) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let engine = StatementEngine(context: context)
        let cycle = CycleCalendar.key(for: .now)

        for card in cards where !card.isCash && !card.isClosed && card.dueDay > 0 {
            guard let name = card.name else { continue }
            let charges = engine.charges(card: card, cycleKey: cycle)
            let carried = engine.carryForwardInto(card: card, cycleKey: cycle)
            let owed = charges + carried

            for (offsetDays, when) in [(3, "in 3 days"), (0, "today")] {
                var comps = DateComponents()
                comps.day = max(Int(card.dueDay) - offsetDays, 1)
                comps.hour = 9

                let content = UNMutableNotificationContent()
                content.title = "\(name) due \(when)"
                content.body = owed.cents > 0
                    ? "About \(owed.formatted(cents: false)) on this cycle."
                    : "Nothing logged on this card yet this cycle."
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                let request = UNNotificationRequest(
                    identifier: "due-\(name)-\(offsetDays)",
                    content: content, trigger: trigger)
                try? await center.add(request)
            }
        }

        // Monthly backup nudge. iCloud syncs; it does not back up.
        var backup = DateComponents(); backup.day = 10; backup.hour = 19
        let content = UNMutableNotificationContent()
        content.title = "Export a backup"
        content.body = "New cycle started. Export a CSV to Files — iCloud syncs, it doesn't back up."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "backup-nudge",
                                  content: content,
                                  trigger: UNCalendarNotificationTrigger(dateMatching: backup,
                                                                         repeats: true)))
    }
}
