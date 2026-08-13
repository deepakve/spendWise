import SwiftUI
import PhotosUI

// The signature element: a card that looks and behaves like a card.
//
// Everything in this file exists to serve one moment — you're at a checkout,
// you need the number, and you have about four seconds. So: the card is
// recognisable by colour before you read it, the number is one tap from the
// clipboard, and the CVV is hidden until you deliberately flip the card over,
// the way you'd physically turn a real one.

struct CardFace: View {
    let name: String
    let issuer: String
    let skin: CardSkin
    var numberDisplay: String            // may be partial — see CardDetailView
    var expiry: String
    var photo: UIImage?
    var revealed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [skin.top, skin.bottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            if let photo {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.clear)
                    .overlay(
                        Image(uiImage: photo).resizable().scaledToFill()
                            .opacity(revealed ? 1 : 0.14)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            // The metallic sheen. One diagonal highlight, low opacity — enough
            // to read as laminate, not enough to fight the content.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .white.opacity(0.07)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .blendMode(.plusLighter)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(Face.body(17, weight: .semibold))
                        if !issuer.isEmpty {
                            Text(issuer.uppercased())
                                .font(.system(size: 9, weight: .semibold)).tracking(1.4)
                                .opacity(0.7)
                        }
                    }
                    Spacer()
                    chip
                }
                Spacer()
                Text(numberDisplay)
                    .font(Face.figure(19, weight: .medium))
                    .tracking(2)
                    .contentTransition(.numericText())
                if !expiry.isEmpty {
                    HStack(spacing: 5) {
                        Text("EXP").font(.system(size: 8, weight: .semibold)).tracking(1.2).opacity(0.6)
                        Text(expiry).font(Face.figure(12, weight: .medium))
                    }
                    .padding(.top, 5)
                }
            }
            .foregroundStyle(skin.ink)
            .padding(20)
        }
        .frame(height: 210)
        .shadow(color: skin.bottom.opacity(0.35), radius: 18, y: 10)
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LinearGradient(colors: [Color(hex: "#E8D9A0"), Color(hex: "#B99B4F")],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 40, height: 30)
            .overlay(
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().frame(height: 1).foregroundStyle(.black.opacity(0.22))
                    }
                }
                .padding(.horizontal, 6)
            )
    }
}

/// The reverse: magnetic stripe and the signature panel where the CVV lives.
struct CardBack: View {
    let skin: CardSkin
    let cvv: String
    var cvvVisible: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [skin.top, skin.bottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 0) {
                Rectangle().fill(.black.opacity(0.82)).frame(height: 44).padding(.top, 22)
                Spacer()
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: "#EFEDE7"))
                        .frame(height: 34)
                        .overlay(alignment: .trailing) {
                            Text(cvvVisible ? cvv : String(repeating: "•", count: max(cvv.count, 3)))
                                .font(Face.figure(15, weight: .semibold))
                                .foregroundStyle(Ink.primary)
                                .padding(.trailing, 12)
                        }
                    FieldLabel(text: "CVV")
                        .foregroundStyle(skin.ink.opacity(0.75))
                }
                .padding(.horizontal, 20)
                Spacer().frame(height: 34)
            }
        }
        .frame(height: 210)
        .shadow(color: skin.bottom.opacity(0.35), radius: 18, y: 10)
    }
}

// MARK: - Detail screen

struct CardDetailView: View {
    @Environment(\.managedObjectContext) private var ctx
    @ObservedObject var card: CDCard

    @State private var secret: CardSecret?
    @State private var photo: UIImage?
    @State private var flipped = false
    @State private var cvvVisible = false
    @State private var numberVisible = false
    @State private var toast: String?
    @State private var vaultError: String?
    @State private var showVaultEdit = false
    @State private var showEdit = false
    @State private var showBonus = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var unlocking = false

    private let dates = StatementDates()

    private var ref: String {
        card.secretRef?.isEmpty == false ? card.secretRef! : "card.\(card.id?.uuidString ?? "")"
    }
    private var skin: CardSkin {
        CardSkin.forIssuer(card.issuer ?? "", name: card.name ?? "",
                           fallbackHex: card.colorHex ?? "#8E8E93")
    }

