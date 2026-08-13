import SwiftUI

// Design language: "card on receipt paper".
//
// Two materials define this subject. Cards are laminated, layered, metallic,
// saturated. Receipts are thin, monospaced, ruled, almost colourless. The app
// puts one on the other: vivid card objects as the hero, everything around them
// set like a printed statement — tabular figures, dotted leaders, tracked-out
// micro-labels.
//
// This is why numbers are monospaced everywhere. In a ledger, digits that line
// up column-to-column are legible in a way proportional figures never are, and
// it's the visual signature of every receipt and statement you've ever read.

enum Ink {
    // Substrate — warm-neutral, not pure grey. Receipt paper has a tint.
    static let paper       = Color(hex: "#F7F5F2")
    static let paperDark   = Color(hex: "#14151A")
    static let rule        = Color(hex: "#D8D3CB")
    static let ruleDark    = Color(hex: "#2C2E38")

    // Type
    static let primary     = Color(hex: "#16171C")
    static let secondary   = Color(hex: "#6B6862")
    static let faint       = Color(hex: "#A8A29A")

    // Semantics — brass for money in, coral for owed, mint for refunds.
    static let brass       = Color(hex: "#B8873B")
    static let coral       = Color(hex: "#E0553F")
    static let mint        = Color(hex: "#2E9E7B")
    static let ocean       = Color(hex: "#2B5CE0")
}

enum Face {
    /// The one serif in the app. Used only for the headline amount, where the
    /// statement-formality is the point. Everywhere else would be decoration.
    static func amount(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
    /// Every other number. Tabular so columns align.
    static func figure(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Receipt vernacular: tiny, tracked-out, uppercase field labels.
struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(Ink.faint)
    }
}

/// The dotted leader between a label and its value, straight off a printed
/// statement. Encodes the same thing the paper does: these two belong together.
struct DottedLeader: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .frame(height: 1)
            .foregroundStyle(Ink.faint.opacity(0.55))
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Label · · · · · · value — the core row of the whole app.
struct LedgerRow<Trailing: View>: View {
    let label: String
    var emphasis: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Face.body(15, weight: emphasis ? .semibold : .regular))
                .foregroundStyle(emphasis ? Ink.primary : Ink.secondary)
                .fixedSize()
            DottedLeader()
            trailing()
        }
    }
}

/// Perforated tear line, used where a statement would end.
struct Perforation: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<60, id: \.self) { _ in
                Circle().frame(width: 2.5, height: 2.5)
            }
        }
        .foregroundStyle(Ink.rule)
        .frame(height: 3, alignment: .center)
        .clipped()
    }
}

// MARK: - Issuer palettes
//
// Each card gets a two-stop gradient drawn from its issuer's real identity, so
// the wallet is scannable by colour before you read a word. Not decorative:
// this is how you find the Bilt card in a stack of twenty at a checkout.

struct CardSkin {
    let top: Color, bottom: Color, ink: Color

    static func forIssuer(_ issuer: String, name: String, fallbackHex: String) -> CardSkin {
        let key = (issuer + " " + name).lowercased()
        func skin(_ a: String, _ b: String, light: Bool = true) -> CardSkin {
            CardSkin(top: Color(hex: a), bottom: Color(hex: b),
                     ink: light ? .white : Color(hex: "#16171C"))
        }
        if key.contains("bilt")            { return skin("#1C1C1E", "#3A3A3E") }
        if key.contains("sapphire")        { return skin("#0B3D91", "#1C6FD0") }
        if key.contains("prime")           { return skin("#0F4C81", "#2E8BC0") }
        if key.contains("freedom")         { return skin("#1B5E9E", "#4AA3DF") }
        if key.contains("discover")        { return skin("#E86C1A", "#F5A623") }
        if key.contains("costco")          { return skin("#005DAA", "#E31837") }
        if key.contains("citi")            { return skin("#003B70", "#0F7CC0") }
        if key.contains("amex") && key.contains("gold") {
            return CardSkin(top: Color(hex: "#C9A227"), bottom: Color(hex: "#EFD98B"),
                            ink: Color(hex: "#3A2F00"))
        }
        if key.contains("amex")            { return skin("#2E6FB7", "#7FB2E5") }
        if key.contains("apple")           { return CardSkin(top: Color(hex: "#F2F2F4"),
                                                             bottom: Color(hex: "#D9D9DE"),
                                                             ink: Color(hex: "#1C1C1E")) }
        if key.contains("wells")           { return skin("#B31B1B", "#E8A33D") }
        if key.contains("bofa") || key.contains("bank of america") { return skin("#012169", "#C8102E") }
        if key.contains("paypal")          { return skin("#003087", "#009CDE") }
        if key.contains("target")          { return skin("#CC0000", "#FF4D4D") }
        if key.contains("best buy")        { return skin("#003B64", "#FFE000") }
        if key.contains("cash")            { return skin("#3F4A3C", "#6E7D68") }
        return skin(fallbackHex, fallbackHex)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF)/255,
                  green: Double((v >> 8) & 0xFF)/255,
                  blue: Double(v & 0xFF)/255)
    }
}

// MARK: - Feedback

enum Haptic {
    static func tap()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn()    { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// Small confirmation that slides in from the top. Used for copy actions, where
/// a full alert would be heavier than the action deserves.
struct Toast: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text).font(Face.body(14, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Ink.primary, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
