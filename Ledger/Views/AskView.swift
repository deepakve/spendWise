import SwiftUI
import CoreData

// The "ask" tab.
//
// Chat framing, but every answer states what it understood before the number.
// That's the difference between a tool you can trust and one you can't: if it
// read "Amex" as "Amex Blue" when you meant Gold, you see that immediately
// rather than acting on a wrong figure.

struct AskView: View {
    @Environment(\.managedObjectContext) private var ctx
    @State private var input = ""
    @State private var turns: [Turn] = []
    @FocusState private var focused: Bool

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let result: QueryResult
    }

    private let starters = [
        "Spend from Aug 5 to Aug 15 on Amex",
        "How much on eat out last month",
        "What did I spend on Bindu",
        "Biggest purchases this cycle",
        "Groceries in June"
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            if turns.isEmpty { empty } else {
                                ForEach(turns) { turn in
                                    TurnCard(turn: turn) { ask($0) }
                                        .id(turn.id)
                                }
                            }
                            Color.clear.frame(height: 90)
                        }
                        .padding(20)
                    }
                    .onChange(of: turns.count) { _, _ in
                        if let last = turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                        }
                    }
                }
                composer
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("Ask")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask about your money")
                .font(Face.amount(28))
                .foregroundStyle(Ink.primary)
            Text("Plain questions. Everything is answered on this device — nothing is sent anywhere.")
                .font(Face.body(14))
                .foregroundStyle(Ink.secondary)

            VStack(spacing: 8) {
                ForEach(starters, id: \.self) { s in
                    Button { ask(s) } label: {
                        HStack {
                            Text(s).font(Face.body(14)).foregroundStyle(Ink.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11)).foregroundStyle(Ink.faint)
                        }
                        .padding(.horizontal, 15).padding(.vertical, 13)
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.rule))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 30)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask anything…", text: $input)
                .font(Face.body(15))
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { ask(input) }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(Ink.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Ink.rule))

            Button { ask(input) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(input.isEmpty ? Color.white : Ink.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(input.isEmpty ? Ink.faint : Ink.primary, in: Circle())
            }
            .disabled(input.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Haptic.tap()
        let result = NaturalQuery(context: ctx).answer(q)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            turns.append(Turn(question: q, result: result))
        }
        input = ""
        focused = false
    }
}

private struct TurnCard: View {
    let turn: AskView.Turn
    var onFollowUp: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Text(turn.question)
                    .font(Face.body(14, weight: .medium))
                    .foregroundStyle(Ink.onPrimary)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(Ink.primary, in: RoundedRectangle(cornerRadius: 15))
            }

            VStack(alignment: .leading, spacing: 14) {
                // What it understood, before the number.
                HStack(spacing: 6) {
                    Image(systemName: turn.result.understood
                          ? "checkmark.circle.fill" : "questionmark.circle")
                        .font(.system(size: 11))
                    Text(turn.result.interpretation)
                        .font(.system(size: 11, weight: .medium)).tracking(0.4)
                }
                .foregroundStyle(turn.result.understood ? Ink.mint : Ink.brass)

                Text(turn.result.total.formatted())
                    .font(Face.amount(38))
                    .foregroundStyle(Ink.primary)

                Text(turn.result.headline)
                    .font(Face.body(13))
                    .foregroundStyle(Ink.secondary)

                if !turn.result.breakdown.isEmpty {
                    Perforation()
                    VStack(spacing: 9) {
                        ForEach(turn.result.breakdown, id: \.label) { item in
                            LedgerRow(label: item.label) {
                                Text(item.amount.formatted(cents: false))
                                    .font(Face.figure(14, weight: .medium))
                                    .foregroundStyle(Ink.primary)
                            }
                        }
                    }
                }

                if !turn.result.rows.isEmpty {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Text(expanded ? "Hide transactions"
                                          : "Show \(turn.result.rows.count) transactions")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                        }
                        .font(Face.body(13, weight: .medium))
                        .foregroundStyle(Ink.ocean)
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        VStack(spacing: 0) {
                            ForEach(turn.result.rows, id: \.objectID) { e in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.merchant ?? "—").font(Face.body(13))
                                        Text([e.date?.formatted(.dateTime.month(.abbreviated).day()),
                                              e.card?.name].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 10)).foregroundStyle(Ink.faint)
                                    }
                                    Spacer()
                                    Text(Money(Int(e.amountCents)).formatted())
                                        .font(Face.figure(13))
                                }
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(18)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.rule))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(turn.result.followUps, id: \.self) { f in
                        Button { onFollowUp(f) } label: {
                            Text(f)
                                .font(Face.body(12))
                                .foregroundStyle(Ink.secondary)
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(Capsule().strokeBorder(Ink.rule))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
