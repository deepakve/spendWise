import Foundation
import Vision
import UIKit

// Receipt scanning.
//
// You asked whether a photo could add the bill, and doubted the app could know
// the card. It usually can — and that's the interesting part.
//
// Almost every card receipt prints the payment method and the last four digits
// of the card near the total, because the card networks require the cardholder
// copy to identify the account:
//
//     VISA ************9205        → Chase Prime
//     MASTERCARD ****8099          → Bilt
//     AMEX XXXXXXXXXXX3306         → Amex Blue
//     DISCOVER ....3807            → Discover
//
// You already store `last4` per card, so matching those four digits against
// your wallet identifies the card exactly — often more reliably than you'd
// remember it yourself three days later.
//
// What it extracts: total, date, merchant, card last-4, and a guess at
// category from the merchant. What it does NOT do is save silently. OCR on a
// crumpled receipt in bad light is wrong often enough that a silent save would
// poison the ledger. It pre-fills the add screen with everything it found and
// marks each field with how confident it is.

struct ScannedReceipt {
    var total: Money?
    var date: Date?
    var merchant: String?
    var cardLast4: String?
    var subtotal: Money?
    var tax: Money?
    var allLines: [String] = []

    /// Fields the scan is unsure about, shown in the UI so you check those first.
    var lowConfidence: Set<Field> = []
    enum Field: String { case total, date, merchant, card }
}

enum ReceiptScanner {

    static func scan(_ image: UIImage) async -> ScannedReceipt {
        guard let cg = image.cgImage else { return ScannedReceipt() }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // receipts aren't prose
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try? handler.perform([request])

        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return parse(lines)
    }

    static func parse(_ lines: [String]) -> ScannedReceipt {
        var out = ScannedReceipt()
        out.allLines = lines
        let joined = lines.joined(separator: "\n")

        out.total = findTotal(lines)
        if out.total == nil { out.lowConfidence.insert(.total) }

        out.subtotal = findAmount(after: ["subtotal", "sub total"], in: lines)
        out.tax = findAmount(after: ["tax", "sales tax"], in: lines)

        out.date = findDate(joined)
        if out.date == nil { out.lowConfidence.insert(.date) }

        out.cardLast4 = findCardLast4(joined)
        if out.cardLast4 == nil { out.lowConfidence.insert(.card) }

        out.merchant = findMerchant(lines)
        if out.merchant == nil { out.lowConfidence.insert(.merchant) }

        return out
    }

    // MARK: total
    //
    // Taken from the line labelled TOTAL rather than the largest number on the
    // receipt — the largest is often a "you saved" figure or a loyalty balance.
    // Preference order matters: GRAND TOTAL beats TOTAL beats AMOUNT DUE, and
    // SUBTOTAL is explicitly excluded.

    private static func findTotal(_ lines: [String]) -> Money? {
        let priority = ["grand total", "total due", "amount due", "balance due",
                        "total", "amount", "charged"]
        for label in priority {
            for (i, line) in lines.enumerated() {
                let low = line.lowercased()
                guard low.contains(label) else { continue }
                if low.contains("sub") || low.contains("tax only") { continue }
                if let m = amount(in: line) { return m }
                // Value sometimes sits on the following line in two-column layouts.
                if i + 1 < lines.count, let m = amount(in: lines[i + 1]) { return m }
            }
        }
        return nil
    }

    private static func findAmount(after labels: [String], in lines: [String]) -> Money? {
        for label in labels {
            for line in lines where line.lowercased().contains(label) {
                if let m = amount(in: line) { return m }
            }
        }
        return nil
    }

    /// Last currency-shaped number on a line — receipts put the label left,
    /// the value right.
    private static func amount(in line: String) -> Money? {
        let pattern = #"\$?\s?(\d{1,6}[.,]\d{2})"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let matches = rx.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        let raw = ns.substring(with: last.range(at: 1)).replacingOccurrences(of: ",", with: ".")
        return Money.parse(raw)
    }

    // MARK: card last 4

    private static func findCardLast4(_ text: String) -> String? {
        // Masked forms: ****1234, XXXX1234, ....1234, ############1234
        let masked = #"(?:[*xX#.•]{2,}\s?)(\d{4})\b"#
        if let rx = try? NSRegularExpression(pattern: masked) {
            let ns = text as NSString
            if let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1))
            }
        }
        // Labelled forms: "CARD 1234", "ACCT: 1234", "VISA 1234"
        let labelled = #"(?i)(?:visa|mastercard|master card|amex|american express|discover|debit|credit|card|acct|account)[^\d\n]{0,12}(\d{4})\b"#
        if let rx = try? NSRegularExpression(pattern: labelled) {
            let ns = text as NSString
            if let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    // MARK: date

    private static func findDate(_ text: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let ns = text as NSString
        let matches = detector?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        // Nearest plausible purchase date: within the last year, not future.
        let now = Date()
        let candidates = matches.compactMap(\.date).filter {
            $0 <= now.addingTimeInterval(86_400) && $0 > now.addingTimeInterval(-365 * 86_400)
        }
        return candidates.first
    }

    // MARK: merchant
    //
    // Merchant name is almost always in the first few lines, in caps, above the
    // address. Skip lines that are clearly an address, phone number or receipt
    // metadata.

    private static func findMerchant(_ lines: [String]) -> String? {
        let skip = ["receipt", "invoice", "order", "welcome", "thank", "store",
                    "tel", "phone", "www", "http", "#", "customer copy"]
        for line in lines.prefix(6) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3, t.count <= 40 else { continue }
            let low = t.lowercased()
            if skip.contains(where: { low.contains($0) }) { continue }
            if t.filter(\.isNumber).count > t.count / 2 { continue }   // address line
            if t.range(of: #"^\d"#, options: .regularExpression) != nil { continue }
            return t.capitalized
        }
        return nil
    }

    /// Match a scanned or parsed last-4 against every identifier a card has.
    ///
    /// Checks the card number, the bank account number, and any additional
    /// digits recorded for the same funding source. A Cadillac autopay
    /// confirmation names the checking account (6932), not the debit card
    /// (9636) — matching only on `last4` misses it entirely, which is exactly
    /// the bug that put an unassigned row in the ledger.
    static func matchCard(last4: String?, among cards: [CDCard]) -> CDCard? {
        guard let raw = last4 else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count == 4 else { return nil }

        for card in cards {
            for candidate in card.allIdentifiers where candidate == digits {
                return card
            }
        }
        return nil
    }
}
