# Ledger — project handoff

**Read this first.** It's the entire context for this project, written so a fresh
Cowork session can pick up without being re-briefed.

Owner: Deepak (Dev) · Household of two: Dev and Subha
Last updated: 12 Aug 2026

---

## What this is

A private iOS expense tracker replacing a Numbers workbook. Built over several
sessions. Two people, ~20 credit cards, custom 10th-to-9th billing cycle.

**Hard constraints, do not violate:**

1. **No financial data leaves the device** except to the owner's own iCloud.
   Never add an LLM API call, analytics SDK, or any network destination.
   `PrivacyGuard.swift` enforces this at the type level and has tests. If a task
   seems to require calling out, stop and ask.
2. **Money is integer cents.** Never `Double`, never `Float`.
3. **The 10th-to-9th cycle** is the reporting month. A purchase on Jun 3 belongs
   to the May cycle. `CycleCalendar.key(for:)` is the only correct way to compute it.
4. **Per-card statement days are separate** from the reporting cycle. Never merge them.
5. **Nothing is logged silently when uncertain.** Flag it `needsReview` and ask.

---

## Current state

Working, ~7,100 lines of Swift, 25 files, one git repo with clean history.

| Area | Status |
|---|---|
| Core ledger, cards, statements, payments | Done |
| Statement reconcile with carry-forward | Done |
| Face ID app lock + card vault | Done |
| Shortcuts (6 App Intents) | Done |
| Receipt OCR (5/5 test receipts) | Done |
| Bank-alert parsing (6/6 issuer formats) | Done |
| Signup bonus tracker | Done |
| Recurring bills with autopay + history | Done |
| Budget vs actual, gift cards, privacy screen | Done |
| Widgets | **Code written, needs an Xcode target** |
| CloudKit sharing with Subha | Code written, **untested** |

**Not yet run on a device.** Everything is unverified against a real compiler.
Expect build errors on first attempt — that's the next job.

---

## Files

```
Ledger/Model/LedgerModel.swift      Core Data model, built in code (not .xcdatamodeld)
Ledger/Core/Persistence.swift       CloudKit stack, private + shared stores
Ledger/Core/Domain.swift            Money, Category, Payer, CycleCalendar
Ledger/Core/StatementEngine.swift   Balance maths and carry-forward
Ledger/Core/CardVault.swift         Keychain, biometric-gated
Ledger/Core/SecurePhoto.swift       AES-GCM encrypted card photos
Ledger/Core/SecureClipboard.swift   90s expiring clipboard, capture guard
Ledger/Core/PrivacyGuard.swift      The no-exfiltration barrier
Ledger/Core/NaturalQuery.swift      On-device query parser (NOT an LLM)
Ledger/Core/ReceiptScanner.swift    Vision OCR
Ledger/Core/AlertParser.swift       Bank SMS/email parsing
Ledger/Core/Recurring.swift         Autopay rules + notifications
Ledger/Core/DesignSystem.swift      Ink/Face/CardSkin tokens
Ledger/Views/                       11 SwiftUI screens
Ledger/Intents/LedgerIntents.swift  6 App Intents for Shortcuts
LedgerWidgets/                      3 widgets, needs its own target
Tests/PrivacyGuardTests.swift       Privacy + money + cycle tests
Ledger.csv                          539 rows of real history, validated
```

---

## Design language

Read `DesignSystem.swift` before touching any view. The concept is **"card on
receipt paper"**: vivid tactile card objects as the hero, everything else set
like a printed statement — monospaced tabular figures, dotted leaders, tracked
micro-labels. Serif (`Face.amount`) is used *only* for headline amounts.

Do not add emoji, gradients, or animation outside the two places that already
carry them (the card rail and the save stamp). The restraint is the design.

---

## Immediate next jobs, in order

1. **Make it build.** Open in Swift Playgrounds on iPad, or Xcode on the Mac
   (arriving ~24 Aug). Fix compile errors. Expect issues around: the
   programmatic `NSManagedObjectModel`, `CloudSharingView`, and the `share([])`
   call in `SettingsView.prepareShare()` which is a placeholder.
2. **Deploy CloudKit schema to Production** before Subha installs anything.
   Development-only schema is the classic "her app looks broken" cause.
3. **Widgets need a separate Xcode target** — Swift Playgrounds can't do this.
4. **Verify the 3 rows just added from Gmail** (see below).

## Open questions for Dev

- **Jun 3 2026, Cinemark, $11.90 — which card?** Blank in the original workbook.
  Only remaining unassigned row.
- **Mustang water $167.63 scheduled for 15 Aug** (subtotal $166.38 + $1.25 fee,
  Mastercard ending 0645 = Bilt). Deliberately NOT added — it hadn't been paid
  when this was written. Should appear via the email automation once it posts.
- **Sept 2025 spend ($853.66)** exists in the ledger but is missing from the
  workbook's monthly-by-category table.

## Important: what is and isn't automated

**Claude scraped Gmail manually in the chat session** that produced this project
— that was a one-off using a Gmail tool available in chat, NOT a feature.

**The app has no Gmail integration and should not get one.** Gmail API access
needs OAuth, Google's restricted-scope verification, and would mean the app
holding a token that can read all mail. It contradicts constraint #1.

The supported path is Shortcuts automations (see `BANK-ALERTS.md`): Message
triggers for card alerts, Email triggers for bill payments, both calling App
Intents. No credentials, no OAuth, nothing leaves the device.

## Three rows were added from Gmail on 12 Aug 2026

| Date | Merchant | Amount | Card |
|---|---|---|---|
| Aug 1 | Cadillac Financial | $740.00 | BofA Debit (ACH from acct *6932) |
| Aug 6 | CoServ | $180.29 | Bilt |
| Aug 6 | CoServ | $20.71 | Bilt |

Two CoServ charges the same morning is correct — electricity and gas are billed
separately.

---

## Working agreements

- **Verify, don't assert.** Every parser in this project was tested against real
  data before being called done. Keep that bar: write the test cases, run them,
  show the results.
- **Say when something can't be done.** Several features were cut because iOS
  genuinely doesn't allow them (reading other apps' notifications, writing to
  `.numbers` files). Don't invent workarounds that don't exist.
- **Dev's stated preferences:** wants things fast to capture, hates re-typing,
  reconciles card-total-against-statement first, searches by person's name in
  notes, and is willing to pay for tools but not to babysit them.
