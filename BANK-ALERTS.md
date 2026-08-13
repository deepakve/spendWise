# Automatic logging from bank alerts

Chase, Amex, Discover, Citi and Bank of America all send a text or email for
every purchase. This turns those into ledger entries without you doing anything.

## What is and isn't possible

**iOS does not let one app read another app's notifications.** There is no API
for it — Android has one, iOS never has. So the app cannot watch your Chase
push alert.

It *can* read the SMS or email Chase sends for the same transaction, because
Shortcuts has Message and Email automation triggers that can run without asking
for confirmation. The chain:

```
Chase texts you  →  Shortcuts automation matches the sender
                 →  passes the text to Ledger
                 →  expense logged, or flagged if anything was unclear
```

## Step 1 — turn on transaction alerts at the bank

**Chase:** app → Profile → Alerts → Account Alerts → *Purchases and
transactions* → set the threshold to **$0.01** so every purchase alerts, and
choose **Text** as the delivery method.

Do the same for the other cards you want covered. Note the exact sender number
each bank uses — you'll need it in step 3.

Typical senders: Chase `28107`, Amex `86509`, Discover `347268`,
Citi `692484`, Bank of America `39472`. Yours may differ; check a real alert.

## Step 2 — make sure the app knows the last 4 digits

The parser matches the card by the last four digits in the alert. Open
**Cards → each card → Edit card terms → Last 4 digits** and fill them in.

Without this the expense still logs, but lands in **Needs review** with no card
attached.

## Step 3 — build the automation

Shortcuts app → **Automation** tab → **+** → **Message**

- **Sender:** the bank's shortcode from step 1
- **Message Contains:** `transaction` (or `purchase` — check your alert wording)
- Tap **Next** → **New Blank Automation**

Add one action:

- **Log from bank alert** (under Ledger)
- Set *Alert text* to the **Shortcut Input** variable
- Leave *Ask me if unclear* **on**

Then turn **Ask Before Running off** so it fires silently.

Repeat per bank. If several banks use similar wording you can point them all at
one automation — the parser detects the issuer itself.

### Email instead of text

Same thing with the **Email** trigger: set *Sender* to the bank's address and
*Subject Contains* to something stable like `Transaction Alert`. Text is more
reliable because the format is shorter and more consistent.

## What it does with each alert

| Situation | What happens |
|---|---|
| Everything parsed | Logged silently. Siri confirms if you ran it manually |
| Card last-4 unknown | Logged, flagged, waiting in **Needs review** |
| Merchant unclear | Logged, flagged, with the original alert text attached |
| No amount found | **Nothing logged.** Tells you it couldn't read it |
| Declined transaction | **Nothing logged.** Declines aren't spend |
| Refund wording | Logged as a negative amount |

Anything flagged carries the full original alert in its notes, so you fix it
against the source rather than from memory three days later.

## Two things worth knowing

**Authorisations aren't final amounts.** Restaurants authorise before the tip
and gas stations pre-authorise a round number. Those alerts fire at the
pre-tip amount, so the reconcile screen will show a gap against the statement.
That gap is the tip — correct the expense when you reconcile.

**You'll get duplicates if you also log manually.** Pick one path per card. The
suggestion: let alerts handle the cards that send them, and use Back Tap or the
scanner for cash and the cards that don't.

---

# Bill payment emails (CoServ, Mustang, Cadillac)

Same idea as the card alerts, but using the **Email** trigger instead of
Message, and with the biller fixed rather than parsed.

**Why fixed:** these emails reliably state the amount but rarely name the biller
in a parseable way. CoServ's confirmation says only *"your recent payment of
$180.29"* — the word CoServ appears in the subject and the sender, never in a
position a parser can trust. Since one automation handles one sender, the
merchant is known already.

## One automation per biller

Shortcuts → **Automation** → **+** → **Email**

### CoServ

- **Sender:** `coserv@smarthub.coop`
- **Subject Contains:** `Payment has Posted`
- Action: **Log bill payment**
  - *Email text:* Shortcut Input
  - *Biller:* `CoServ`
  - *Card:* Bilt
  - *Category:* Utilities
  - *Use the total:* on

CoServ bills electricity and gas separately, so you will get **two emails on
the same morning** — e.g. $180.29 and $20.71 on 6 Aug 2026. Both are real. The
duplicate guard won't block them because the amounts differ.

### Mustang Special Utility District

- **Sender:** `noreply@municipalonlinepayments.com`
- **Subject Contains:** `Utility Billing`
- Action: **Log bill payment**
  - *Biller:* `Mustang Water` · *Card:* Bilt · *Category:* Utilities
  - *Use the total:* **on** — the total includes the $1.25 online payment fee.
    Turn it off if you'd rather log the $166.38 subtotal and leave the fee out.

Mustang's email is a **schedule notice**, not a confirmation — it says the
payment *will be processed* on the 15th. With *Only log if already paid* on
(the default), the intent refuses it and waits. That's deliberate: logging a
future payment puts a transaction in the ledger before the money moves.

### Cadillac Financial

- **Sender:** `speedpay.com` (covers both `noreply@` and
  `CadillacFinancial_noreply@`)
- **Subject Contains:** `Payment`
- Action: **Log bill payment**
  - *Biller:* `Cadillac Financial` · *Card:* BofA Debit · *Category:* Car

Note the account numbers in this email are the **loan** account (`*3153`) and
the **funding** account (`*6932`). The app matches on 6932 because BofA Debit
carries it in its *Bank account, last 4* field. If you add another biller that
pays from a different account, put that account's last four in the same field
on the relevant card.

## Safety

Every one of these goes through the duplicate guard using a hash of the email
text, so an automation firing twice — or you re-running it manually — cannot
create a second row.
