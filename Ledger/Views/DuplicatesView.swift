import SwiftUI
import CoreData

// Cleanup screen for anything the guard flagged rather than blocked.
//
// Nothing here is deleted automatically. Two Costco runs in a week are a real
// pattern in this ledger, and a pre-auth/settled pair needs the *larger* one
// kept, not the first. Both calls need a human.

struct DuplicatesView: View {
    @Environment(\.managedObjectContext) private var ctx
    @State private var clusters: [[CDExpense]] = []

    var body: some View {
        List {
            if clusters.isEmpty {
                ContentUnavailableView("No duplicates",
                                       systemImage: "checkmark.seal",
                                       description: Text("Every entry looks unique."))
            }
            ForEach(Array(clusters.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group, id: \.objectID) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.merchant ?? "—").font(Face.body(15, weight: .medium))
                                HStack(spacing: 5) {
                                    Text(e.date?.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                                    if let c = e.card?.name { Text("· \(c)") }
                                    Text("· \(sourceLabel(e.source))")
                                }
                                .font(.system(size: 10)).foregroundStyle(Ink.faint)
                            }
                            Spacer()
                            Text(Money(Int(e.amountCents)).formatted())
                                .font(Face.figure(14, weight: .medium))
                            Button {
                                ctx.delete(e); Persistence.shared.save(); reload()
                            } label: {
                                Image(systemName: "trash").foregroundStyle(Ink.coral)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                    Button("Keep both — not a duplicate") {
                        // Nudge the fingerprint so the pair stops clustering.
                        for (i, e) in group.enumerated() where i > 0 {
                            e.dupeHash = (e.dupeHash ?? "") + "-kept\(i)"
                            e.needsReview = false
                        }
                        Persistence.shared.save(); reload()
                    }
                    .font(Face.body(13))
                } header: {
                    Text("\(group.count) matching entries")
                }
            }
        }
        .navigationTitle("Possible duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rescan") { DuplicateGuard.reindex(context: ctx); reload() }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() { clusters = DuplicateGuard.clusters(context: ctx) }

    private func sourceLabel(_ s: String?) -> String {
        switch s {
        case "bankAlert": "from bank alert"
        case "recurringRule": "autopay"
        case "csvImport": "imported"
        case "shortcut": "Siri"
        case "quickAdd": "typed"
        default: "manual"
        }
    }
}
