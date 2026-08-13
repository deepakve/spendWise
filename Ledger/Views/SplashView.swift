import SwiftUI

// First-launch splash.
//
// DESIGN-DIRECTION-CINEMATIC.md: "the reference's 3s monogram shimmer maps
// well to a first-launch splash — keep it to first launch only, not every
// cold start, or it becomes friction on an app opened many times a day."
// Full cinematic treatment: obsidian background, lime accent, a serif
// monogram with a shimmer pass. Gated behind a one-time flag so it never
// appears again after the first successful launch.

struct SplashView: View {
    @AppStorage("hasSeenSplash") private var hasSeenSplash = false
    @State private var shimmerOffset: CGFloat = -140
    @State private var isDismissing = false
    var onFinished: () -> Void

    private let monogramFont = Font.system(size: 64, weight: .semibold, design: .serif).italic()

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0A").ignoresSafeArea()
            VStack(spacing: 14) {
                Text("L")
                    .font(monogramFont)
                    .foregroundStyle(Ink.accent)
                    .overlay {
                        if !Motion.prefersReduced {
                            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .rotationEffect(.degrees(20))
                                .offset(x: shimmerOffset)
                                .mask(Text("L").font(monogramFont))
                        }
                    }
                Text("LEDGER")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .opacity(isDismissing ? 0 : 1)
        .onAppear(perform: start)
    }

    private func start() {
        guard !Motion.prefersReduced else { finish(after: 0.6); return }
        withAnimation(.easeInOut(duration: 1.1).repeatCount(2, autoreverses: false)) {
            shimmerOffset = 140
        }
        finish(after: 3)
    }

    private func finish(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            hasSeenSplash = true
            withAnimation(.easeOut(duration: 0.4)) { isDismissing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: onFinished)
        }
    }
}
