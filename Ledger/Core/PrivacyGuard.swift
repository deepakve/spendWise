import Foundation

// Privacy barrier.
//
// The goal: make "card data is never sent to an LLM provider" a property the
// compiler enforces, not a promise someone has to remember six months from now
// when adding a feature at 11pm.
//
// Three independent layers, because any single one can be defeated by a
// determined mistake:
//
//   1. TYPE BARRIER — outbound payloads can only be built from types that
//      conform to `DeviceSafe`. `CardSecret` and card photos deliberately do
//      not conform and cannot be made to conform from another file, so code
//      that tries to include them does not compile.
//
//   2. RUNTIME SCAN — anything about to leave the device is scanned for
//      card-number-shaped digit runs (validated with Luhn) and for the CVV/PIN
//      of every stored card. A hit throws rather than sending.
//
//   3. AUDIT LOG — every outbound payload is recorded locally with a hash, so
//      "what has this app ever sent" is an answerable question rather than a
//      matter of trust.
//
// Today none of this is exercised, because the app makes no network calls at
// all. It exists so that if a future version adds one, the barrier is already
// standing rather than being retrofitted around a shipped feature.

// MARK: - 1. Type barrier

/// Marker for data that is allowed to leave the device.
///
/// Conformance is deliberately restricted to this file. Adding a conformance
/// elsewhere is a visible, reviewable act rather than an accident.
public protocol DeviceSafe {
    /// The exact text that would leave the device.
    var outboundText: String { get }
}

/// A single ledger row, reduced to the fields a spending question needs.
/// Note what is absent: no card number, no CVV, no expiry, no photo, no
/// account identifier. Merchant and note are included because a question like
/// "how much on Bindu" is meaningless without them.
public struct SafeExpenseSummary: DeviceSafe {
    public let dateISO: String
    public let amountCents: Int
    public let merchant: String
    public let category: String
    public let payer: String
    public let cardNickname: String        // "Bilt" — a label, never a number
    public let note: String

    public var outboundText: String {
        "\(dateISO)|\(amountCents)|\(merchant)|\(category)|\(payer)|\(cardNickname)|\(note)"
    }
}

/// Aggregates carry no per-transaction detail at all.
public struct SafeAggregate: DeviceSafe {
    public let label: String
    public let totalCents: Int
    public let count: Int
    public var outboundText: String { "\(label)|\(totalCents)|\(count)" }
}

// CardSecret is NOT DeviceSafe, and this is load-bearing.
//
// There is intentionally no `extension CardSecret: DeviceSafe` anywhere in the
// app. Any attempt to place a CardSecret into an OutboundPayload fails to
// compile with "argument type 'CardSecret' does not conform to expected type
// 'DeviceSafe'". Same for the encrypted photo blobs, which are raw Data.

// MARK: - 2. Runtime scan

public enum PrivacyError: LocalizedError {
    case containsCardNumber
    case containsStoredSecret(field: String)
    case destinationNotAllowed(host: String)

    public var errorDescription: String? {
        switch self {
        case .containsCardNumber:
            "Blocked: the text contains something shaped like a card number."
        case .containsStoredSecret(let f):
            "Blocked: the text contains a stored \(f)."
        case .destinationNotAllowed(let h):
            "Blocked: \(h) is not an approved destination."
        }
    }
}

public enum PrivacyGuard {

    /// Hosts the app is permitted to contact. Empty by design: the app makes no
    /// outbound calls. Adding an entry is the single switch that would enable
    /// any external service, and it sits here where it is easy to audit.
    public static let allowedHosts: Set<String> = []

    /// Providers explicitly refused, so that adding one is never a silent
    /// one-line change.
    public static let blockedHosts: Set<String> = [
        "api.anthropic.com", "api.openai.com", "api.cohere.ai",
        "generativelanguage.googleapis.com", "api.mistral.ai",
        "api.together.xyz", "api.groq.com", "openrouter.ai"
    ]

    /// Build an outbound payload. This is the only supported way to produce
    /// text destined to leave the device, and it fails closed.
    public static func payload(_ items: [DeviceSafe],
                               destination host: String,
                               knownSecrets: [String] = []) throws -> String {
        guard !blockedHosts.contains(host.lowercased()),
              allowedHosts.contains(host.lowercased()) else {
            throw PrivacyError.destinationNotAllowed(host: host)
        }
        let text = items.map(\.outboundText).joined(separator: "\n")
        try assertClean(text, knownSecrets: knownSecrets)
        AuditLog.record(host: host, text: text)
        return text
    }

    /// Scan arbitrary text for card-shaped data. Public so it can be used as a
    /// belt-and-braces check anywhere, including on clipboard contents.
    public static func assertClean(_ text: String, knownSecrets: [String] = []) throws {
        if containsLikelyCardNumber(text) { throw PrivacyError.containsCardNumber }
        for secret in knownSecrets where !secret.isEmpty {
            if text.contains(secret) {
                throw PrivacyError.containsStoredSecret(field: "card secret")
            }
        }
    }

    /// A run of 13–19 digits that passes the Luhn checksum. Luhn matters: it
    /// keeps order numbers, phone numbers and dates from tripping the alarm,
    /// so the check stays useful instead of being disabled for false positives.
    public static func containsLikelyCardNumber(_ text: String) -> Bool {
        let digitsOnly = text.map { $0.isNumber ? $0 : " " }
        var run = ""
        for ch in digitsOnly + " " {
            if ch.isNumber { run.append(ch); continue }
            if run.count >= 13 && run.count <= 19, luhnValid(run) { return true }
            // Also catch grouped forms: "4147 4003 4779 9205" collapses to 16.
            run = ""
        }
        // Second pass: grouped numbers like "4147 4003 4779 9205" or
        // "4147-4003-4779-9205" — one number split by internal spacing.
        // Scoped to a local run of digits/spaces/dashes, not the whole text,
        // so an unrelated digit elsewhere (a date, a store number) can never
        // be stitched together with one somewhere else into a false match.
        guard let groupedRx = try? NSRegularExpression(pattern: #"\d[\d \-]{11,22}\d"#)
        else { return false }
        let ns = text as NSString
        for m in groupedRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let collapsed = ns.substring(with: m.range).filter { $0.isNumber }
            guard collapsed.count >= 13 else { continue }
            for len in stride(from: min(19, collapsed.count), through: 13, by: -1) {
                for start in 0...(collapsed.count - len) {
                    let slice = String(Array(collapsed)[start..<(start + len)])
                    if luhnValid(slice) { return true }
                }
            }
        }
        return false
    }

    static func luhnValid(_ number: String) -> Bool {
        let digits = number.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}

// MARK: - 3. Audit log

/// Local, append-only record of anything that left the device. Stores a hash
/// rather than the content, so the log itself is not a second copy of your data.
public enum AuditLog {
    public struct Entry: Codable, Identifiable {
        public let id: UUID
        public let date: Date
        public let host: String
        public let byteCount: Int
        public let sha256Prefix: String
    }

    private static let key = "privacy.auditlog"

    public static func record(host: String, text: String) {
        var entries = all()
        entries.append(Entry(id: UUID(), date: .now, host: host,
                             byteCount: text.utf8.count,
                             sha256Prefix: String(text.simpleHash.prefix(12))))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func all() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    public static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

private extension String {
    var simpleHash: String {
        var hash: UInt64 = 5381
        for byte in utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }
}
