import SwiftUI
import CoreData

// MARK: - Budget vs actual
//
// The question this answers isn't "how much did I spend" — the headline already
// says that. It's "am I going to be over by the end of the cycle", which needs
// two things the raw total doesn't give you: a target, and where you *should*
// be given how far through the month you are.
//
// So each row shows a bar with a pace marker. Being past 60% of the grocery
// budget is fine on day 20 and alarming on day 5, and the marker is what makes
// that legible at a glance rather than requiring arithmetic.

struct BudgetProgressView: View {
    let cycle: Cycle
    let rows: [CDExpense]
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "plannedCents", ascending: false)])
    private var lines: FetchedResults<CDBudgetLine>

    private var progress: Double { cycle.progress() }

    private struct Row: Identifiable {
        let id = UUID()
        let name: String
        let category: Category
        let planned: Money
        let actual: Money
        var ratio: Double { planned.cents == 0 ? 0 : Double(actual.cents) / Double(planned.cents) }
        var over: Bool { actual > planned }
    }

    private var computed: [Row] {
        var actualByCategory: [Category: Int] = [:]
        for r in rows {
            actualByCategory[Category.lenient(r.category ?? ""), default: 0] += Int(r.amountCents)
        }
        return lines.filter { !$0.isIncome }.map { line in
            let cat = Category.lenient(line.category ?? "")
            return Row(name: line.name ?? "—", category: cat,
                       planned: Money(Int(line.plannedCents)),
                       actual: Money(actualByCategory[cat] ?? 0))
        }
        .sorted { $0.ratio > $1.ratio }
    }

    private var totalPlanned: Money { Money(computed.reduce(0) { $0 + $1.planned.cents }) }
    private var totalActual: Money { Money(computed.reduce(0) { $0 + $1.actual.cents }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                FieldLabel(text: "Budget")
                Spacer()
                Text("\(Int(progress * 100))% through the cycle")
                    .font(.system(size: 10)).foregroundStyle(Ink.faint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(totalActual.formatted(cents: false))
                    .font(Face.amount(26)).foregroundStyle(Ink.primary)
                Text("of \(totalPlanned.formatted(cents: false))")
                    .font(Face.body(13)).foregroundStyle(Ink.secondary)
                Spacer()
                let left = totalPlanned - totalActual
                Text(left.cents >= 0 ? "\(left.formatted(cents: false)) left"
                                     : "\(left.abs.formatted(cents: false)) over")
                    .font(Face.body(12, weight: .medium))
                    .foregroundStyle(left.cents >= 0 ? Ink.mint : Ink.coral)
            }

            ForEach(computed.prefix(8)) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: row.category.symbol)
                            .font(.system(size: 10)).foregroundStyle(row.category.tint)
                            .frame(width: 15)
                        Text(row.name).font(Face.body(13))
                        Spacer()
                        Text(row.actual.formatted(cents: false))
                            .font(Face.figure(13, weight: .medium))
                            .foregroundStyle(row.over ? Ink.coral : Ink.primary)
                        Text("/ \(row.planned.formatted(cents: false))")
                            .font(Face.figure(11)).foregroundStyle(Ink.faint)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Ink.rule).frame(height: 6)
                            Capsule()
                                .fill(row.over ? Ink.coral
                                      : (row.ratio > progress + 0.15 ? Ink.brass : Ink.mint))
                                .frame(width: geo.size.width * min(row.ratio, 1), height: 6)
                            // Pace marker: where this should be right now.
                            // Budget/category visuals are in scope for the
                            // cinematic accent, per DESIGN-DIRECTION-CINEMATIC.md.
                            Rectangle().fill(Ink.accent)
                                .frame(width: 1.5, height: 11)
                                .offset(x: geo.size.width * progress, y: -2.5)
                        }
                    }
                    .frame(height: 11)
                }
            }

            Text("The vertical line is where each bar should be if you spent evenly through the cycle.")
                .font(.system(size: 10)).foregroundStyle(Ink.faint)
        }
        .padding(18)
        .glassPanel()
    }
}

// MARK: - Widget snapshot publisher
//
// Called after every save. Keeps widgets fast by giving them a tiny pre-computed
// blob instead of a second Core Data + CloudKit stack.

enum SnapshotPublisher {
    @MainActor
    static func refresh(context: NSManagedObjectContext) {
        let analytics = Analytics()
        let cycle = analytics.calendar.cycle(containing: .now)

        let expReq = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        expReq.predicate = NSPredicate(format: "cycleKey == %@ AND needsReview == NO", cycle.key)
        let rows = (try? context.fetch(expReq)) ?? []

        let budgetReq = NSFetchRequest<CDBudgetLine>(entityName: "CDBudgetLine")
        let budget = (try? context.fetch(budgetReq)) ?? []
        let budgetTotal = budget.filter { !$0.isIncome }.reduce(0) { $0 + Int($1.plannedCents) }

        let cal = Calendar.current
        let todayRows = rows.filter { cal.isDateInToday($0.date ?? .distantPast) }

        let byCategory = analytics.byCategory(rows)

        let cardReq = NSFetchRequest<CDCard>(entityName: "CDCard")
        cardReq.predicate = NSPredicate(format: "isClosed == NO AND isCash == NO AND dueDay > 0")
        let cards = (try? context.fetch(cardReq)) ?? []
        let dates = StatementDates()
        let engine = StatementEngine(context: context)

        let due = cards.compactMap { card -> LedgerSnapshot.DueCard? in
            guard let name = card.name,
                  let days = dates.daysUntilDue(dueDay: Int(card.dueDay)) else { return nil }
            let owed = engine.charges(card: card, cycleKey: cycle.key)
                     + engine.carryForwardInto(card: card, cycleKey: cycle.key)
            return LedgerSnapshot.DueCard(name: name, daysUntil: days,
                                          owedCents: owed.cents,
                                          colorHex: card.colorHex ?? "#8E8E93")
        }
        .sorted { $0.daysUntil < $1.daysUntil }

        let snap = LedgerSnapshot(
            cycleLabel: cycle.shortLabel,
            cycleSpentCents: rows.reduce(0) { $0 + Int($1.amountCents) },
            budgetCents: budgetTotal,
            cycleProgress: cycle.progress(),
            todayCents: todayRows.reduce(0) { $0 + Int($1.amountCents) },
            todayCount: todayRows.count,
            topCategory: byCategory.first?.category.rawValue ?? "",
            topCategoryCents: byCategory.first?.total.cents ?? 0,
            dueSoon: Array(due.prefix(3)))

        SnapshotStore.write(snap)
    }
}
