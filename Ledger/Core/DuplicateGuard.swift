import Foundation
import CoreData
import CryptoKit

// Duplicate prevention.
//
// This app now has SIX ways an expense can be created, and several of them fire
// for the same real-world purchase:
//
//   1. Quick add (you type it)
//   2. Shortcuts / Siri (Back Tap, location automation)
//   3. Bank alert automation (Chase texts you)
//   4. Receipt scan
//   5. Recurring autopay (posts itself on the due day)
//   6. CSV import
//
// Buy petrol on the Sapphire and you could easily get three copies: the bank
// texts you, you scan the receipt, and you also tapped Back Tap in the car.
// Without a guard the ledger silently inflates, and an inflated ledger is worse
// than no ledger because it fails reconciliation for reasons you can't find.
//
// Three tiers, because the right response differs:
//
//   EXACT      Same day, amount, merchant, card. Almost certainly one purchase
//              recorded twice. Blocked outright — the second write returns the
//              first record instead of creating anything.
//
//   NEAR       Same amount and merchant within 3 days, or same merchant and
//              card with amounts within 25%. Could be genuine (two Costco runs
//              in a week) or a pre-auth vs settled pair. Created, but linked
//              and surfaced for a human decision. NEVER auto-deleted.
//
//   SOURCE     The same bank alert or receipt processed twice. Deduped by a
//              hash of the source text, which is exact and cheap.
//
// The asymmetry is deliberate: silently deleting a real expense is a much worse
// failure than showing you one extra row to dismiss.

struct DuplicateMatch {
    enum Kind { case exact, near, sameSource }
    let kind: Kind
    let existing: CDExpense
    let reason: String
}

enum DuplicateGuard {

    // MARK: fingerprints

    /// Identity of a purchase: day + amount + merchant + card.
    static func fingerprint(date: Date, cents: Int, merchant: String, cardName: String) -> String {
        let day = dayString(date)
        let m = merchant.lowercased().trimmingCharacters(in: .whitespaces)
        return sha("\(day)|\(cents)|\(m)|\(cardName.lowercased())")
    }

