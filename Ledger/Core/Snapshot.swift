import Foundation
import WidgetKit

// Shared snapshot, written by the app and read by the widgets.
//
// Lives in the main app target because the widget extension doesn't exist yet
// (needs its own Xcode target — see LedgerWidgets/LedgerWidgets.swift). The app
// writes to the App Group container regardless; the widgets start reading from
// it the moment that target is added, no app-side change required.

struct LedgerSnapshot: Codable {
    var cycleLabel: String = ""
    var cycleSpentCents: Int = 0
    var budgetCents: Int = 0
    var cycleProgress: Double = 0        // 0…1 through the cycle
    var todayCents: Int = 0
    var todayCount: Int = 0
    var topCategory: String = ""
    var topCategoryCents: Int = 0
    var dueSoon: [DueCard] = []
    var updated: Date = .now

    struct DueCard: Codable, Identifiable {
        var id: String { name }
        var name: String
        var daysUntil: Int
        var owedCents: Int
        var colorHex: String
    }

    /// Spend pace vs cycle pace. >1 means spending faster than the month runs.
    var pace: Double {
        guard budgetCents > 0, cycleProgress > 0.02 else { return 0 }
        return (Double(cycleSpentCents) / Double(budgetCents)) / cycleProgress
    }
}

enum SnapshotStore {
    /// Must match the App Group added in the target's capabilities.
    static let appGroup = "group.com.yourname.ledger"
    private static let key = "widget.snapshot"

    static func write(_ snap: LedgerSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func read() -> LedgerSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: key),
              let snap = try? JSONDecoder().decode(LedgerSnapshot.self, from: data)
        else { return LedgerSnapshot() }
        return snap
    }
}
