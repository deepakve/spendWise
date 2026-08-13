import SwiftUI
import CoreData
import CloudKit

// MARK: - Cards

struct CardsView: View {
    @Environment(\.managedObjectContext) private var ctx
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true)])
    private var cards: FetchedResults<CDCard>
    @FetchRequest(sortDescriptors: [])
    private var expenses: FetchedResults<CDExpense>

    @State private var showAdd = false
    private let dates = StatementDates()
    private let analytics = Analytics()

    var body: some View {
        NavigationStack {
            List {
                ForEach(cards.filter { !$0.isClosed }, id: \.objectID) { card in
                    NavigationLink { CardDetailView(card: card) } label: { row(card) }
                }
                Section {
                    Button { showAdd = true } label: {
                        Label("Add a card", systemImage: "plus")
                    }
                }
                let closed = cards.filter { $0.isClosed }
                if !closed.isEmpty {
                    Section("Closed") {
                        ForEach(closed, id: \.objectID) { card in
                            NavigationLink { CardDetailView(card: card) } label: {
                                Text(card.name ?? "—").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cards")
            .sheet(isPresented: $showAdd) { CardEditView(card: nil) }
        }
    }

    private func row(_ card: CDCard) -> some View {
        let key = CycleCalendar.key(for: .now)
        let spend = Money(expenses
            .filter { $0.card == card && $0.cycleKey == key && !$0.needsReview }
            .reduce(0) { $0 + Int($1.amountCents) })
        return HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: card.colorHex ?? "#8E8E93"))
                .frame(width: 6, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name ?? "—")
                HStack(spacing: 6) {
                    if let l = card.last4, !l.isEmpty { Text("•••• \(l)") }
                    if card.aprBasisPoints > 0 {
                        Text(String(format: "%.2f%%", Double(card.aprBasisPoints)/100))
                    }
                    if let d = dates.daysUntilDue(dueDay: Int(card.dueDay)) {
                        Text("due in \(d)d").foregroundStyle(d <= 3 ? .red : .secondary)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(spend.formatted(cents: false)).monospacedDigit()
        }
    }
}

struct VaultEditView: View {
    @Environment(\.dismiss) private var dismiss
    let ref: String
    var existing: CardSecret?
    var onSave: (CardSecret) -> Void

    @State private var s = CardSecret()
    @State private var error: String?
    @State private var showCVV = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("Card number", text: $s.number).keyboardType(.numberPad)
                    TextField("Expiry MM/YY", text: $s.expiry)
                    TextField("PIN", text: $s.pin).keyboardType(.numberPad)
                }
                Section {
                    Toggle("Also store CVV", isOn: $showCVV)
                    if showCVV {
                        TextField("CVV", text: $s.cvv).keyboardType(.numberPad)
                    }
                } footer: {
                    Text("Number, expiry and CVV together are everything needed for an online purchase. Card networks forbid even merchants from storing CVV for that reason. Storing the number alone is much lower risk — it's on every receipt and can be reissued. Your device, your call.")
                }
                Section("Account") {
                    TextField("Login email", text: $s.loginHint)
                    TextField("Support phone", text: $s.supportPhone)
                    TextField("Notes", text: $s.freeform, axis: .vertical)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .navigationTitle("Secure details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            if !showCVV { s.cvv = "" }
                            try CardVault.save(s, ref: ref)
                            onSave(s)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .onAppear {
                if let existing { s = existing; showCVV = !existing.cvv.isEmpty }
            }
        }
    }
}

// MARK: - Add / edit card terms

struct CardEditView: View {
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    var card: CDCard?

    @State private var name = ""
    @State private var issuer = ""
    @State private var last4 = ""
    @State private var accountLast4 = ""
    @State private var otherLast4 = ""
    @State private var apr = ""
    @State private var limit = ""
    @State private var statementDay = 1
    @State private var dueDay = 1
    @State private var colorHex = "#0A84FF"
    @State private var isCash = false

    private let palette = ["#0A84FF","#FF9F0A","#30D158","#BF5AF2","#FF375F",
                           "#64D2FF","#FFD60A","#AC8E68","#5E5CE6","#8E8E93"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name — e.g. Chase Sapphire", text: $name)
                TextField("Issuer", text: $issuer)
                TextField("Card number, last 4", text: $last4).keyboardType(.numberPad)
                TextField("Bank account, last 4", text: $accountLast4).keyboardType(.numberPad)
                TextField("Any other last 4, comma separated", text: $otherLast4)
                    .keyboardType(.numbersAndPunctuation)
                HStack {
                    Text("APR %")
                    Spacer()
                    TextField("0.00", text: $apr).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
                HStack {
                    Text("Credit limit")
                    Spacer()
                    TextField("0", text: $limit).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).frame(width: 110)
                }
                Picker("Statement closes on", selection: $statementDay) {
                    ForEach(1...31, id: \.self) { Text("day \($0)").tag($0) }
                }
                Picker("Payment due on", selection: $dueDay) {
                    ForEach(1...31, id: \.self) { Text("day \($0)").tag($0) }
                }
                Toggle("Cash or debit (no statement)", isOn: $isCash)

                Section("Colour") {
                    HStack {
                        ForEach(palette, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.primary,
                                    lineWidth: hex == colorHex ? 2 : 0))
                                .onTapGesture { colorHex = hex }
                        }
                    }
                }
            }
            .navigationTitle(card == nil ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(name.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let c = card else { return }
        name = c.name ?? ""; issuer = c.issuer ?? ""; last4 = c.last4 ?? ""
        accountLast4 = c.accountLast4 ?? ""; otherLast4 = c.otherLast4 ?? ""
        apr = c.aprBasisPoints > 0 ? String(format: "%.2f", Double(c.aprBasisPoints)/100) : ""
        limit = c.creditLimitCents > 0 ? String(Int(c.creditLimitCents)/100) : ""
        statementDay = c.statementDay > 0 ? Int(c.statementDay) : 1
        dueDay = c.dueDay > 0 ? Int(c.dueDay) : 1
        colorHex = c.colorHex ?? "#0A84FF"; isCash = c.isCash
    }

    private func save() {
        let c = card ?? CDCard(context: ctx)
        if card == nil { c.id = UUID(); c.sortIndex = 99 }
        c.name = name; c.issuer = issuer; c.last4 = last4
        c.accountLast4 = accountLast4; c.otherLast4 = otherLast4
        c.aprBasisPoints = Int32((Double(apr) ?? 0) * 100)
        c.creditLimitCents = Int64((Double(limit) ?? 0) * 100)
        c.statementDay = Int16(statementDay); c.dueDay = Int16(dueDay)
        c.colorHex = colorHex; c.isCash = isCash
        if c.secretRef?.isEmpty != false { c.secretRef = "card.\(c.id?.uuidString ?? UUID().uuidString)" }
        Persistence.shared.save()
        dismiss()
    }
}

// MARK: - Settings, sharing, import/export

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var ctx
    @EnvironmentObject private var store: Persistence
    @FetchRequest(sortDescriptors: []) private var expenses: FetchedResults<CDExpense>

    @State private var share: CKShare?
    @State private var showShare = false
    @State private var showImporter = false
    @State private var message: String?
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await prepareShare() }
                    } label: {
                        Label("Share this ledger with your wife", systemImage: "person.2.fill")
                    }
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("She installs the app, taps your invite, and reads and writes the same ledger from her own Apple ID. No shared password. You can revoke access at any time.")
                }

                Section("iCloud") {
                    Label(store.syncError == nil ? "Syncing" : "Sync problem",
                          systemImage: store.syncError == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                    if let e = store.syncError {
                        Text(e).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Data") {
                    Button("Import CSV") { showImporter = true }
                    Button("Export CSV") { export() }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }

                Section {
                    NavigationLink { RecurringInboxView() } label: {
                        Label("Recurring bills due", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink { RecurringSettingsView() } label: {
                        Label("Manage recurring", systemImage: "repeat")
                    }
                    NavigationLink { GiftCardsView() } label: {
                        Label("Gift cards", systemImage: "giftcard")
                    }
                }
                Section {
                    NavigationLink { PrivacyView() } label: {
                        Label("Privacy", systemImage: "checkmark.shield")
                    }
                    NavigationLink { DuplicatesView() } label: {
                        Label("Possible duplicates", systemImage: "doc.on.doc")
                    }
                    NavigationLink("Needs review") { ReviewQueueView() }
                }

                Section {
                    Text("iCloud syncs, it doesn't back up. A deletion propagates everywhere. Export a CSV to Files every month or two.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showShare) {
                if let share {
                    CloudSharingView(share: share,
                                     container: CKContainer(identifier: Persistence.containerID))
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText]) { result in
                guard case .success(let url) = result else { return }
                importCSV(url)
            }
        }
    }

    private func prepareShare() async {
        if let existing = store.existingShare() {
            share = existing; showShare = true; return
        }
        // Zone-wide share: NSPersistentCloudKitContainer shares the whole zone
        // that the given object lives in, so any one object from the private
        // store anchors a share covering the entire ledger — one invite grants
        // everything, rather than asking her to accept a share per record.
        guard let store0 = store.privateStore else {
            message = "Sync isn't ready yet. Try again in a moment."
            return
        }
        let cardReq = NSFetchRequest<CDCard>(entityName: "CDCard")
        cardReq.affectedStores = [store0]
        cardReq.fetchLimit = 1
        guard let anchor = try? ctx.fetch(cardReq).first else {
            message = "Add at least one card before sharing."
            return
        }
        do {
            let container = store.container
            let (_, newShare, _) = try await container.share([anchor], to: nil)
            newShare[CKShare.SystemFieldKey.title] = "Our Ledger" as CKRecordValue
            share = newShare
            showShare = true
        } catch {
            message = "Could not start sharing: \(error.localizedDescription)"
        }
    }

    private func importCSV(_ url: URL) {
        do {
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = try CSVImporter(context: ctx).run(text)
            message = "Imported \(result.imported), flagged \(result.flagged), skipped \(result.skipped) duplicates."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    private func export() {
        var out = "Card,Store,Date,Amount,Category,Notes,Recurring,Who,Cycle\n"
        let df = DateFormatter(); df.dateFormat = "MMM d, yyyy"
        for e in expenses.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            let fields = [e.card?.name ?? "", e.merchant ?? "",
                          df.string(from: e.date ?? .now),
                          String(format: "%.2f", Double(e.amountCents)/100),
                          e.category ?? "", e.notes ?? "",
                          e.isRecurring ? "Yes" : "", e.payer ?? "Us", e.cycleKey ?? ""]
            out += fields.map { f in
                f.contains(",") || f.contains("\"")
                    ? "\"\(f.replacingOccurrences(of: "\"", with: "\"\""))\"" : f
            }.joined(separator: ",") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ledger.csv")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
        message = "Exported to Files › Ledger.csv"
    }
}

struct ReviewQueueView: View {
    @Environment(\.managedObjectContext) private var ctx
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)],
                  predicate: NSPredicate(format: "needsReview == YES"))
    private var flagged: FetchedResults<CDExpense>

    var body: some View {
        List {
            ForEach(flagged, id: \.objectID) { e in
                NavigationLink { EditExpenseView(expense: e) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(e.merchant ?? "—").font(.headline)
                            Spacer()
                            Text(Money(Int(e.amountCents)).formatted()).monospacedDigit()
                        }
                        Text(e.notes ?? "").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Needs review")
        .overlay {
            if flagged.isEmpty {
                ContentUnavailableView("All clear", systemImage: "checkmark.seal")
            }
        }
    }
}