    /// Identity of a *source document* — the exact SMS or receipt text.
    /// Prevents re-processing when an automation fires twice.
    static func sourceHash(_ text: String) -> String {
        sha(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: checks

    /// Call before creating an expense. Returns a match if one is found.
    static func check(date: Date, cents: Int, merchant: String, card: CDCard?,
                      sourceText: String? = nil,
                      context: NSManagedObjectContext) -> DuplicateMatch? {

        // Tier 3 — same source document already processed.
        if let sourceText {
            let hash = sourceHash(sourceText)
            let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
            r.predicate = NSPredicate(format: "sourceHash == %@", hash)
            r.fetchLimit = 1
            if let hit = try? context.fetch(r).first {
                return DuplicateMatch(kind: .sameSource, existing: hit,
                                      reason: "This exact alert or receipt was already processed.")
            }
        }

        // Tier 1 — exact fingerprint.
        let fp = fingerprint(date: date, cents: cents,
                             merchant: merchant, cardName: card?.name ?? "")
        let exact = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        exact.predicate = NSPredicate(format: "dupeHash == %@", fp)
        exact.fetchLimit = 1
        if let hit = try? context.fetch(exact).first {
            return DuplicateMatch(kind: .exact, existing: hit,
                                  reason: "Same amount, merchant and card on the same day.")
        }

        // Tier 2 — near matches within a 3-day window.
        let window: TimeInterval = 3 * 86_400
        let near = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        near.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@ AND merchantKey == %@",
            date.addingTimeInterval(-window) as NSDate,
            date.addingTimeInterval(window) as NSDate,
            merchant.lowercased())
        let candidates = (try? context.fetch(near)) ?? []

        for c in candidates {
            let other = Int(c.amountCents)
            if other == cents {
                return DuplicateMatch(kind: .near, existing: c,
                                      reason: "Same amount at the same merchant \(dayGap(date, c.date)).")
            }
            // Pre-authorisation vs settled: a restaurant authorises before the
            // tip, so the pair differs by roughly the tip amount.
            if cents > 0, other > 0 {
                let ratio = Double(max(cents, other)) / Double(min(cents, other))
                if ratio <= 1.35 && c.card?.objectID == card?.objectID {
                    return DuplicateMatch(kind: .near, existing: c,
                        reason: "Similar amount at the same merchant \(dayGap(date, c.date)) — possibly the pre-tip authorisation of the same purchase.")
                }
            }
        }
        return nil
    }

    private static func dayGap(_ a: Date, _ b: Date?) -> String {
        guard let b else { return "nearby" }
        let days = abs(Calendar.current.dateComponents([.day], from: b, to: a).day ?? 0)
        switch days {
        case 0: return "on the same day"
        case 1: return "a day apart"
        default: return "\(days) days apart"
        }
    }

    // MARK: safe creation
    //
    // The single entry point every source should use. Nothing else should call
    // `CDExpense(context:)` directly.

    enum Outcome {
        case created(CDExpense)
        case blocked(DuplicateMatch)       // exact or same-source; nothing written
        case flagged(CDExpense, DuplicateMatch)  // near; written and linked
    }

    @discardableResult
    static func create(date: Date, amount: Money, merchant: String,
                       category: Category, card: CDCard?, payer: Payer = .us,
                       notes: String = "", source: String = "manual",
                       sourceText: String? = nil,
                       ruleID: UUID? = nil,
                       isEstimated: Bool = false,
                       needsReview: Bool = false,
                       context: NSManagedObjectContext) -> Outcome {

        let match = check(date: date, cents: amount.cents, merchant: merchant,
                          card: card, sourceText: sourceText, context: context)

        if let match, match.kind == .exact || match.kind == .sameSource {
            return .blocked(match)
        }

        let e = CDExpense(context: context)
        e.id = UUID()
        e.date = date
        e.amountCents = Int64(amount.cents)
        e.merchant = merchant.trimmingCharacters(in: .whitespaces)
        e.merchantKey = merchant.lowercased().trimmingCharacters(in: .whitespaces)
        e.category = category.rawValue
        e.payer = payer.rawValue
        e.card = card
        e.notes = notes
        e.cycleKey = CycleCalendar.key(for: date)
        e.source = source
        e.ruleID = ruleID
        e.isEstimated = isEstimated
        e.createdAt = .now
        e.updatedAt = .now
        e.dupeHash = fingerprint(date: date, cents: amount.cents,
                                 merchant: merchant, cardName: card?.name ?? "")
        if let sourceText { e.sourceHash = sourceHash(sourceText) }

        if let match {
            e.possibleDuplicateOf = match.existing.id
            e.needsReview = true
            e.notes = "Possible duplicate — \(match.reason) \(notes)"
                .trimmingCharacters(in: .whitespaces)
            Persistence.shared.save()
            return .flagged(e, match)
        }

        e.needsReview = needsReview
        Persistence.shared.save()
        return .created(e)
    }

    /// Recompute every fingerprint. Run after a bulk import or after editing
    /// merchant names, since the hash depends on them.
    static func reindex(context: NSManagedObjectContext) {
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        for e in (try? context.fetch(r)) ?? [] {
            e.dupeHash = fingerprint(date: e.date ?? .distantPast,
                                     cents: Int(e.amountCents),
                                     merchant: e.merchant ?? "",
                                     cardName: e.card?.name ?? "")
        }
        Persistence.shared.save()
    }

    /// Groups of records sharing a fingerprint — for the cleanup screen.
    static func clusters(context: NSManagedObjectContext) -> [[CDExpense]] {
        let r = NSFetchRequest<CDExpense>(entityName: "CDExpense")
        r.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        let all = (try? context.fetch(r)) ?? []
        return Dictionary(grouping: all, by: { $0.dupeHash ?? "" })
            .values
            .filter { $0.count > 1 && !($0.first?.dupeHash ?? "").isEmpty }
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }
}
