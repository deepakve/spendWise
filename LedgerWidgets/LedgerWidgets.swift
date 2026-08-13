import WidgetKit
import SwiftUI
import AppIntents

// Widgets.
//
// You asked what a widget could usefully show. The test I applied: it should
// answer a question you'd otherwise open the app for, in the time it takes to
// glance. Four passed that test, and a few obvious ideas failed it — a list of
// recent transactions, for instance, tells you nothing you can act on.
//
//   1. Cycle pace (small)      — spend so far vs budget, and whether you're
//                                ahead of where the month says you should be
//   2. Next bills (medium)     — the three soonest due dates with amounts
//   3. Quick log (Lock Screen) — one tap straight into add-expense
//   4. Today (Lock Screen)     — what you've logged today, to stop double entry
//
// The app writes a small snapshot to a shared App Group container after every
// change; widgets read that rather than opening Core Data, which keeps them
// fast and avoids a second CloudKit connection.

// MARK: - Shared snapshot
//
// LedgerSnapshot and SnapshotStore live in Ledger/Core/Snapshot.swift, in the
// main app target, not here — this file isn't part of any build target yet
// (the widget extension needs its own Xcode target; see job 5 in HANDOFF.md).
// Once that target exists, add Snapshot.swift to its membership alongside
// this file so both share the same types.

// MARK: - Timeline

struct LedgerEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerSnapshot
}

struct LedgerProvider: TimelineProvider {
    func placeholder(in context: Context) -> LedgerEntry {
        LedgerEntry(date: .now, snapshot: LedgerSnapshot())
    }
    func getSnapshot(in context: Context, completion: @escaping (LedgerEntry) -> Void) {
        completion(LedgerEntry(date: .now, snapshot: SnapshotStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LedgerEntry>) -> Void) {
        let entry = LedgerEntry(date: .now, snapshot: SnapshotStore.read())
        // Refresh hourly; the app also pushes an update on every save.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - 1. Cycle pace

struct CyclePaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CyclePace", provider: LedgerProvider()) { entry in
            CyclePaceView(snap: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cycle pace")
        .description("Spend so far against your budget, and whether you're ahead of the month.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct CyclePaceView: View {
    let snap: LedgerSnapshot
    @Environment(\.widgetFamily) private var family

    private var spent: Money { Money(snap.cycleSpentCents) }
    private var budget: Money { Money(snap.budgetCents) }
    private var ratio: Double {
        snap.budgetCents == 0 ? 0 : min(Double(snap.cycleSpentCents) / Double(snap.budgetCents), 1)
    }
    private var isAhead: Bool { snap.pace > 1.05 }

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.cycleLabel).font(.caption2).opacity(0.7)
                Text(spent.formatted(cents: false)).font(.title3.weight(.semibold))
                ProgressView(value: ratio).tint(isAhead ? .orange : .green)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(snap.cycleLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isAhead ? "flame.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isAhead ? .orange : .green)
                }
                Text(spent.formatted(cents: false))
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                    .minimumScaleFactor(0.6).lineLimit(1)

                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(.quaternary).frame(height: 6)
                        Capsule().fill(isAhead ? .orange : .green)
                            .frame(width: geo.size.width * ratio, height: 6)
                        // Where you *should* be, given how far the cycle has run.
                        Rectangle().fill(.primary.opacity(0.5))
                            .frame(width: 1.5, height: 12)
                            .offset(x: geo.size.width * snap.cycleProgress, y: -3)
                    }
                    .frame(height: 6)
                }
                .frame(height: 12)

                if snap.budgetCents > 0 {
                    Text("of \(budget.formatted(cents: false)) · \(Int(snap.cycleProgress * 100))% through")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if !snap.topCategory.isEmpty {
                    Text("\(snap.topCategory) \(Money(snap.topCategoryCents).formatted(cents: false))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - 2. Next bills

struct BillsDueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BillsDue", provider: LedgerProvider()) { entry in
            BillsDueView(snap: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bills due")
        .description("The next payments, with what's on each card.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

struct BillsDueView: View {
    let snap: LedgerSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular {
            if let first = snap.dueSoon.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(first.name) · \(first.daysUntil)d").font(.caption2.weight(.medium))
                    Text(Money(first.owedCents).formatted(cents: false))
                        .font(.title3.weight(.semibold))
                }
            } else {
                Text("No bills due").font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Text("NEXT PAYMENTS")
                    .font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(.secondary)
                ForEach(snap.dueSoon.prefix(3)) { card in
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: card.colorHex)).frame(width: 4, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(card.daysUntil == 0 ? "Due today" : "in \(card.daysUntil) days")
                                .font(.system(size: 10))
                                .foregroundStyle(card.daysUntil <= 3 ? .red : .secondary)
                        }
                        Spacer()
                        Text(Money(card.owedCents).formatted(cents: false))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                }
                if snap.dueSoon.isEmpty {
                    Text("Nothing due soon").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 3 & 4. Lock Screen

struct QuickLogWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickLog", provider: LedgerProvider()) { entry in
            QuickLogView(snap: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("What you've logged today. Tap to add another.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct QuickLogView: View {
    let snap: LedgerSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("Today \(Money(snap.todayCents).formatted(cents: false)) · \(snap.todayCount)")
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text(Money(snap.todayCents).formatted(cents: false))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(1)
                }
            }
        }
    }
}

@main
struct LedgerWidgets: WidgetBundle {
    var body: some Widget {
        CyclePaceWidget()
        BillsDueWidget()
        QuickLogWidget()
    }
}
