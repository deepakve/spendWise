import SwiftUI
import CoreData
import Charts

struct DashboardView: View {
    @Environment(\.managedObjectContext) private var ctx
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)])
    private var expenses: FetchedResults<CDExpense>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true)])
    private var cards: FetchedResults<CDCard>

    @State private var cycleKey = CycleCalendar.key(for: .now)
    @State private var breakdown: Breakdown = .category
    @State private var showAdd = false
    @State private var showScan = false

    private let analytics = Analytics()
    private let dates = StatementDates()

    enum Breakdown: String, CaseIterable, Identifiable {
        case category = "Category", card = "Card", person = "Person"
        var id: String { rawValue }
    }

    private var cycle: Cycle { analytics.calendar.cycle(key: cycleKey) }
    private var rows: [CDExpense] { analytics.inCycle(Array(expenses), cycleKey) }
    private var prevRows: [CDExpense] {
        analytics.inCycle(Array(expenses), analytics.calendar.previous(cycle).key)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    cyclePicker
                    headline
                    ForEach(BonusEngine.active(context: ctx), id: \.card.objectID) { p in
                        BonusTrackerView(progress: p)
                    }
                    Picker("Breakdown", selection: $breakdown) {
                        ForEach(Breakdown.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    donut
                    breakdownList
                    BudgetProgressView(cycle: cycle, rows: rows)
                    trendChart
                    dueSoon
                }
                .padding()
            }
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add manually", systemImage: "plus") }
                        Button { showScan = true } label: { Label("Scan a receipt", systemImage: "doc.viewfinder") }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(isPresented: $showAdd) { QuickAddView(defaultDate: .now) }
            .sheet(isPresented: $showScan) { ScanReceiptView() }
        }
    }

    // Horizontal cycle strip. Range is shown as well as the month name, because
    // a 10th-to-9th month is easy to misread as a calendar month later.
    private var cyclePicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(analytics.calendar.recent(18)) { c in
                        Button { withAnimation { cycleKey = c.key } } label: {
                            VStack(spacing: 2) {
                                Text(c.shortLabel).font(.subheadline.weight(.medium))
                                Text(c.rangeLabel).font(.caption2)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(c.key == cycleKey ? Color.accentColor.opacity(0.2)
                                                          : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).id(c.key)
                    }
                }
            }
            .onAppear { proxy.scrollTo(cycleKey, anchor: .trailing) }
        }
    }

    private var headline: some View {
        let total = analytics.total(rows)
        let delta = total - analytics.total(prevRows)
        return VStack(spacing: 6) {
            Text(total.formatted())
                .font(.system(size: 42, weight: .semibold, design: .rounded))
            HStack(spacing: 4) {
                Image(systemName: delta.cents >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text("\(delta.abs.formatted(cents: false)) vs last cycle")
            }
            .font(.footnote)
            .foregroundStyle(delta.cents >= 0 ? .red : .green)

            if cycle.contains(.now) {
                Text("On pace for \(analytics.projected(rows, cycle: cycle).formatted(cents: false))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(rows.count) transactions · \(cycle.rangeLabel)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private struct Slice: Identifiable {
        let id = UUID(); let name: String; let amount: Double; let tint: Color
    }

    private var slices: [Slice] {
        switch breakdown {
        case .category:
            analytics.byCategory(rows).filter { $0.total.cents > 0 }
                .map { Slice(name: $0.category.rawValue, amount: $0.total.dollars, tint: $0.category.tint) }
        case .card:
            analytics.byCard(rows).filter { $0.total.cents > 0 }
                .map { Slice(name: $0.name, amount: $0.total.dollars, tint: color(for: $0.name)) }
        case .person:
            analytics.byPayer(rows).filter { $0.total.cents > 0 }
                .map { Slice(name: $0.payer.rawValue, amount: $0.total.dollars, tint: $0.payer.tint) }
        }
    }

    private var donut: some View {
        Chart(slices) { s in
            SectorMark(angle: .value("Amount", s.amount),
                       innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(s.tint)
                .cornerRadius(3)
        }
        .frame(height: 220)
        .overlay {
            VStack(spacing: 0) {
                Text(slices.first?.name ?? "—").font(.caption).foregroundStyle(.secondary)
                Text(Money(dollars: slices.first?.amount ?? 0).formatted(cents: false))
                    .font(.title3.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private var breakdownList: some View {
        VStack(spacing: 0) {
            ForEach(slices) { s in
                NavigationLink {
                    LedgerView(presetCycleKey: cycleKey, presetFilter: s.name)
                } label: {
                    HStack {
                        Circle().fill(s.tint).frame(width: 10, height: 10)
                        Text(s.name)
                        Spacer()
                        Text(Money(dollars: s.amount).formatted(cents: false)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    // Six cycles of history, so "did I spend too much this month" has a baseline
    // rather than being a number floating in space.
    private var trendChart: some View {
        let recent = analytics.calendar.recent(6)
        let data = recent.map { c in
            (label: c.shortLabel,
             amount: analytics.total(analytics.inCycle(Array(expenses), c.key)).dollars,
             isCurrent: c.key == cycleKey)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 6 cycles").font(.headline)
            Chart(data, id: \.label) { d in
                BarMark(x: .value("Cycle", d.label), y: .value("Total", d.amount))
                    .foregroundStyle(d.isCurrent ? Color.accentColor : Color.secondary.opacity(0.4))
                    .cornerRadius(4)
            }
            .frame(height: 150)
        }
        .padding()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var dueSoon: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Due soon").font(.headline)
            ForEach(cards.filter { !$0.isCash && !$0.isClosed && $0.dueDay > 0 }
                .sorted { (dates.daysUntilDue(dueDay: Int($0.dueDay)) ?? 99)
                        < (dates.daysUntilDue(dueDay: Int($1.dueDay)) ?? 99) }
                .prefix(5), id: \.objectID) { card in
                NavigationLink {
                    StatementView(card: card, cycleKey: cycleKey)
                } label: {
                    HStack {
                        Text(card.name ?? "—")
                        Spacer()
                        if let d = dates.daysUntilDue(dueDay: Int(card.dueDay)) {
                            Text(d == 0 ? "Today" : "in \(d)d")
                                .font(.caption.weight(d <= 3 ? .semibold : .regular))
                                .foregroundStyle(d <= 3 ? .red : .secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal,
                                .indigo, .mint, .cyan, .brown, .red, .yellow]
        return palette[abs(name.hashValue) % palette.count]
    }
}
