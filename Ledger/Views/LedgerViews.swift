import SwiftUI
import CoreData

// MARK: - Browse & search every record

struct LedgerView: View {
    @Environment(\.managedObjectContext) private var ctx
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)])
    private var expenses: FetchedResults<CDExpense>

    var presetCycleKey: String? = nil
    var presetFilter: String? = nil

    @State private var search = ""
    @State private var cycleFilter: String = "all"
    @State private var payerFilter: Payer? = nil
    @State private var showAdd = false

    private let analytics = Analytics()

    private var filtered: [CDExpense] {
        var rows = Array(expenses)
        if let presetCycleKey { rows = rows.filter { $0.cycleKey == presetCycleKey } }
        else if cycleFilter != "all" { rows = rows.filter { $0.cycleKey == cycleFilter } }

        if let presetFilter {
            rows = rows.filter {
                $0.category == presetFilter || $0.card?.name == presetFilter || $0.payer == presetFilter
            }
        }
        if let payerFilter { rows = rows.filter { $0.payer == payerFilter.rawValue } }

        if !search.isEmpty {
            let q = search.lowercased()
            rows = rows.filter {
                ($0.merchant ?? "").lowercased().contains(q)
                || ($0.notes ?? "").lowercased().contains(q)
                || ($0.card?.name ?? "").lowercased().contains(q)
                || ($0.category ?? "").lowercased().contains(q)
            }
        }
        return rows
    }

    private var grouped: [(Date, [CDExpense])] {
        Dictionary(grouping: filtered) {
            Calendar.current.startOfDay(for: $0.date ?? .distantPast)
        }
        .sorted { $0.key > $1.key }
        .map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Showing \(filtered.count)")
                    Spacer()
                    Text(analytics.total(filtered).formatted())
                        .fontWeight(.semibold).monospacedDigit()
                }
                .font(.subheadline)
            }

            if presetCycleKey == nil {
                Section {
                    Picker("Cycle", selection: $cycleFilter) {
                        Text("All cycles").tag("all")
                        ForEach(analytics.calendar.recent(18)) { c in
                            Text(c.label).tag(c.key)
                        }
                    }
                    Picker("Who", selection: $payerFilter) {
                        Text("Everyone").tag(Payer?.none)
                        ForEach(Payer.allCases) { Text($0.rawValue).tag(Payer?.some($0)) }
                    }
                }
            }

            ForEach(grouped, id: \.0) { day, rows in
                Section(day.formatted(.dateTime.weekday(.abbreviated).month().day().year())) {
                    ForEach(rows, id: \.objectID) { e in
                        NavigationLink { EditExpenseView(expense: e) } label: { row(e) }
                    }
                    .onDelete { idx in
                        for i in idx { ctx.delete(rows[i]) }
                        Persistence.shared.save()
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Merchant, note, person, card")
        .navigationTitle(presetFilter ?? "Ledger")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { QuickAddView(defaultDate: .now) }
    }

    private func row(_ e: CDExpense) -> some View {
        let cat = Category.lenient(e.category ?? "")
        return HStack {
            Image(systemName: cat.symbol).foregroundStyle(cat.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.merchant ?? "—")
                HStack(spacing: 5) {
                    if let c = e.card?.name { Text(c) }
                    if let p = e.payer, p != "Us" { Text("· \(p)") }
                    if let n = e.notes, !n.isEmpty { Text("· \(n)").lineLimit(1) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money(Int(e.amountCents)).formatted())
                .monospacedDigit()
                .foregroundStyle(e.amountCents < 0 ? .green : .primary)
        }
    }
}

// MARK: - Edit

struct EditExpenseView: View {
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var expense: CDExpense
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true)])
    private var cards: FetchedResults<CDCard>

    @State private var amount = ""
    @State private var loaded = false

    var body: some View {
        Form {
            HStack {
                Text("Amount")
                Spacer()
                TextField("0.00", text: $amount)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing).frame(width: 120)
            }
            TextField("Merchant", text: Binding(
                get: { expense.merchant ?? "" },
                set: { expense.merchant = $0; expense.merchantKey = $0.lowercased() }))
            DatePicker("Date", selection: Binding(
                get: { expense.date ?? .now },
                set: { expense.date = $0; expense.cycleKey = CycleCalendar.key(for: $0) }),
                displayedComponents: .date)
            Picker("Category", selection: Binding(
                get: { Category.lenient(expense.category ?? "") },
                set: { expense.category = $0.rawValue })) {
                ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Card", selection: Binding(
                get: { expense.card }, set: { expense.card = $0 })) {
                Text("None").tag(CDCard?.none)
                ForEach(cards, id: \.objectID) { Text($0.name ?? "—").tag(CDCard?.some($0)) }
            }
            Picker("Who", selection: Binding(
                get: { Payer(rawValue: expense.payer ?? "Us") ?? .us },
                set: { expense.payer = $0.rawValue })) {
                ForEach(Payer.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Notes", text: Binding(
                get: { expense.notes ?? "" }, set: { expense.notes = $0 }), axis: .vertical)

            if expense.needsReview {
                Button("Mark reviewed") {
                    expense.needsReview = false
                    Persistence.shared.save()
                }
            }

            Section {
                Button("Delete", role: .destructive) {
                    ctx.delete(expense)
                    Persistence.shared.save()
                    dismiss()
                }
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loaded {
                amount = String(format: "%.2f", Double(expense.amountCents) / 100)
                loaded = true
            }
        }
        .onDisappear {
            if let m = Money.parse(amount) { expense.amountCents = Int64(m.cents) }
            expense.updatedAt = .now
            Persistence.shared.save()
        }
    }
}
