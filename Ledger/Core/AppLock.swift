import SwiftUI
import LocalAuthentication

// Whole-app lock.
//
// `.deviceOwnerAuthentication` rather than `.deviceOwnerAuthenticationWithBiometrics`
// so the device passcode is an automatic fallback — Face ID fails often enough
// (mask, dark, wet hands) that biometrics-only would lock you out of your own
// ledger at the worst moment.
//
// The app also re-locks when it goes to the background and stays there past a
// grace period, so handing someone your unlocked phone doesn't expose it. The
// grace period exists because re-authenticating every time you glance at a
// notification would make you turn the feature off.

@MainActor
final class AppLock: ObservableObject {
    @Published var isUnlocked = false
    @Published var failureMessage: String?

    @AppStorage("lockEnabled") var lockEnabled = true
    @AppStorage("lockGraceSeconds") var graceSeconds = 60.0

    private var backgroundedAt: Date?

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Passcode"
        }
    }

    func authenticate() async {
        guard lockEnabled else { isUnlocked = true; return }

        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"

        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device — nothing to authenticate against.
            // Unlock rather than brick the app, and say why.
            failureMessage = "No device passcode is set, so the app can't lock."
            isUnlocked = true
            return
        }

        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your ledger")
            isUnlocked = ok
            failureMessage = ok ? nil : "Authentication failed."
        } catch {
            isUnlocked = false
            failureMessage = (error as NSError).code == LAError.userCancel.rawValue
                ? nil : error.localizedDescription
        }
    }

    func didEnterBackground() {
        backgroundedAt = .now
    }

    func didBecomeActive() async {
        guard lockEnabled else { return }
        if let since = backgroundedAt,
           Date.now.timeIntervalSince(since) > graceSeconds {
            isUnlocked = false
        }
        backgroundedAt = nil
        if !isUnlocked { await authenticate() }
    }
}

struct LockGate<Content: View>: View {
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var phase
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            if lock.isUnlocked {
                content()
                    .environmentObject(lock)
                    .transition(.opacity)
            } else {
                lockScreen
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.isUnlocked)
        .task { await lock.authenticate() }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .background: lock.didEnterBackground()
            case .active:     Task { await lock.didBecomeActive() }
            default: break
            }
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Ledger").font(.largeTitle.weight(.semibold))
            Text("Locked").foregroundStyle(.secondary)

            Button {
                Task { await lock.authenticate() }
            } label: {
                Label("Unlock with \(lock.biometryName)", systemImage: "faceid")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let msg = lock.failureMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
