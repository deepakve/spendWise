import SwiftUI
import CoreData
import CloudKit

// Share invite — one of the screens scoped for full cinematic treatment in
// DESIGN-DIRECTION-CINEMATIC.md. Obsidian background, glass, a lime accent
// CTA: inviting Subha into the ledger is an occasional, deliberate moment,
// not something read forty times a day the way the ledger list is, so it
// can afford to be the "hero" the way the card rail already is.
//
// Sharing mechanics live here rather than in SettingsView: prepareShare()
// per SECURITY-ARCHITECTURE.md §3 fetches-or-creates the real CKShare for
// the zone (an actual CDCard anchors the zone-wide share — see the comment
// below), and CloudSharingView wraps UICloudSharingController with it.

struct ShareInviteView: View {
    @Environment(\.managedObjectContext) private var ctx
    @EnvironmentObject private var store: Persistence

    @State private var share: CKShare?
    @State private var showShare = false
    @State private var message: String?
    @State private var isPreparing = false

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0A").ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Ink.accent.opacity(0.15))
                        .frame(width: 120, height: 120)
                        .blur(radius: Motion.prefersReduced ? 0 : 4)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Ink.accent)
                }

                VStack(spacing: 10) {
                    Text("Share this ledger")
                        .font(Face.amount(28))
                        .foregroundStyle(.white)
                    Text("She installs the app, taps your invite, and reads and writes the same ledger from her own Apple ID. No shared password. You can revoke access at any time.")
                        .font(Face.body(14))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Spacer()

                if let message {
                    Text(message)
                        .font(Face.body(12))
                        .foregroundStyle(Ink.coral)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Button {
                    Task { await prepareShare() }
                } label: {
                    HStack(spacing: 8) {
                        if isPreparing { ProgressView().tint(.black) }
                        Text(isPreparing ? "Preparing…" : "Send invite")
                    }
                    .font(Face.body(16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Ink.accent,
                                in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
                }
                .disabled(isPreparing)
                .padding(.horizontal, 24).padding(.bottom, 30)
            }
        }
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showShare) {
            if let share {
                CloudSharingView(share: share,
                                 container: CKContainer(identifier: Persistence.containerID))
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
        isPreparing = true
        defer { isPreparing = false }
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
}
