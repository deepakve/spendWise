import SwiftUI
import CoreData

// Signup bonus tracking.
//
// Your Chase Sapphire has $5,000 to spend in three months for 100k points.
// Missing that deadline by $200 costs the entire bonus, and the only way to
// miss it is not to notice — which is exactly what a spreadsheet you check
// monthly lets happen.
//
// So the tracker is built around one number: **how much per day from here**.
// A raw "spent $2,100 of $5,000" tells you nothing actionable. "$62/day for
// the next 47 days, and you're currently averaging $48" tells you to move
// groceries onto this card this week.

struct BonusProgress {
    let card: CDCard
    let target: Money
    let spent: Money
    let startsOn: Date
    let endsOn: Date
    let reward: String

    var remaining: Money { Money(max(target.cents - spent.cents, 0)) }
    var isComplete: Bool { spent >= target }

    var daysLeft: Int {
        max(Calendar.current.dateComponents([.day], from: .now, to: endsOn).day ?? 0, 0)
    }
    var daysElapsed: Int {
        max(Calendar.current.dateComponents([.day], from: startsOn, to: .now).day ?? 1, 1)
    }
    var totalDays: Int {
        max(Calendar.current.dateComponents([.day], from: startsOn, to: endsOn).day ?? 1, 1)
    }

    var fraction: Double {
        target.cents == 0 ? 0 : min(Double(spent.cents) / Double(target.cents), 1)
    }
    var timeFraction: Double {
        min(Double(daysElapsed) / Double(totalDays), 1)
    }

    /// Required daily spend from today to finish on time.
    var neededPerDay: Money {
        guard daysLeft > 0, !isComplete else { return .zero }
        return Money(remaining.cents / daysLeft)
    }
    /// Actual daily spend so far.
    var actualPerDay: Money { Money(spent.cents / max(daysElapsed, 1)) }

    /// True when spending is behind where it needs to be.
    var isBehind: Bool { !isComplete && fraction < timeFraction }

    var status: String {
        if isComplete { return "Earned" }
        if daysLeft == 0 { return "Deadline passed" }
        if isBehind { return "Behind pace" }
        return "On track"
    }
    var tint: Color {
        if isComplete { return Ink.mint }
        if daysLeft == 0 { return Ink.coral }
        if isBehind { return daysLeft < 30 ? Ink.coral : Ink.brass }
        return Ink.mint
    }
}

enum BonusEngine {
    static func progress(for card: CDCard, context: NSManagedObjectContext) -> BonusProgress? {
        guard card.bonusTargetCents > 0,
              let start = card.bonusStartsOn,
              let end = card.bonusEndsOn else { return nil }

        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        r.predicate = NSPredicate(
            format: "card == %@ AND date >= %@ AND date <= %@ AND needsReview == NO",
            card, start as NSDate, end as NSDate)
        let rows = (try? context.fetch(r)) ?? []
        // Refunds reduce qualifying spend, which is how issuers count it too.
        let spent = Money(rows.reduce(0) { $0 + Int($1.amountCents) })

        return BonusProgress(card: card, target: Money(Int(card.bonusTargetCents)),
                             spent: spent, startsOn: start, endsOn: end,
                             reward: card.bonusReward ?? "")
    }

    static func active(context: NSManagedObjectContext) -> [BonusProgress] {
        let r = NSFetchRequest<CDCard>(entityName: "CDCard")
        r.predicate = NSPredicate(format: "bonusTargetCents > 0")
        let cards = (try? context.fetch(r)) ?? []
        return cards.compactMap { progress(for: $0, context: context) }
            .filter { $0.daysLeft > 0 || $0.isComplete }
            .sorted { $0.daysLeft < $1.daysLeft }
    }
}

// MARK: - Dashboard card