    var body: some View {
      CaptureGuard {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 26) {
                    cardStage
                    if secret != nil { fieldsPanel } else { lockedPanel }
                    termsPanel
                    actionsPanel
                }
                .padding(20)
            }
            if let toast {
                Toast(text: toast, symbol: "doc.on.doc.fill").padding(.top, 6)
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(card.name ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showVaultEdit) {
            VaultEditView(ref: ref, existing: secret) { saved in
                secret = saved
                card.secretRef = ref
                Persistence.shared.save()
            }
        }
        .sheet(isPresented: $showEdit) { CardEditView(card: card) }
        .sheet(isPresented: $showBonus) { BonusEditView(card: card) }
        .onChange(of: pickerItem) { _, item in Task { await savePhoto(item) } }
        .task { photo = try? SecurePhoto.load(ref: ref) }
      }
    }

    // MARK: card stage — the flip

    private var cardStage: some View {
        ZStack {
            CardFace(name: card.name ?? "—",
                     issuer: card.issuer ?? "",
                     skin: skin,
                     numberDisplay: faceNumber,
                     expiry: secret?.expiry ?? "",
                     photo: photo,
                     revealed: numberVisible)
                .opacity(flipped ? 0 : 1)
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (0, 1, 0))

            CardBack(skin: skin, cvv: secret?.cvv ?? "", cvvVisible: cvvVisible)
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(flipped ? 0 : -180), axis: (0, 1, 0))
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: flipped)
        .onTapGesture {
            guard secret != nil else { Task { await unlock() }; return }
            Haptic.tap()
            flipped.toggle()
            if !flipped { cvvVisible = false }
        }
        .overlay(alignment: .bottom) {
            if secret != nil {
                Text(flipped ? "Tap to turn back" : "Tap the card to see the CVV")
                    .font(Face.body(11))
                    .foregroundStyle(Ink.faint)
                    .offset(y: 22)
            }
        }
        .padding(.bottom, 20)
    }

    /// What prints on the card face. Masked until deliberately revealed.
    private var faceNumber: String {
        guard let n = secret?.number, !n.isEmpty else { return "•••• •••• •••• ••••" }
        if numberVisible { return grouped(n) }
        let digits = n.filter(\.isNumber)
        return "•••• •••• •••• " + String(digits.suffix(4))
    }

    private func grouped(_ s: String) -> String {
        let d = s.filter(\.isNumber)
        return stride(from: 0, to: d.count, by: 4).map {
            String(d.dropFirst($0).prefix(4))
        }.joined(separator: " ")
    }

    // MARK: locked state

    private var lockedPanel: some View {
        VStack(spacing: 14) {
            Button {
                Task { await unlock() }
            } label: {
                Label(CardVault.exists(ref: ref) ? "Unlock card details" : "Add card details",
                      systemImage: "faceid")
                    .font(Face.body(16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.primary)
            .disabled(unlocking)

            if let vaultError {
                Text(vaultError).font(Face.body(12)).foregroundStyle(Ink.coral)
            }
        }
    }

    // MARK: revealed fields, each copyable

    private var fieldsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                FieldLabel(text: "Card details")
                Spacer()
                Button("Hide") {
                    withAnimation {
                        secret = nil; flipped = false
                        cvvVisible = false; numberVisible = false
                    }
                }
                .font(Face.body(13, weight: .medium))
                .foregroundStyle(Ink.ocean)
            }
            .padding(.bottom, 12)

            copyRow(label: "Number",
                    value: secret?.number ?? "",
                    display: numberVisible ? grouped(secret?.number ?? "") : masked(secret?.number ?? ""),
                    toggle: { numberVisible.toggle() },
                    isVisible: numberVisible)

            if let e = secret?.expiry, !e.isEmpty {
                Divider().padding(.vertical, 2)
                copyRow(label: "Expires", value: e, display: e, toggle: nil, isVisible: true)
            }

            if let c = secret?.cvv, !c.isEmpty {
                Divider().padding(.vertical, 2)
                copyRow(label: "CVV",
                        value: c,
                        display: cvvVisible ? c : String(repeating: "•", count: c.count),
                        toggle: { cvvVisible.toggle(); if cvvVisible { flipped = true } },
                        isVisible: cvvVisible)
            }

            if let p = secret?.pin, !p.isEmpty {
                Divider().padding(.vertical, 2)
                copyRow(label: "PIN", value: p,
                        display: cvvVisible ? p : String(repeating: "•", count: p.count),
                        toggle: { cvvVisible.toggle() }, isVisible: cvvVisible)
            }

            if let l = secret?.loginHint, !l.isEmpty {
                Divider().padding(.vertical, 2)
                copyRow(label: "Login", value: l, display: l, toggle: nil, isVisible: true)
            }
            if let s = secret?.supportPhone, !s.isEmpty {
                Divider().padding(.vertical, 2)
                copyRow(label: "Support", value: s, display: s, toggle: nil, isVisible: true)
            }
            if let f = secret?.freeform, !f.isEmpty {
                Divider().padding(.vertical, 6)
                Text(f).font(Face.body(13)).foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.rule))
    }

    private func masked(_ s: String) -> String {
        let d = s.filter(\.isNumber)
        return d.count >= 4 ? "•••• " + String(d.suffix(4)) : "••••"
    }

    private func copyRow(label: String, value: String, display: String,
                         toggle: (() -> Void)?, isVisible: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                FieldLabel(text: label)
                Text(display)
                    .font(Face.figure(16, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
            }
            Spacer()
            if let toggle {
                Button {
                    Haptic.tap()
                    withAnimation(.easeInOut(duration: 0.18)) { toggle() }
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 38, height: 38)
                        .background(Ink.paper, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isVisible ? "Hide \(label)" : "Show \(label)")
            }
            Button {
                SecureClipboard.copySensitive(value.filter { !$0.isWhitespace })
                Haptic.success()
                show("\(label) copied · clears in 90s")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.onPrimary)
                    .frame(width: 38, height: 38)
                    .background(Ink.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(label)")
        }
        .padding(.vertical, 9)
    }

    // MARK: terms

    private var termsPanel: some View {
        VStack(spacing: 11) {
            HStack { FieldLabel(text: "Terms"); Spacer() }
            LedgerRow(label: "APR") {
                Text(card.aprBasisPoints > 0
                     ? String(format: "%.2f%%", Double(card.aprBasisPoints)/100) : "—")
                    .font(Face.figure(15, weight: .medium))
            }
            LedgerRow(label: "Credit limit") {
                Text(card.creditLimitCents > 0
                     ? Money(Int(card.creditLimitCents)).formatted(cents: false) : "—")
                    .font(Face.figure(15, weight: .medium))
            }
            LedgerRow(label: "Statement closes") {
                Text(card.statementDay > 0 ? "day \(card.statementDay)" : "—")
                    .font(Face.figure(15, weight: .medium))
            }
            LedgerRow(label: "Payment due") {
                Text(card.dueDay > 0 ? "day \(card.dueDay)" : "—")
                    .font(Face.figure(15, weight: .medium))
            }
            if let d = dates.nextDue(dueDay: Int(card.dueDay)),
               let days = dates.daysUntilDue(dueDay: Int(card.dueDay)) {
                LedgerRow(label: "Next due", emphasis: true) {
                    Text("\(d.formatted(.dateTime.month(.abbreviated).day())) · \(days)d")
                        .font(Face.figure(15, weight: .semibold))
                        .foregroundStyle(days <= 3 ? Ink.coral : Ink.primary)
                }
            }
            Perforation().padding(.top, 4)
        }
        .padding(18)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.rule))
    }

    private var actionsPanel: some View {
        VStack(spacing: 10) {
            NavigationLink {
                StatementView(card: card, cycleKey: CycleCalendar.key(for: .now))
            } label: {
                actionLabel("Statements & payments", "doc.text")
            }
            NavigationLink {
                LedgerView(presetFilter: card.name)
            } label: {
                actionLabel("All transactions", "list.bullet")
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                actionLabel(SecurePhoto.exists(ref: ref) ? "Replace card photo" : "Add card photo",
                            "camera")
            }
            if SecurePhoto.exists(ref: ref) {
                Button {
                    SecurePhoto.delete(ref: ref); photo = nil; show("Photo deleted")
                } label: { actionLabel("Delete card photo", "trash", tint: Ink.coral) }
            }
            Button { showVaultEdit = true } label: {
                actionLabel("Edit secure details", "lock.rotation")
            }
            Button { showBonus = true } label: {
                actionLabel(card.bonusTargetCents > 0 ? "Signup bonus" : "Track a signup bonus",
                            "target", tint: Ink.brass)
            }
            Button { showEdit = true } label: {
                actionLabel("Edit card terms", "slider.horizontal.3")
            }
        }
    }

    private func actionLabel(_ text: String, _ symbol: String,
                             tint: Color = Ink.primary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22)
            Text(text).font(Face.body(15))
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ink.faint)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Ink.rule))
    }

    // MARK: actions

    private func unlock() async {
        if !CardVault.exists(ref: ref) { showVaultEdit = true; return }
        unlocking = true
        defer { unlocking = false }
        do {
            let s = try await CardVault.load(ref: ref, reason: "Show \(card.name ?? "card") details")
            withAnimation { secret = s }
            photo = try? SecurePhoto.load(ref: ref)
            vaultError = nil
        } catch { vaultError = error.localizedDescription }
    }

    private func savePhoto(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        do {
            try SecurePhoto.save(image, ref: ref)
            photo = image
            show("Photo saved, encrypted")
        } catch { show("Could not save photo") }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation { toast = nil }
        }
    }
}
