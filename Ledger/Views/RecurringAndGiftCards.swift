import SwiftUI
import CoreData

// MARK: - Recurring bills waiting to be confirmed

struct RecurringInboxView: View {
    @Environment(\.managedObjectContext) private var ctx
    @StateObject private var store = RecurringStore.shared
    @State private var edits: [UUID: String] = [:]

    private var pending: [RecurringRule] { store.due() }

    var body: some View {
        List {
            if pending.isEmpty {
                ContentUnavailableView("Nothing waiting", systemImage: "checkmark.seal",
                                       description: Text("Recurring bills appear here on their due day."))
            }
            ForEach(pending) { rule in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(Face.body(16, weight: .semibold))
                            Text("\(rule.merchant) · \(rule.cardName) · day \(rule.dayOfMonth)")
                                .font(.system(size: 11)).foregroundStyle(Ink.faint)
                        }
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        Text("$").foregroundStyle(Ink.secondary)
                        TextField(String(format: "%.2f", Double(rule.amountCents)/100),
                                  text: Binding(
                                    get: { edits[rule.id] ?? String(format: "%.2f", Double(rule.amountCents)/100) },
                                    set: { edits[rule.id] = $0 }))
                            .font(Face.figure(19, weight: .medium))
                            .keyboardType(.decimalPad)
                        Spacer()
                        Button("Skip") { store.skip(rule) }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Confirm") {
                            let text = edits[rule.id] ?? String(format: "%.2f", Double(rule.amountCents)/100)
                            guard let amount = Money.parse(text) else { return }
                            store.confirm(rule, amount: amount, date: .now, context: ctx)
                            Haptic.success()
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Recurring")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RecurringSettingsView: View {
    @StateObject private var store = RecurringStore.shared

    var body: some View {
        List {
            Section {
                Text("These post as proposals on their due day — never automatically. Confirming one updates its remembered amount, so a bill that drifts is learned rather than fought.")
                    .font(Face.body(12)).foregroundStyle(Ink.secondary)
            }
            ForEach($store.rules) { $rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(isOn: $rule.isActive) {
                            Text(rule.name).font(Face.body(15, weight: .medium))
                        }
                    }
                    Text("\(rule.amount.formatted()) · \(rule.cardName) · day \(rule.dayOfMonth)")
                        .font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }
            .onDelete { store.rules.remove(atOffsets: $0) }
        }
        .navigationTitle("Recurring bills")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Gift cards
//
// Your workbook tracks these on their own sheet — $316.99 of Costco cards
// purchased, $102.77 used. They're a second currency and the failure mode is
// double counting: buying the card is the expense, spending it isn't. This
// tracks the balance without letting redemptions inflate your cycle totals.

struct GiftCard: Codable, Identifiable, Hashable {
    var id = UUID()
    var brand: String
    var purchasedOn: Date
    var faceValueCents: Int
    var redemptions: [Redemption] = []
    var isArchived = false
    var note: String = ""

    struct Redemption: Codable, Identifiable, Hashable {
        var id = UUID()
        var date: Date
        var amountCents: Int
        var note: String = ""
    }

    var redeemedCents: Int { redemptions.reduce(0) { $0 + $1.amountCents } }
    var remaining: Money { Money(faceValueCents - redeemedCents) }
    var faceValue: Money { Money(faceValueCents) }
    var progress: Double {
        faceValueCents == 0 ? 0 : min(Double(redeemedCents) / Double(faceValueCents), 1)
    }
}

@MainActor
final class GiftCardStore: ObservableObject {
    static let shared = GiftCardStore()
    private let key = "giftcards.v1"
    @Published var cards: [GiftCard] = [] { didSet { persist() } }

    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([GiftCard].self, from: d) {
            cards = decoded
        }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
    var totalRemaining: Money {
        Money(cards.filter { !$0.isArchived }.reduce(0) { $0 + $1.remaining.cents })
    }
}

struct GiftCardsView: View {
    @StateObject private var store = GiftCardStore.shared
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        FieldLabel(text: "Unused balance")
                        Text(store.totalRemaining.formatted())
                            .font(Face.amount(30)).foregroundStyle(Ink.primary)
                    }
                    Spacer()
                    Image(systemName: "giftcard.fill")
                        .font(.system(size: 34)).foregroundStyle(Ink.brass.opacity(0.5))
                }
                .padding(.vertical, 8)
            }

