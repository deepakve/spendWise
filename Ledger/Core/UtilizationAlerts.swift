import Foundation
import CoreData
import UserNotifications

// Credit-limit utilization alerts.
//
// Due-date alerts (BillAlerts, in Recurring.swift) tell you when a bill is
// coming due. This is the other alert you asked for: a heads-up the moment
// a card's spend for the cycle crosses a percentage of its credit limit,
// checked right when the purchase lands rather than waiting for the next
// time the app happens to be open.

enum UtilizationAlerts {
    private static let thresholdKey = "utilizationAlertPercent"
    private static let notifiedCyclesKey = "utilizationAlerts.notifiedCycles"

    /// Percent of the credit limit that triggers an alert. Defaults to 90 —
    /// change it from Settings if you want an earlier or later warning.
    static var thresholdPercent: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: thresholdKey)
            return stored == 0 ? 90 : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }

    /// Call right after an expense lands on a card. Fires at most once per
    /// card per cycle — crossing the threshold again on a later purchase in
    /// the same cycle doesn't re-notify.
    @MainActor
    static func checkAfterExpense(card: CDCard?, context: NSManagedObjectContext) {
        guard let card, card.creditLimitCents > 0, !card.isCash, !card.isClosed else { return }

        let key = CycleCalendar.key(for: .now)
        let engine = StatementEngine(context: context)
        let owed = engine.charges(card: card, cycleKey: key) + engine.carryForwardInto(card: card, cycleKey: key)
        let limit = Money(Int(card.creditLimitCents))
        guard limit.cents > 0 else { return }

        let percent = Int((Double(owed.cents) / Double(limit.cents)) * 100)
        guard percent >= thresholdPercent else { return }

        let cycleMark = "\(card.id?.uuidString ?? "")|\(key)"
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedCyclesKey) ?? [])
        guard !notified.contains(cycleMark) else { return }
        notified.insert(cycleMark)
        UserDefaults.standard.set(Array(notified), forKey: notifiedCyclesKey)

        let content = UNMutableNotificationContent()
        content.title = "\(card.name ?? "Card") is at \(percent)% of its limit"
        content.body = "\(owed.formatted()) of \(limit.formatted()) this cycle."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "utilization-\(cycleMark)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Clears the "already notified" record for a card/cycle — used when a
    /// statement reconciles and the numbers change materially, so a
    /// corrected figure can re-trigger the alert if it's still over.
    static func resetNotification(card: CDCard, cycleKey: String) {
        let cycleMark = "\(card.id?.uuidString ?? "")|\(cycleKey)"
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedCyclesKey) ?? [])
        notified.remove(cycleMark)
        UserDefaults.standard.set(Array(notified), forKey: notifiedCyclesKey)
    }
}
