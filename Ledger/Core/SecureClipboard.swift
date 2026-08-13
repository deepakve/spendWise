import UIKit
import SwiftUI

// A hole I opened last turn, and should have closed then.
//
// I added Copy buttons for card numbers. On iOS, `UIPasteboard.general` is
// persistent and — with Universal Clipboard on — is broadcast to every Mac and
// iPad signed into the same Apple ID within about two minutes. So tapping
// "copy card number" was quietly publishing it to your other devices and
// leaving it there indefinitely, readable by any app you open next.
//
// Two fixes:
//
//   1. `expirationDate` — iOS clears the item automatically at the deadline,
//      even if the app is killed. 90 seconds is enough to switch apps and
//      paste, short enough that the number isn't sitting there at dinner.
//
//   2. `localOnly` — the item never crosses to Universal Clipboard, so a card
//      number copied on your phone doesn't surface on a shared Mac.
//
// Also here: screenshot and screen-recording protection, because the other way
// card details escape is a screenshot syncing to iCloud Photos.

enum SecureClipboard {

    /// Copy something sensitive: local to this device, auto-erased shortly after.
    static func copySensitive(_ value: String, seconds: TimeInterval = 90) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(seconds)
            ])
    }

    /// Ordinary copy for non-sensitive text, e.g. a merchant name.
    static func copy(_ value: String) {
        UIPasteboard.general.string = value
    }

    /// Clear immediately — used when the card detail screen closes.
    static func clearIfSensitive(_ value: String) {
        if UIPasteboard.general.string == value {
            UIPasteboard.general.items = []
        }
    }
}

import UniformTypeIdentifiers

// MARK: - Screen capture protection

/// Blanks the wrapped content while the screen is being recorded or mirrored,
/// and warns after a screenshot. iOS gives no way to *block* a screenshot, so
/// the honest approach is to detect it and tell you what just happened —
/// that image is now in Photos, and Photos syncs.
struct CaptureGuard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var isCaptured = UIScreen.main.isCaptured
    @State private var showScreenshotWarning = false

    var body: some View {
        Group {
            if isCaptured {
                VStack(spacing: 14) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Ink.faint)
                    Text("Hidden while recording")
                        .font(Face.body(15, weight: .medium))
                    Text("Card details stay hidden while the screen is being recorded or mirrored.")
                        .font(Face.body(12))
                        .foregroundStyle(Ink.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Ink.paper)
            } else {
                content()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIScreen.capturedDidChangeNotification)) { _ in
            withAnimation { isCaptured = UIScreen.main.isCaptured }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            showScreenshotWarning = true
        }
        .alert("You just took a screenshot", isPresented: $showScreenshotWarning) {
            Button("Open Photos to delete it") {
                if let url = URL(string: "photos-redirect://") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("That image contains your card details and will sync to iCloud Photos. Deleting it is usually the right call.")
        }
    }
}
