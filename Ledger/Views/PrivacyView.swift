import SwiftUI

// A screen you can open to check the claim, rather than trusting a README.
// It reads the same constants the code enforces, so it cannot drift out of
// date: if someone adds an approved host, this screen shows it.

struct PrivacyView: View {
    @State private var log = AuditLog.all()

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: PrivacyGuard.allowedHosts.isEmpty
                          ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(PrivacyGuard.allowedHosts.isEmpty ? Ink.mint : Ink.coral)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PrivacyGuard.allowedHosts.isEmpty
                             ? "Nothing leaves this device"
                             : "\(PrivacyGuard.allowedHosts.count) approved destination(s)")
                            .font(Face.body(16, weight: .semibold))
                        Text("Apart from your own iCloud")
                            .font(Face.body(12)).foregroundStyle(Ink.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Where your data lives") {
                dataRow("Expenses, cards, statements", "Your private iCloud database",
                        detail: "Encrypted in transit and at rest. Shared only with people you invite.")
                dataRow("Card numbers, CVV, PIN", "This device's Keychain",
                        detail: "Face ID on every read. Marked device-only, so it is excluded from iCloud and from backups.")
                dataRow("Card photos", "Encrypted file on this device",
                        detail: "AES-GCM with a key held in the Keychain. Never written to your photo library.")
            }

            Section {
                ForEach(Array(PrivacyGuard.blockedHosts).sorted(), id: \.self) { host in
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Ink.coral).font(.system(size: 13))
                        Text(host).font(Face.figure(13))
                        Spacer()
                        Text("blocked").font(.system(size: 10, weight: .semibold))
                            .tracking(0.8).foregroundStyle(Ink.faint)
                    }
                }
            } header: {
                Text("AI providers")
            } footer: {
                Text("These are refused at the code level. The app also has no networking code at all — no URLSession, no web views. Adding one would require changing the approved-destinations list above, which this screen reads directly.")
            }

            Section {
                if log.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray").foregroundStyle(Ink.faint)
                        Text("Nothing has ever been sent.")
                            .font(Face.body(14)).foregroundStyle(Ink.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(log.reversed()) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.host).font(Face.body(14, weight: .medium))
                            Text("\(e.date.formatted()) · \(e.byteCount) bytes · \(e.sha256Prefix)")
                                .font(.system(size: 10)).foregroundStyle(Ink.faint)
                        }
                    }
                }
            } header: {
                Text("Outbound log")
            } footer: {
                Text("Every payload that leaves the device is recorded here with a hash of its contents. The log stores hashes rather than the data itself, so it is not a second copy of your ledger.")
            }

            Section {
                Text("Two safeguards run on anything about to leave: a scan for card-shaped digit runs, checked with the Luhn algorithm, and a check against every CVV and PIN you have stored. Either one blocks the send.\n\nSeparately, card details cannot be placed into an outbound payload at all — the type does not permit it, so such code fails to build.")
                    .font(Face.body(12)).foregroundStyle(Ink.secondary)
            } header: {
                Text("How it's enforced")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { log = AuditLog.all() }
    }

    private func dataRow(_ what: String, _ where_: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(what).font(Face.body(14, weight: .medium))
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10)).foregroundStyle(Ink.faint)
                Text(where_).font(Face.body(13)).foregroundStyle(Ink.ocean)
            }
            Text(detail).font(Face.body(11)).foregroundStyle(Ink.secondary)
        }
        .padding(.vertical, 4)
    }
}