            ForEach($store.cards.filter { !$0.wrappedValue.isArchived }) { $card in
                NavigationLink { GiftCardDetail(card: $card) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(card.brand).font(Face.body(15, weight: .medium))
                            Spacer()
                            Text(card.remaining.formatted())
                                .font(Face.figure(15, weight: .semibold))
                                .foregroundStyle(card.remaining.cents > 0 ? Ink.mint : Ink.faint)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Ink.rule).frame(height: 5)
                                Capsule().fill(Ink.brass)
                                    .frame(width: geo.size.width * card.progress, height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text("\(Money(card.redeemedCents).formatted(cents: false)) of \(card.faceValue.formatted(cents: false)) used")
                            .font(.system(size: 10)).foregroundStyle(Ink.faint)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Button { showAdd = true } label: { Label("Add gift card", systemImage: "plus") }
            } footer: {
                Text("Log the purchase as a normal expense on the card you bought it with. Redemptions here only draw down the balance — they don't count again against your cycle total.")
            }
        }
        .navigationTitle("Gift cards")
        .sheet(isPresented: $showAdd) { AddGiftCardView() }
    }
}

struct GiftCardDetail: View {
    @Binding var card: GiftCard
    @State private var amount = ""
    @State private var note = ""

    var body: some View {
        List {
            Section {
                LedgerRow(label: "Face value") {
                    Text(card.faceValue.formatted()).font(Face.figure(15))
                }
                LedgerRow(label: "Used") {
                    Text(Money(card.redeemedCents).formatted()).font(Face.figure(15))
                }
                LedgerRow(label: "Remaining", emphasis: true) {
                    Text(card.remaining.formatted())
                        .font(Face.figure(15, weight: .semibold))
                        .foregroundStyle(Ink.mint)
                }
            }
            Section("Use some of it") {
                HStack {
                    Text("$")
                    TextField("0.00", text: $amount).keyboardType(.decimalPad)
                        .font(Face.figure(17))
                }
                TextField("What for?", text: $note)
                Button("Record") {
                    guard let m = Money.parse(amount) else { return }
                    card.redemptions.append(.init(date: .now, amountCents: m.cents, note: note))
                    amount = ""; note = ""
                    Haptic.success()
                }
                .disabled(Money.parse(amount) == nil)
            }
            if !card.redemptions.isEmpty {
                Section("History") {
                    ForEach(card.redemptions.reversed()) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(Face.body(13))
                                if !r.note.isEmpty {
                                    Text(r.note).font(.system(size: 11))
                                        .foregroundStyle(Ink.faint)
                                }
                            }
                            Spacer()
                            Text(Money(r.amountCents).formatted()).font(Face.figure(14))
                        }
                    }
                }
            }
            Section {
                Toggle("Archived", isOn: $card.isArchived)
            }
        }
        .navigationTitle(card.brand)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddGiftCardView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = GiftCardStore.shared
    @State private var brand = ""
    @State private var value = ""
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Brand — e.g. Costco", text: $brand)
                HStack {
                    Text("Face value"); Spacer()
                    TextField("0.00", text: $value).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).frame(width: 110)
                }
                DatePicker("Purchased", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("New gift card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let m = Money.parse(value) else { return }
                        store.cards.append(GiftCard(brand: brand, purchasedOn: date,
                                                    faceValueCents: m.cents))
                        dismiss()
                    }
                    .disabled(brand.isEmpty || Money.parse(value) == nil)
                }
            }
        }
    }
}
