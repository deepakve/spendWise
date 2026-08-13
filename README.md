# Ledger

Private expense tracker for two people. SwiftUI + Core Data + CloudKit.
Statement reconciliation with carry-forward, a Face ID card vault, Shortcuts
support, and charts.

**Builds on iPad — no Mac required.**

---

## Build it today on your iPad Pro

Swift Playgrounds can build this and ship it to your iPhone through TestFlight.

1. **App Store → install Swift Playgrounds** (free) on the iPad
2. Get this folder onto the iPad (see *GitHub* below, or AirDrop the zip)
3. Swift Playgrounds → **Open** → select the `Ledger` folder. `Package.swift`
   makes it a runnable app project
4. Edit two lines in `Package.swift`:
   - `bundleIdentifier` → something unique, e.g. `com.yourname.ledger`
   - `teamIdentifier` → your Team ID from developer.apple.com → Membership
5. Tap **▶︎** to run it on the iPad and confirm it works
6. **⋯ → Upload to App Store Connect**. First time it signs you in and creates
   the app record
7. Safari → appstoreconnect.apple.com → TestFlight → add yourself and your wife
   as **internal testers**
8. Both of you install Apple's **TestFlight** app and tap the invite

Internal-tester builds skip App Review. Builds expire after 90 days, so
re-upload roughly quarterly — about two minutes each time.

### The one thing to check first

Swift Playgrounds exposes a limited set of capabilities. Face ID is declared in
`Package.swift` and works. **CloudKit may not be settable from Swift
Playgrounds** — if it isn't, the app still runs perfectly with everything stored
locally on each phone, and you switch sync on when the Mac arrives on the 24th
by opening this same folder in Xcode and ticking the iCloud box. No code
changes, no data migration; the store file is identical either way.

Honest sequencing: **working app on both phones this week**, shared sync either
this week or on the 24th depending on that one capability.

---

## Put it on GitHub

I can't push for you — I have no network access from this session, and I'd
rather not hold your GitHub credentials regardless. The repo is already
initialised with one commit, so it's two steps.

**From the iPad** (best option): install **Working Copy** from the App Store. A
full git client for iPad that integrates with Swift Playgrounds, so you can
commit and push as you edit.

1. Working Copy → **+** → **Link external directory** → point at the Ledger folder
2. Sign in to GitHub inside Working Copy
3. Create the repo and push

**From a browser:** github.com → New repository → **Ledger** → *Private* → then
"uploading an existing file" and drag the folder in.

**Make it private.** Not because the code is secret, but because a public repo
plus a bundle ID plus your name is more of a map to your finances than is
comfortable.

`.gitignore` already excludes certificates, provisioning profiles and build
artefacts.

---

## Shortcuts

Five intents ship with the app. All appear automatically in the Shortcuts app
under **Ledger**, and all work from Back Tap, Siri, widgets, NFC tags, and
location automations.

| Intent | Says | Ask Siri |
|---|---|---|
| **Log expense** | "Logged $12.98 at Chowrastha on Bilt." | "Log an expense in Ledger" |
| **Card total** | "Bilt this cycle: $1,449.43, plus $212 carried in." | "Card total in Ledger" |
| **Spend this cycle** | "Eat Out this cycle: $134.47." | "Spend this cycle in Ledger" |
| **Spend on person** | "Subha this cycle: $382.70." | "Spend on person in Ledger" |
| **Search spend** | "7 entries matching Bindu, totalling $94.12." | "Search spend in Ledger" |

**Card, Category and Who are typed pickers, not text boxes.** Shortcuts shows
your real card list, so dictation can never turn "Bilt" into "built" — the
problem that made the CSV version fragile.

### Recommended setup

- **Back Tap:** Settings → Accessibility → Touch → Back Tap → Triple Tap →
  **Log expense**
- **Lock Screen widget:** long-press the Lock Screen → Customise → Shortcuts →
  Log expense
- **Location automations:** Shortcuts → Automation → Leave → Costco (also
  Chowrastha, Home Depot, H-E-B, Nellis) → Run **Log expense** → Ask Before
  Running **off**
- **Bill reminders:** Automation → Time of Day → day before each due date →
  Run **Card total**

---

## Sharing with your wife

**You don't need to share a CSV file**, and I'd steer you away from it: two
people writing one file means whoever saves second wipes the other's entries,
with no way to merge afterwards.

CloudKit sharing does the same job properly. Settings → **Share this ledger** →
send her the link. She accepts once, and after that:

- Both phones read and write the same ledger
- **Offline edits queue locally and push when the device reconnects.** This is
  built into CloudKit, not something the app manages. Log a coffee in a
  basement; it lands on her phone when you resurface
- Changes appear on the other phone within seconds when both are online
- Neither sees the other's password, and you can revoke at any time

One caveat: if you both edit *the same expense* within a few seconds, last write
wins. Adding different expenses simultaneously is completely safe.

---

## Card details

Two storage modes, chosen in Settings.

**Device-only (default).** iOS Keychain, Face ID on every read,
`ThisDeviceOnly` so it never leaves the phone — not to iCloud, not into backups.
Maximum security; the trade is that your wife's phone won't have them, and
losing the device loses the numbers.

**Synced (opt-in).** Stored in the `vaultBlob` field, declared with
`allowsCloudEncryption`. CloudKit encrypts it with a key held in your Keychain,
so Apple stores ciphertext it cannot read, and it reaches your wife's phone
through the same share. Still behind Face ID in the app.

CVV storage is supported in both modes. The factual position, stated once:
number + expiry + CVV together are everything needed for an online purchase,
which is why card networks forbid merchants from storing CVV at all. Your
reasoning — that this stays in your own iCloud and goes to no third party — is
an accurate description of where the data lives. It's your data and your call;
the app does what you tell it.

---

## When the Mac arrives

Nothing changes. Open the same folder in Xcode — it reads `Package.swift`
natively. You gain the debugger, crash logs, and the full capabilities editor.
Code, data and CloudKit container are identical.

---

## What answers what

| You wanted | Where |
|---|---|
| Face ID / passcode to open | Automatic. Settings → grace period |
| Spend by card / category / person, any day | Overview tab, segmented control |
| Pick any cycle | Overview, top strip — 18 cycles back |
| What's on this card this month | Cards → card → Statements & payments |
| Add a bill I missed | Statement screen, or **+** anywhere |
| Browse and edit every record | Ledger tab, searchable |
| What accumulated this month | Statement → "Charges this cycle" |
| What should I pay | Statement → "You owe" |
| What carries forward | Statement → "Carries to next cycle", with interest cost |
| Due date, APR, cycle date per card | Cards → card → Terms |
| Card numbers | Cards → card → Secure details |
| Did I overspend? | Overview → "Last 6 cycles" |
| Track by voice | Shortcuts, above |

## Design notes

- **Money is integer cents everywhere.** A ledger that drifts a cent per
  thousand rows is one you stop trusting.
- **Two separate cycle concepts.** The global 10th-to-9th window drives
  reporting; each card's own statement day drives due dates. Collapsing them
  would silently move February spend into January.
- **The data model is built in code, not a `.xcdatamodeld`.** That's what lets
  the same project compile in Swift Playgrounds and Xcode.
- **Charges are computed, never stored.** Correcting an old expense
  automatically fixes every statement that contained it.
- **iCloud syncs, it doesn't back up.** A deletion propagates everywhere. Export
  a CSV every month or two.
