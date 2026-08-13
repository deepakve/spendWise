import SwiftUI
import CoreData

// The bill-paying screen. It answers, in order:
//   1. What did I charge this cycle?
//   2. What does the bank say I owe? (you type it from the statement)
//   3. Is there a gap — did I miss logging something?
//   4. How much did I pay, and what carries forward?

struct StatementView: View {
    @Environment(\.managedObjectContext) private var ctx
    @ObservedObject var card: CDCard
    @State var cycleKey: String

    @State private var statedClosing = ""
    @State private var interest = ""
    @State private var fees = ""
    @State private var paymentAmount = ""
    @State private var paymentDate = Date()
    @State private var showAddMissing = false

    private let analytics = Analytics()

    private var engine: StatementEngine { StatementEngine(context: ctx) }
    private var cycle: Cycle { analytics.calendar.cycle(key: cycleKey) }

    @FetchRequest private var expenses: FetchedResults<CDExpense>

    init(card: CDCard, cycleKey: String) {
        self.card = card
        _cycleKey = State(initialValue: cycleKey)
        _expenses = FetchRequest(
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)],
            predicate: NSPredicate(format: "card == %@ AND cycleKey == %@", card, cycleKey))
    }

    private var statement: CDStatement { engine.statement(for: card, cycleKey: cycleKey) }
    private var math: StatementMath { engine.math(for: statement) }

    var body: some View {
        List {
            cycleSection
            summarySection
            reconcileSection
            paymentSection
            transactionsSection
        }
        .navigationTitle(card.name ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddMissing) {
            QuickAddView(defaultDate: cycle.end, defaultCard: card)
        }
        .onAppear(perform: loadFields)
        .onDisappear(perform: persistFields)
    }

    private var cycleSection: some View {
        Section {
            Picker("Cycle", selection: $cycleKey) {
                ForEach(analytics.calendar.recent(18)) { c in
                    Text("\(c.label) · \(c.rangeLabel)").tag(c.key)
                }
            }
            if let due = statement.dueOn {
                LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private var summarySection: some View {
        Section("Balance") {
            row("Carried in", math.previousBalance, muted: true)
            row("Charges this cycle", math.charges)
            row("Interest", math.interest, muted: true)
            row("Fees", math.fees, muted: true)
            row("Payments", -math.payments, muted: true)
            Divider()
            HStack {
                Text("You owe").font(.headline)
                Spacer()
                Text(math.computedClosing.formatted())
                    .font(.headline).monospacedDigit()
            }
        }
    }

    // The gap between what the bank says and what the app computed is the whole
    // reason this screen exists: it's how you find the fee you forgot.
    private var reconcileSection: some View {
        Section {
            HStack {
                Text("Statement says")
                Spacer()
                TextField("0.00", text: $statedClosing)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
            HStack {
                Text("Interest charged")
                Spacer()
                TextField("0.00", text: $interest)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
            HStack {
                Text("Fees")
                Spacer()
                TextField("0.00", text: $fees)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }

            if math.statedClosing.cents != 0 {
                let gap = math.unreconciled
                if gap.cents == 0 {
                    Label("Matches exactly", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(gap.cents > 0
                              ? "\(gap.formatted()) on the statement isn't logged here"
                              : "\(gap.abs.formatted()) logged here isn't on the statement",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if gap.cents > 0 {
                            Button {
                                showAddMissing = true
                            } label: {
                                Label("Add the missing charge", systemImage: "plus.circle")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Reconcile")
        } footer: {
            Text("Type the closing balance from your statement. Any difference means a transaction is missing on one side.")
        }
    }

    private var paymentSection: some View {
        Section("Payment") {
            HStack {
                Text("Amount")
                Spacer()
                TextField("0.00", text: $paymentAmount)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
            DatePicker("Paid on", selection: $paymentDate, displayedComponents: .date)

            HStack(spacing: 8) {
                Button("Pay in full") {
                    paymentAmount = String(format: "%.2f",
                        (math.statedClosing.cents != 0 ? math.statedClosing : math.computedClosing).dollars)
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button("Record") { recordPayment() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(Money.parse(paymentAmount) == nil)
            }

            ForEach(sortedPayments, id: \.objectID) { p in
                HStack {
                    Text(p.paidOn?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                        .font(.caption)
                    Spacer()
                    Text(Money(Int(p.amountCents)).formatted()).monospacedDigit()
                }
            }
            .onDelete(perform: deletePayments)

            if math.isFullyPaid {
                Label("Paid in full", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if math.carryForward.cents > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Carries to next cycle").font(.subheadline.weight(.medium))
                        Spacer()
                        Text(math.carryForward.formatted())
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red).monospacedDigit()
                    }
                    if card.aprBasisPoints > 0 {
                        let cost = math.monthlyInterestCost(aprBasisPoints: Int(card.aprBasisPoints))
                        Text("At \(String(format: "%.2f", Double(card.aprBasisPoints)/100))% APR that costs about \(cost.formatted()) next month.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var transactionsSection: some View {
        Section("\(expenses.count) transactions") {
            Button {
                showAddMissing = true
            } label: {
                Label("Add a missing transaction", systemImage: "plus")
            }
            ForEach(expenses, id: \.objectID) { e in
                NavigationLink { EditExpenseView(expense: e) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.merchant ?? "—")
                            Text(e.date?.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money(Int(e.amountCents)).formatted()).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - helpers

    private var sortedPayments: [CDPayment] {
        let set = (statement.payments as? Set<CDPayment>) ?? []
        return set.sorted { ($0.paidOn ?? .distantPast) < ($1.paidOn ?? .distantPast) }
    }

    private func row(_ label: String, _ amount: Money, muted: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(muted ? .secondary : .primary)
            Spacer()
            Text(amount.formatted()).monospacedDigit()
                .foregroundStyle(muted ? .secondary : .primary)
        }
    }

    private func loadFields() {
        let s = statement
        statedClosing = s.statedClosingCents == 0 ? "" : String(format: "%.2f", Double(s.statedClosingCents)/100)
        interest = s.interestCents == 0 ? "" : String(format: "%.2f", Double(s.interestCents)/100)
        fees = s.feesCents == 0 ? "" : String(format: "%.2f", Double(s.feesCents)/100)
    }

    private func persistFields() {
        let s = statement
        s.statedClosingCents = Int64(Money.parse(statedClosing)?.cents ?? 0)
        s.interestCents = Int64(Money.parse(interest)?.cents ?? 0)
        s.feesCents = Int64(Money.parse(fees)?.cents ?? 0)
        Persistence.shared.save()
    }

    private func recordPayment() {
        guard let amount = Money.parse(paymentAmount) else { return }
        persistFields()
        engine.recordPayment(amount, on: paymentDate, to: statement)
        Persistence.shared.save()
        paymentAmount = ""
    }

    private func deletePayments(at offsets: IndexSet) {
        for i in offsets { ctx.delete(sortedPayments[i]) }
        Persistence.shared.save()
    }
}