struct BonusTrackerView: View {
    let progress: BonusProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    FieldLabel(text: "Signup bonus")
                    Text(progress.card.name ?? "—")
                        .font(Face.body(16, weight: .semibold))
                }
                Spacer()
                Text(progress.status.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.9)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(progress.tint, in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(progress.spent.formatted(cents: false))
                    .font(Face.amount(30)).foregroundStyle(Ink.primary)
                Text("of \(progress.target.formatted(cents: false))")
                    .font(Face.body(14)).foregroundStyle(Ink.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.rule).frame(height: 9)
                    Capsule().fill(progress.tint)
                        .frame(width: geo.size.width * progress.fraction, height: 9)
                    // Where spending should be, given the time elapsed.
                    Rectangle().fill(Ink.primary.opacity(0.5))
                        .frame(width: 2, height: 16)
                        .offset(x: geo.size.width * progress.timeFraction, y: -3.5)
                }
            }
            .frame(height: 16)

            if progress.isComplete {
                Label("Bonus earned. \(progress.reward)", systemImage: "checkmark.seal.fill")
                    .font(Face.body(13, weight: .medium))
                    .foregroundStyle(Ink.mint)
            } else {
                Perforation()
                VStack(spacing: 9) {
                    LedgerRow(label: "Still to spend", emphasis: true) {
                        Text(progress.remaining.formatted(cents: false))
                            .font(Face.figure(15, weight: .semibold))
                    }
                    LedgerRow(label: "Days left") {
                        Text("\(progress.daysLeft)")
                            .font(Face.figure(15, weight: .medium))
                            .foregroundStyle(progress.daysLeft < 30 ? Ink.coral : Ink.primary)
                    }
                    LedgerRow(label: "Needed per day", emphasis: true) {
                        Text(progress.neededPerDay.formatted(cents: false))
                            .font(Face.figure(15, weight: .semibold))
                            .foregroundStyle(progress.tint)
                    }
                    LedgerRow(label: "Averaging") {
                        Text(progress.actualPerDay.formatted(cents: false))
                            .font(Face.figure(15, weight: .medium))
                    }
                }

                if progress.isBehind {
                    Text("You're spending \(progress.actualPerDay.formatted(cents: false))/day but need \(progress.neededPerDay.formatted(cents: false))/day. Moving groceries and fuel onto this card would close the gap.")
                        .font(Face.body(11)).foregroundStyle(Ink.coral)
                        .padding(.top, 2)
                }
                if !progress.reward.isEmpty {
                    Text(progress.reward).font(.system(size: 10)).foregroundStyle(Ink.faint)
                }
            }
        }
        .padding(18)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(progress.isBehind ? progress.tint.opacity(0.5) : Ink.rule,
                          lineWidth: progress.isBehind ? 1.5 : 1))
    }
}

// MARK: - Setup

struct BonusEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var card: CDCard

    @State private var target = ""
    @State private var starts = Date()
    @State private var months = 3
    @State private var reward = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Spend target"); Spacer()
                        TextField("5000", text: $target).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing).frame(width: 110)
                    }
                    DatePicker("Account opened", selection: $starts,
                               displayedComponents: .date)
                    Picker("Window", selection: $months) {
                        ForEach([3, 4, 6, 12], id: \.self) { Text("\($0) months").tag($0) }
                    }
                    TextField("Reward — e.g. 100k points", text: $reward)
                } footer: {
                    Text("Only purchases on this card between the open date and the deadline count. Refunds reduce qualifying spend, which is how issuers count it too.")
                }

                if card.bonusTargetCents > 0 {
                    Section {
                        Button("Remove bonus tracking", role: .destructive) {
                            card.bonusTargetCents = 0
                            card.bonusStartsOn = nil; card.bonusEndsOn = nil
                            Persistence.shared.save(); dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Signup bonus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let m = Money.parse(target) else { return }
                        card.bonusTargetCents = Int64(m.cents)
                        card.bonusStartsOn = starts
                        card.bonusEndsOn = Calendar.current.date(
                            byAdding: .month, value: months, to: starts)
                        card.bonusReward = reward
                        Persistence.shared.save()
                        dismiss()
                    }
                    .disabled(Money.parse(target) == nil)
                }
            }
            .onAppear {
                if card.bonusTargetCents > 0 {
                    target = String(Int(card.bonusTargetCents) / 100)
                    starts = card.bonusStartsOn ?? .now
                    reward = card.bonusReward ?? ""
                }
            }
        }
    }
}
