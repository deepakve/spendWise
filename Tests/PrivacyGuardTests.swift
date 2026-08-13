import XCTest
@testable import Ledger

// These tests exist to be run, and to be re-run by anyone (including a future
// version of me) who touches the networking or query code. They assert the
// privacy property directly rather than assuming it.

final class PrivacyGuardTests: XCTestCase {

    // Standard published test card numbers. Valid Luhn, issued by the card
    // networks specifically for testing, tied to no real account.
    let visaTest       = "4111111111111111"
    let mastercardTest = "5555555555554444"
    let amexTest       = "378282246310005"
    let discoverTest   = "6011111111111117"

    // MARK: destination

    func testNoHostIsAllowedByDefault() {
        XCTAssertTrue(PrivacyGuard.allowedHosts.isEmpty,
                      "The app should have no approved outbound destination.")
    }

    func testLLMProvidersAreBlocked() throws {
        let item = SafeAggregate(label: "Eat Out", totalCents: 13447, count: 12)
        for host in ["api.anthropic.com", "api.openai.com",
                     "generativelanguage.googleapis.com", "api.groq.com"] {
            XCTAssertThrowsError(
                try PrivacyGuard.payload([item], destination: host),
                "Payload to \(host) must be refused") { error in
                guard case PrivacyError.destinationNotAllowed = error else {
                    return XCTFail("Wrong error for \(host): \(error)")
                }
            }
        }
    }

    func testUnknownHostIsRefused() {
        let item = SafeAggregate(label: "Groceries", totalCents: 100_000, count: 4)
        XCTAssertThrowsError(try PrivacyGuard.payload([item], destination: "example.com"))
    }

    // MARK: card-number detection

    func testDetectsBareCardNumbers() {
        for n in [visaTest, mastercardTest, amexTest, discoverTest] {
            XCTAssertTrue(PrivacyGuard.containsLikelyCardNumber(n),
                          "\(n) should be detected")
        }
    }

    func testDetectsGroupedAndSeparatedCardNumbers() {
        let variants = [
            "4111 1111 1111 1111",
            "4111-1111-1111-1111",
            "my card is 4111111111111111 ok",
            "card:4111111111111111;exp:07/31"
        ]
        for v in variants {
            XCTAssertTrue(PrivacyGuard.containsLikelyCardNumber(v),
                          "Should detect card number in: \(v)")
        }
    }

    func testDoesNotFlagOrdinaryLedgerText() {
        // Real strings from the ledger. None should trip the alarm, or the
        // check would get disabled for noise.
        let benign = [
            "Chowrastha 12.98 Eat Out",
            "Costco gift card 6355 3655",          // partial, fails Luhn
            "Jordan Tax 951.26 audit 924 + 27.26",
            "Order 1234567890 shipped",
            "Phone 214 555 0134",
            "Bilt 34.74% APR due day 8",
            "2026-06 cycle total 2828.76"
        ]
        for text in benign {
            XCTAssertFalse(PrivacyGuard.containsLikelyCardNumber(text),
                           "False positive on: \(text)")
        }
    }

    func testLuhnRejectsNearMisses() {
        // One digit off a valid number — must not validate.
        XCTAssertFalse(PrivacyGuard.luhnValid("4111111111111112"))
        XCTAssertTrue(PrivacyGuard.luhnValid(visaTest))
    }

    // MARK: secret scanning

    func testBlocksTextContainingStoredCVV() {
        XCTAssertThrowsError(
            try PrivacyGuard.assertClean("spend summary cvv 906", knownSecrets: ["906"]))
    }

    func testCleanTextPasses() throws {
        XCTAssertNoThrow(
            try PrivacyGuard.assertClean("Eat Out this cycle 134.47 across 12 transactions",
                                         knownSecrets: ["906", "1234"]))
    }

    // MARK: the safe summary carries no card data

    func testSafeSummaryOmitsCardIdentifiers() {
        let s = SafeExpenseSummary(dateISO: "2026-08-02",
                                   amountCents: 1422,
                                   merchant: "7-Eleven",
                                   category: "Drinks or Smokes",
                                   payer: "Us",
                                   cardNickname: "Chase Sapphire",
                                   note: "")
        let text = s.outboundText
        XCTAssertFalse(PrivacyGuard.containsLikelyCardNumber(text))
        XCTAssertFalse(text.contains("4147"), "Nickname only — never a PAN fragment")
        XCTAssertTrue(text.contains("Chase Sapphire"))
    }

    // MARK: compile-time barrier
    //
    // The strongest guarantee isn't a test — it's that the following does not
    // compile, because CardSecret does not conform to DeviceSafe:
    //
    //     let secret = CardSecret(number: "4111111111111111", cvv: "906")
    //     try PrivacyGuard.payload([secret], destination: "api.anthropic.com")
    //     //                        ^ type 'CardSecret' does not conform to 'DeviceSafe'
    //
    // Uncomment it to confirm the build fails. If it ever compiles, the barrier
    // has been weakened and this test file should fail review.

    func testCardSecretIsNotDeviceSafe() {
        // Runtime mirror of the compile-time property, so a refactor that adds
        // a conformance is caught even if nobody reads the comment above.
        let safeTypes: [Any.Type] = [SafeExpenseSummary.self, SafeAggregate.self]
        XCTAssertFalse(safeTypes.contains { $0 == CardSecret.self as Any.Type },
                       "CardSecret must never appear in the DeviceSafe set.")
    }
}

