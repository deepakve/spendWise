import SwiftUI
import PhotosUI
import CoreData

// Scan a receipt, then check what it read.
//
// It never saves silently. OCR on a crumpled receipt in a car park is wrong
// often enough that a silent save would quietly poison the ledger, and a wrong
// number you never saw is worse than no number. So it fills the add screen and
// marks every field it's unsure about.

struct ScanReceiptView: View {
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "sortIndex", ascending: true)])
    private var cards: FetchedResults<CDCard>

    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var scan: ScannedReceipt?
    @State private var scanning = false
    @State private var showAdd = false
    @State private var manualTotal = ""
    @State private var manualMerchant = ""
    @State private var manualCard: CDCard?
    @State private var manualDate = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.rule))
                    }

                    if scanning {
                        HStack(spacing: 9) {
                            ProgressView()
                            Text("Reading the receipt…").font(Face.body(14))
                        }
                        .padding(.vertical, 24)
                    }

                    if let scan { results(scan) }

                    PhotosPicker(selection: $item, matching: .images) {
                        Label(image == nil ? "Choose a receipt photo" : "Try another photo",
                              systemImage: "doc.viewfinder")
                            .font(Face.body(16, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.rule))
                    }
                }
                .padding(20)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("Scan receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onChange(of: item) { _, new in Task { await run(new) } }
        }
    }

    private func results(_ s: ScannedReceipt) -> some View {
        VStack(spacing: 12) {
            field("Total", s.total?.formatted() ?? "not found",
                  sure: !s.lowConfidence.contains(.total))
            field("Date", s.date?.formatted(date: .abbreviated, time: .omitted) ?? "not found",
                  sure: !s.lowConfidence.contains(.date))
            field("Merchant", s.merchant ?? "not found",
                  sure: !s.lowConfidence.contains(.merchant))

            let matched = ReceiptScanner.matchCard(last4: s.cardLast4, among: Array(cards))
            field("Card",
                  matched?.name ?? (s.cardLast4.map { "•••• \($0) — no match" } ?? "not found"),
                  sure: matched != nil)

            if matched == nil && s.cardLast4 != nil {
                Text("The receipt shows •••• \(s.cardLast4!), but no card in your wallet has those last four. Add them under Cards → Edit card and future scans will match automatically.")
                    .font(Face.body(11)).foregroundStyle(Ink.secondary)
            }

            if !s.lowConfidence.isEmpty {
                Perforation().padding(.vertical, 4)
                Text("I need you to fill these in")
                    .font(Face.body(13, weight: .semibold)).foregroundStyle(Ink.brass)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if s.lowConfidence.contains(.total) {
                    question("How much was the total?") {
                        HStack {
                            Text("$").foregroundStyle(Ink.secondary)
                            TextField("0.00", text: $manualTotal)
                                .keyboardType(.decimalPad).font(Face.figure(17))
                        }
                    }
                }
                if s.lowConfidence.contains(.merchant) {
                    question("Where was this?") {
                        TextField("Merchant", text: $manualMerchant)
                            .font(Face.body(15))
                    }
                }
                if matched == nil {
                    question("Which card did you use?") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(cards.filter { !$0.isClosed }, id: \.objectID) { c in
                                    Button {
                                        manualCard = c; Haptic.tap()
                                    } label: {
                                        Text(c.name ?? "")
                                            .font(Face.body(12,
                                                weight: manualCard?.objectID == c.objectID ? .semibold : .regular))
                                            .foregroundStyle(manualCard?.objectID == c.objectID
                                                             ? .white : Ink.primary)
                                            .padding(.horizontal, 11).padding(.vertical, 7)
                                            .background(manualCard?.objectID == c.objectID
                                                        ? Ink.primary : Color.white, in: Capsule())
                                            .overlay(Capsule().strokeBorder(Ink.rule))
                                    }
                                }
                            }
                        }
                    }
                }
                if s.lowConfidence.contains(.date) {
                    question("What date?") {
                        DatePicker("", selection: $manualDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }

            Button {
                showAdd = true
            } label: {
                Label(readyToUse(s) ? "Use this" : "Answer the questions above",
                      systemImage: readyToUse(s) ? "arrow.right.circle.fill" : "questionmark.circle")
                    .font(Face.body(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(readyToUse(s) ? Ink.primary : Ink.faint,
                                in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!readyToUse(s))
            .padding(.top, 4)
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.rule))
        .sheet(isPresented: $showAdd) {
            QuickAddView(defaultDate: scan?.date ?? manualDate,
                         defaultCard: ReceiptScanner.matchCard(last4: scan?.cardLast4,
                                                               among: Array(cards)) ?? manualCard,
                         prefillAmount: scan?.total ?? Money.parse(manualTotal),
                         prefillMerchant: scan?.merchant ?? (manualMerchant.isEmpty ? nil : manualMerchant))
        }
    }

    /// Every gap becomes an explicit question rather than a blank the app
    /// quietly treats as done. Nothing proceeds until they're answered.
    private func question<C: View>(_ prompt: String,
                                   @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt).font(Face.body(13, weight: .medium)).foregroundStyle(Ink.primary)
            control()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Ink.paper, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.brass.opacity(0.4)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readyToUse(_ s: ScannedReceipt) -> Bool {
        if s.lowConfidence.contains(.total) && Money.parse(manualTotal) == nil { return false }
        if s.lowConfidence.contains(.merchant) && manualMerchant.isEmpty { return false }
        if ReceiptScanner.matchCard(last4: s.cardLast4, among: Array(cards)) == nil
            && manualCard == nil { return false }
        return true
    }

    private func field(_ label: String, _ value: String, sure: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                FieldLabel(text: label)
                Text(value).font(Face.body(15, weight: .medium))
                    .foregroundStyle(sure ? Ink.primary : Ink.brass)
            }
            Spacer()
            Image(systemName: sure ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .foregroundStyle(sure ? Ink.mint : Ink.brass)
        }
    }

    private func run(_ new: PhotosPickerItem?) async {
        guard let new,
              let data = try? await new.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }
        image = img; scanning = true; scan = nil
        let result = await ReceiptScanner.scan(img)
        scan = result; scanning = false
        Haptic.success()
    }
}
