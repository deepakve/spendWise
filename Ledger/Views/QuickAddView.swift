import SwiftUI
import CoreData

// Adding a bill is the thing you'll do fifteen times a week, so it gets the
// most design attention in the app. Principles applied:
//
//   • The amount is the hero. A custom keypad, not the system one — bigger
//     targets, no autocorrect bar stealing 44pt, and a thumb-reachable Save.
//   • The card is chosen by *looking*, not reading. A horizontal rail of real
//     card faces; you recognise Bilt's graphite or Amex Gold's gold instantly.
//   • Everything else is optional and out of the way. Merchant, category and
//     person collapse to a single line each with a sensible guess pre-filled.
//   • One orchestrated success moment, not scattered animation: the amount
//     lifts, a stamp lands, haptic fires. Then it resets for the next one.
//
// The restraint is deliberate. Spending the boldness on the card rail and the
// save stamp means everything around them can stay quiet, which is what makes
// them land.

struct QuickAddView: View {
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true)],
                  predicate: NSPredicate(format: "isClosed == NO"))
    private var cards: FetchedResults<CDCard>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)])
    private var history: FetchedResults<CDExpense>

    var defaultDate: Date = .now
    var defaultCard: CDCard? = nil
    var prefillAmount: Money? = nil
    var prefillMerchant: String? = nil

    @State private var digits = ""
    @State private var merchant = ""
    @State private var category: Category = .foodAndLiving
    @State private var selectedCard: CDCard?
    @State private var date = Date()
    @State private var payer: Payer = .us
    @State private var note = ""
    @State private var isRefund = false

    @State private var showDetails = false
    @State private var saved = false
    @State private var duplicateWarning: String?
    @State private var stampScale: CGFloat = 0.4
    @FocusState private var merchantFocused: Bool

    private var amount: Money {
        Money(isRefund ? -(Int(digits) ?? 0) : (Int(digits) ?? 0))
    }
    private var canSave: Bool { (Int(digits) ?? 0) > 0 && !merchant.isEmpty }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                amountDisplay
                merchantField
                cardRail
                quickChips
                if showDetails { detailFields.transition(.opacity.combined(with: .move(edge: .top))) }
                Spacer(minLength: 8)
                keypad
                saveBar
            }
            if saved { successStamp }
        }
        .onAppear {
            date = defaultDate
            selectedCard = defaultCard ?? history.first?.card ?? cards.first
            if let prefillAmount { digits = String(abs(prefillAmount.cents)) }
            if let prefillMerchant { merchant = prefillMerchant; learn(prefillMerchant) }
        }
    }

    // MARK: header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 36, height: 36)
                    .background(Ink.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Ink.rule))
            }
            Spacer()
            Button {
                Haptic.tap()
                withAnimation(.snappy) { isRefund.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isRefund ? "arrow.uturn.left.circle.fill" : "arrow.up.circle")
                    Text(isRefund ? "Refund" : "Purchase")
                }
                .font(Face.body(13, weight: .medium))
                .foregroundStyle(isRefund ? Ink.mint : Ink.secondary)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(isRefund ? Ink.mint.opacity(0.12) : Ink.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isRefund ? Ink.mint.opacity(0.4) : Ink.rule))
            }
        }
        .padding(.horizontal, 20).padding(.top, 12)
    }

    // MARK: amount

    private var amountDisplay: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(isRefund ? "−$" : "$")
                    .font(Face.amount(34))
                    .foregroundStyle(digits.isEmpty ? Ink.faint : Ink.secondary)
                Text(displayAmount)
                    .font(Face.amount(62))
                    .foregroundStyle(digits.isEmpty ? Ink.faint : (isRefund ? Ink.mint : Ink.primary))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: digits)
            }
            .frame(height: 74)

            if let c = selectedCard, let name = c.name {
                Text(name.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(Ink.faint)
            }
        }
        .padding(.top, 10).padding(.bottom, 18)
    }

    private var displayAmount: String {
        guard let cents = Int(digits), cents > 0 else { return "0.00" }
        return String(format: "%.2f", Double(cents) / 100)
    }

    // MARK: merchant

    private var merchantField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: category.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(category.tint)
                    .frame(width: 34, height: 34)
                    .background(category.tint.opacity(0.14), in: Circle())
                TextField("Where?", text: $merchant)
                    .font(Face.body(17, weight: .medium))
                    .focused($merchantFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onChange(of: merchant) { _, v in learn(v) }
                if !merchant.isEmpty {
                    Button { merchant = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.faint)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.rule))

            if merchantFocused && !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                merchant = s; learn(s); merchantFocused = false; Haptic.tap()
                            } label: {
                                Text(s).font(Face.body(13))
                                    .foregroundStyle(Ink.primary)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Ink.surface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Ink.rule))
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var suggestions: [String] {
        let recent = history.compactMap(\.merchant)
        if merchant.count < 2 {
            var seen = Set<String>()
            return recent.filter { seen.insert($0).inserted }.prefix(6).map { $0 }
        }
        let q = merchant.lowercased()
        var seen = Set<String>()
        return recent.filter { $0.lowercased().contains(q) && seen.insert($0).inserted }
            .prefix(5).map { $0 }
    }

    // MARK: card rail — pick by sight

    private var cardRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(cards, id: \.objectID) { card in
                    let skin = CardSkin.forIssuer(card.issuer ?? "", name: card.name ?? "",
                                                  fallbackHex: card.colorHex ?? "#8E8E93")
                    let isOn = selectedCard?.objectID == card.objectID
                    Button {
                        Haptic.tap()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                            selectedCard = card
                        }
                    } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(colors: [skin.top, skin.bottom],
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing))
                                .frame(width: 62, height: 40)
                                .overlay(alignment: .bottomTrailing) {
                                    if let l = card.last4, !l.isEmpty {
                                        Text(l).font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(skin.ink.opacity(0.85))
                                            .padding(5)
                                    }
                                }
                                .overlay(
                                    // Lime ring on selection — the card rail
                                    // is one of the screens scoped for full
                                    // cinematic treatment.
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Ink.accent, lineWidth: isOn ? 2.5 : 0)
                                )
                                .scaleEffect(isOn ? 1.06 : 1)
                                .shadow(color: (isOn ? Ink.accent : skin.bottom).opacity(isOn ? 0.5 : 0.15),
                                        radius: isOn ? 10 : 3, y: isOn ? 4 : 2)
                            Text(card.name ?? "")
                                .font(.system(size: 9, weight: isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? Ink.primary : Ink.faint)
                                .lineLimit(1).frame(width: 66)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 16)
    }

    // MARK: chips

    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Menu {
                    ForEach(Category.allCases.filter { $0 != .uncategorized }) { c in
                        Button { category = c; Haptic.tap() } label: {
                            Label(c.rawValue, systemImage: c.symbol)
                        }
                    }
                } label: {
                    chip(category.rawValue, symbol: category.symbol, tint: category.tint, on: true)
                }

                Menu {
                    ForEach(Payer.allCases) { p in
                        Button { payer = p; Haptic.tap() } label: { Text(p.rawValue) }
                    }
                } label: {
                    chip(payer.rawValue, symbol: "person.fill",
                         tint: payer.tint, on: payer != .us)
                }

                Button {
                    withAnimation(.snappy) { showDetails.toggle() }
                    Haptic.tap()
                } label: {
                    chip(dateLabel, symbol: "calendar", tint: Ink.ocean,
                         on: !Calendar.current.isDateInToday(date))
                }

                Button {
                    withAnimation(.snappy) { showDetails.toggle() }
                } label: {
                    chip(note.isEmpty ? "Add note" : note, symbol: "text.alignleft",
                         tint: Ink.brass, on: !note.isEmpty)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var dateLabel: String {
        Calendar.current.isDateInToday(date) ? "Today"
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func chip(_ text: String, symbol: String, tint: Color, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(Face.body(13, weight: on ? .medium : .regular)).lineLimit(1)
        }
        .foregroundStyle(on ? tint : Ink.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(on ? tint.opacity(0.12) : Ink.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(on ? tint.opacity(0.35) : Ink.rule))
    }

    private var detailFields: some View {
        VStack(spacing: 10) {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .font(Face.body(14))
            TextField("Note — names here are searchable", text: $note, axis: .vertical)
                .font(Face.body(14))
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.rule))
        }
        .padding(.horizontal, 20).padding(.top, 12)
    }

    // MARK: keypad

    private let keys: [[String]] = [["1","2","3"], ["4","5","6"], ["7","8","9"], ["00","0","⌫"]]

    private var keypad: some View {
        VStack(spacing: 9) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 9) {
                    ForEach(row, id: \.self) { k in
                        Button { press(k) } label: {
                            Group {
                                if k == "⌫" {
                                    Image(systemName: "delete.left").font(.system(size: 19))
                                } else {
                                    Text(k).font(Face.figure(25, weight: .medium))
                                }
                            }
                            .foregroundStyle(Ink.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.rule))
                        }
                        .buttonStyle(KeyStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func press(_ key: String) {
        Haptic.tap()
        switch key {
        case "⌫": if !digits.isEmpty { digits.removeLast() }
        case "00": if !digits.isEmpty && digits.count <= 6 { digits += "00" }
        default: if digits.count <= 7 { digits = (digits + key).trimmingLeadingZeros }
        }
    }

    private var saveBar: some View {
      VStack(spacing: 8) {
        if let duplicateWarning {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(duplicateWarning).font(Face.body(12))
                Spacer()
                Button("Dismiss") { self.duplicateWarning = nil }
                    .font(Face.body(12, weight: .medium))
            }
            .foregroundStyle(Ink.brass)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(Ink.brass.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            .padding(.horizontal, 20)
        }
        Button { save() } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text(canSave ? "Save \(amount.abs.formatted())" : "Enter an amount")
            }
            .font(Face.body(17, weight: .semibold))
            .foregroundStyle(canSave ? Ink.onPrimary : Color.white)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(canSave ? Ink.primary : Ink.faint,
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(!canSave)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
      }
    }

    // MARK: the one success moment

    private var successStamp: some View {
        ZStack {
            Color.black.opacity(0.06).ignoresSafeArea()
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Ink.mint.opacity(0.15)).frame(width: 108, height: 108)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(Ink.mint)
                }
                .scaleEffect(stampScale)
                Text("Logged").font(Face.body(15, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text(amount.abs.formatted() + " · " + merchant)
                    .font(Face.figure(13)).foregroundStyle(Ink.secondary)
            }
        }
        .transition(.opacity)
    }

    // MARK: logic

    private func learn(_ text: String) {
        guard text.count >= 3,
              let last = history.first(where: {
                  ($0.merchant ?? "").lowercased() == text.lowercased() }) else { return }
        withAnimation(.snappy) { category = Category.lenient(last.category ?? "") }
        if let c = last.card { selectedCard = c }
    }

    private func save() {
        guard canSave else { return }
        let outcome = DuplicateGuard.create(
            date: date, amount: amount, merchant: merchant,
            category: category, card: selectedCard, payer: payer,
            notes: note, source: "quickAdd", context: ctx)

        switch outcome {
        case .blocked(let match):
            // Already recorded. Say so rather than writing a second copy.
            duplicateWarning = "Already logged — \(match.reason)"
            Haptic.warn()
            return
        case .flagged(_, let match):
            duplicateWarning = "Logged, but check it: \(match.reason)"
            Haptic.warn()
        case .created:
            break
        }

        Haptic.success()
        stampScale = 0.4
        withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
            saved = true; stampScale = 1
        }
        Task {
            try? await Task.sleep(for: .seconds(0.85))
            withAnimation(.easeOut(duration: 0.22)) { saved = false }
            digits = ""; merchant = ""; note = ""; isRefund = false
            showDetails = false; duplicateWarning = nil
        }
    }
}

private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private extension String {
    var trimmingLeadingZeros: String {
        let s = drop { $0 == "0" }
        return s.isEmpty ? "" : String(s)
    }
}