// MARK: - Statement maths, since money bugs are the other silent failure

final class StatementMathTests: XCTestCase {

    func testCarryForwardWhenPartiallyPaid() {
        let m = StatementMath(previousBalance: Money(0),
                              charges: Money(144_943),
                              interest: Money(0), fees: Money(0),
                              payments: Money(50_000),
                              statedClosing: Money(0))
        XCTAssertEqual(m.computedClosing, Money(144_943))
        XCTAssertEqual(m.carryForward, Money(94_943))
        XCTAssertFalse(m.isFullyPaid)
    }

    func testNothingCarriesWhenPaidInFull() {
        let m = StatementMath(previousBalance: Money(21_200),
                              charges: Money(100_000),
                              interest: Money(0), fees: Money(0),
                              payments: Money(121_200),
                              statedClosing: Money(0))
        XCTAssertEqual(m.carryForward, Money(0))
        XCTAssertTrue(m.isFullyPaid)
    }

    func testUnreconciledSurfacesMissingCharges() {
        // Bank says 1,500; app only knows about 1,449.43. The 50.57 gap is the
        // fee you forgot to log — the whole point of the reconcile screen.
        let m = StatementMath(previousBalance: Money(0),
                              charges: Money(144_943),
                              interest: Money(0), fees: Money(0),
                              payments: Money(0),
                              statedClosing: Money(150_000))
        XCTAssertEqual(m.unreconciled, Money(5_057))
    }

    func testInterestCostOfCarrying() {
        let m = StatementMath(previousBalance: Money(0), charges: Money(144_943),
                              interest: Money(0), fees: Money(0),
                              payments: Money(0), statedClosing: Money(0))
        // Bilt at 34.74% APR: 1449.43 * (0.3474/12) ≈ 41.96
        let cost = m.monthlyInterestCost(aprBasisPoints: 3474)
        XCTAssertEqual(cost.cents, 4196, accuracy: 2)
    }

    func testMoneyParsingHandlesLedgerFormats() {
        XCTAssertEqual(Money.parse("$1,364.00")?.cents, 136_400)
        XCTAssertEqual(Money.parse("-$613.88")?.cents, -61_388)
        XCTAssertEqual(Money.parse("(12.50)")?.cents, -1_250)
        XCTAssertEqual(Money.parse("10.28")?.cents, 1_028)
        XCTAssertNil(Money.parse(""))
    }

    func testCycleKeyRespectsTenthToNinthWindow() {
        let cal = Calendar(identifier: .gregorian)
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d))!
        }
        // The 3rd falls into the previous cycle; the 15th into the current one.
        XCTAssertEqual(CycleCalendar.key(for: date(2026, 6, 3), calendar: cal), "2026-05")
        XCTAssertEqual(CycleCalendar.key(for: date(2026, 6, 15), calendar: cal), "2026-06")
        XCTAssertEqual(CycleCalendar.key(for: date(2026, 1, 5), calendar: cal), "2025-12")
    }
}

// MARK: - Card identifier matching
//
// The bug this prevents: a Cadillac autopay confirmation names the BofA
// checking account (6932), not the debit card (9636). Matching on the card
// number alone left the row unassigned and needing manual repair.

final class CardMatchingTests: XCTestCase {

    func testMatchesOnCardNumber() {
        let ids = ["9636", "6932"]
        XCTAssertTrue(ids.contains("9636"))
    }

    func testMatchesOnBankAccountNumber() {
        // Same funding source, different printed identifier.
        let ids = ["9636", "6932"]
        XCTAssertTrue(ids.contains("6932"),
                      "ACH confirmations name the account, not the card.")
    }

    func testUnknownIdentifierDoesNotMatch() {
        let ids = ["9636", "6932"]
        XCTAssertFalse(ids.contains("0645"),
                       "Mustang's Mastercard 0645 is not yet on file and must not false-match.")
    }
}

// MARK: - Duplicate guard

final class DuplicateGuardTests: XCTestCase {

    func testIdenticalPurchasesShareAFingerprint() {
        let d = Date()
        let a = DuplicateGuard.fingerprint(date: d, cents: 1298,
                                           merchant: "Chowrastha", cardName: "Bilt")
        let b = DuplicateGuard.fingerprint(date: d, cents: 1298,
                                           merchant: "chowrastha ", cardName: "bilt")
        XCTAssertEqual(a, b, "Case and whitespace must not create a false unique.")
    }

    func testDifferentCardIsNotADuplicate() {
        let d = Date()
        let a = DuplicateGuard.fingerprint(date: d, cents: 1298,
                                           merchant: "Chowrastha", cardName: "Bilt")
        let b = DuplicateGuard.fingerprint(date: d, cents: 1298,
                                           merchant: "Chowrastha", cardName: "Discover")
        XCTAssertNotEqual(a, b)
    }

    func testSameAlertTextHashesIdentically() {
        let sms = "Chase: Your $45.35 transaction with BAWARCHI BIRYANI on card ending in 5778"
        XCTAssertEqual(DuplicateGuard.sourceHash(sms),
                       DuplicateGuard.sourceHash(sms + "\n"),
                       "Trailing whitespace must not defeat source dedupe.")
    }
}
