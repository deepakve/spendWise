import Foundation

// Parsing bank transaction alerts.
//
// iOS gives no app access to another app's notifications — there is no
// equivalent of Android's NotificationListenerService, and there never has
// been. So the app cannot read your Chase push alert.
//
// It can read the SMS or email Chase sends for the same transaction, because
// Shortcuts has Message and Email automation triggers that can run without
// asking. The chain is:
//
//   Chase texts you  →  Shortcuts automation matches the sender
//                    →  passes the message text to this parser
//                    →  expense created, flagged if anything was uncertain
//
// Every issuer words these differently, so the parser is format-driven rather
// than one clever regex. Anything it can't pin down becomes a question rather
// than a guess — an alert logged at the wrong amount is worse than one that
// waited thirty seconds for you to confirm.

struct ParsedAlert {
    var amount: Money?
    var merchant: String?
    var last4: String?
    var issuer: String?
    var isDecline = false
    var isRefund = false
    var uncertain: Set<Field> = []
    var raw: String = ""

    enum Field: String, CaseIterable { case amount, merchant, card }

    var isUsable: Bool { amount != nil && !isDecline }

    /// What the app should ask about, in the order worth asking.
    var questions: [Field] {
        Field.allCases.filter { uncertain.contains($0) }
    }
}

enum AlertParser {

    static func parse(_ text: String) -> ParsedAlert {
        var out = ParsedAlert()
        out.raw = text
        let low = text.lowercased()

        // Declines and holds are not spend. Logging them would inflate every
        // total and they'd never appear on the statement.
        if low.contains("declined") || low.contains("was denied")
            || low.contains("unable to process") || low.contains("suspected fraud") {
            out.isDecline = true
        }
        if low.contains("refund") || low.contains("credit was posted")
            || low.contains("returned") || low.contains("credited to your") {
            out.isRefund = true
        }

        out.issuer = detectIssuer(low)
        out.amount = findAmount(text)
        if out.amount == nil { out.uncertain.insert(.amount) }

        out.last4 = findLast4(text)
        if out.last4 == nil { out.uncertain.insert(.card) }

        out.merchant = findMerchant(text)
        if out.merchant == nil || (out.merchant?.count ?? 0) < 2 {
            out.uncertain.insert(.merchant)
        }

        return out
    }

    private static func detectIssuer(_ low: String) -> String? {
        let map: [(String, String)] = [
            ("chase", "Chase"), ("amex", "American Express"),
            ("american express", "American Express"), ("discover", "Discover"),
            ("citi", "Citi"), ("bank of america", "Bank of America"),
            ("bofa", "Bank of America"), ("wells fargo", "Wells Fargo"),
            ("apple card", "Apple Card"), ("goldman", "Apple Card"),
            ("bilt", "Bilt"), ("synchrony", "Synchrony"), ("paypal", "PayPal")
        ]
        for (needle, name) in map where low.contains(needle) { return name }
        return nil
    }

    /// The transaction amount, not a credit limit or a rewards balance.
    private static func findAmount(_ text: String) -> Money? {
        // Prefer an amount that follows a transaction word.
        let contextual = #"(?i)(?:transaction|purchase|charge|charged|payment|amount|of|for)\s*(?:of\s*)?\$\s?([\d,]+\.\d{2})"#
        if let rx = try? NSRegularExpression(pattern: contextual) {
            let ns = text as NSString
            if let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return Money.parse(ns.substring(with: m.range(at: 1)))
            }
        }
        // Otherwise the first dollar amount, ignoring obvious balances.
        let generic = #"\$\s?([\d,]+\.\d{2})"#
        guard let rx = try? NSRegularExpression(pattern: generic) else { return nil }
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: max(m.range.location - 20, 0)).lowercased()
            if before.contains("balance") || before.contains("limit")
                || before.contains("available") || before.contains("rewards") { continue }
            return Money.parse(ns.substring(with: m.range(at: 1)))
        }
        return nil
    }

    private static func findLast4(_ text: String) -> String? {
        let patterns = [
            #"(?i)(?:ending in|ending|card ending)\s*(?:in\s*)?[*x#.]*\s?(\d{4})"#,
            #"(?i)account\s*(?:ending)?\s*[*x#.]*\s?(\d{4})"#,
            #"[*x#.]{2,}\s?(\d{4})\b"#
        ]
        let ns = text as NSString
        for p in patterns {
            guard let rx = try? NSRegularExpression(pattern: p) else { continue }
            if let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    /// Merchant sits between a preposition and a trailing clause. Issuers vary:
    ///   Chase:    "...transaction with BAWARCHI BIRYANI on card ending..."
    ///   Amex:     "...of $250.00 at COSTCO WHSE was charged..."
    ///   Discover: "...transaction of $16.57 at WORLD OF SMOKE was made..."
    private static func findMerchant(_ text: String) -> String? {
        let patterns = [
            #"(?i)(?:transaction|purchase|charge)\s+(?:with|at|from)\s+(.+?)(?:\s+(?:on|was|for|has|is)\b|[,.]|$)"#,
            #"(?i)\bat\s+(.+?)(?:\s+(?:on|was|for|has|is)\b|[,.]|$)"#,
            #"(?i)\bwith\s+(.+?)(?:\s+(?:on|was|for|has|is)\b|[,.]|$)"#
        ]
        let ns = text as NSString
        for p in patterns {
            guard let rx = try? NSRegularExpression(pattern: p) else { continue }
            guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            var name = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-"))
            // Strip store numbers and city/state tails that merchants append.
            name = name.replacingOccurrences(of: #"\s+#?\d{3,}$"#, with: "",
                                             options: .regularExpression)
            name = name.replacingOccurrences(of: #"\s+[A-Z]{2}$"#, with: "",
                                             options: .regularExpression)
            guard name.count >= 2, name.count <= 45 else { continue }
            // Reject things that are clearly not a merchant.
            let bad = ["your card", "your account", "card ending", "the amount"]
            if bad.contains(where: { name.lowercased().contains($0) }) { continue }
            return name.capitalized
        }
        return nil
    }
}
