# Commission Incident Registry

---

## Zero Production Data Contamination (2026-03-23) — THE RULE

**Incident:** During commission verification, test data was written to the production Supabase DB with test barber IDs. 190+ rows accumulated across 14 tables (daily_summaries, service_transactions, cash_fee_ledger, barber_payouts, clients, customer_loyalty, sms_logs, barber_notifications, owner_alerts, feedback, queue_entries, bookings, and more).

**Impact:**
- Owner dashboard reports showed fake revenue
- Commission totals were inflated
- Barber notifications fired for fake events
- Cleanup took manual SQL deletion across all affected tables

**Test barber IDs do NOT make writes safe.** Even inactive test barbers surface in:
- `daily_summaries` (appear in reports)
- `service_transactions` (appear in analytics)
- `cash_fee_ledger` (appear on commission dashboard)
- `barber_payouts` (appear in payout history)
- `clients` (appear in CRM)
- `sms_logs` (appear in comms analytics)

**The rule:**
1. NEVER INSERT / UPDATE / DELETE for "testing" purposes. Not with test IDs. Not temporarily. Not at all.
2. "Test this flow" = READ-ONLY verification. Read code, run SELECTs.
3. If writes are ever needed, STATE EXACTLY which tables and how many rows and WAIT for explicit approval.
4. If writes happened, clean immediately in the SAME session. Re-run audit queries across ALL tables until counts are 0.

**This rule is stronger than usual because commission data is revenue-facing.** A $0.30 test cash fee becomes a $0.30 line item a barber will see on their commission page.

**Files to read when this comes up:**
- `.claude/rules/debugging-protocol.md` Section 9 (full rule)
- MEMORY.md "ABSOLUTE RULE — Zero Production Data Contamination" entry

---

## Commission Amount Mismatch Between Dashboard and Ledger

**Symptom:**
- Owner commission page shows "Outstanding: $250"
- Sum of `cash_fee_ledger WHERE status='owed'` shows $225
- Discrepancy of $25 — where did it come from?

**Possible root causes:**
1. A waive happened but didn't propagate to all three tables (source, service_transactions, cash_fee_ledger)
2. A daily_summaries row got out of sync with its underlying transactions
3. A cash fee was recorded on `service_transactions` but the ledger trigger didn't fire (missing row)
4. An inline calculation somewhere bypassed `determinePaymentRouting()`

**Diagnose:**
1. Run audit query: cash transactions missing ledger rows.
2. Run audit query: daily_summaries totals vs service_transactions sums.
3. If a specific date is suspect, compare both sources for that date.
4. Check `src/app/api/commission/waive/route.ts` — did a recent waive miss a step?

**Do NOT fix by inserting into `cash_fee_ledger` directly.** The trigger should create those rows. If it didn't fire, the bug is in the trigger or the transaction insert path, not the ledger.

---

## Payout Recorded But Barber Reports Not Received

**Symptom:**
- Owner clicks "Pay Out $Y via Venmo" on commission dashboard
- `barber_payouts` row created, dashboard balance goes to zero
- Barber calls saying they never got the Venmo

**Root cause:**
- `barber_payouts` is an accounting record of "we paid X via method Y." It does NOT trigger the actual transfer. The owner still has to open Venmo/Zelle and send the money manually.
- If the owner forgot to do the actual transfer but clicked the button, the app thinks the barber is paid but no money moved.

**Correct expectation:**
Record-keeping only. This is by design — the app doesn't integrate with Venmo/Zelle APIs.

**Diagnose:**
1. Read `src/app/api/commission/payout/route.ts` — confirm it only records, doesn't transfer.
2. Check `barber_payouts.payout_method` and `created_at` for the disputed payout.
3. If the owner confirms they forgot to send the actual transfer, they need to: send the money via the platform, then no DB change needed.
4. If the owner insists they sent the money but barber denies: verify via the external platform's audit trail.

---

## Grace Period Shows Expired When It Shouldn't

**Symptom:**
- New barber was hired 10 days ago
- Barber dashboard shows "Grace period expired" and their booking fees are applied
- But CLAUDE.md / commission-system-spec.md says grace is 30 days

**Possible root causes:**
1. `barbers.grace_period_ends_at` is NULL or set to a past date
2. `determinePaymentRouting()` doesn't properly check grace status before applying fees
3. The "now" comparison uses UTC instead of Eastern (rare)

**Diagnose:**
1. Query: `SELECT id, slug, grace_period_ends_at, employment_type FROM barbers WHERE id = '...'`
2. If `grace_period_ends_at` is NULL, the grace was never set at barber creation. Check `src/app/api/auth/create-barber/route.ts` — does it set grace?
3. If date is past: was it set correctly at creation? Compare to `barbers.created_at`.
4. Read `determinePaymentRouting()` — verify grace check uses `now()` with proper TZ.

**Fix:** If grace was never set, the owner may need to manually update. This IS a write — requires explicit approval with exact barber ID and new date value.

---

## Stripe Connect Barber Still Shows Card Earnings Owed

**Symptom:**
- Barber completed Stripe Connect onboarding
- `barbers.stripe_account_id` is set, `stripe_charges_enabled = true`
- Commission dashboard still shows "Card Earnings Owed to You: $X"

**Root cause:**
- Old card payments (pre-Connect) are in `service_transactions` with `fee_settlement_status = 'pending'`. These accrued before Connect was enabled.
- Post-Connect transactions should have `fee_settlement_status = 'auto_split'`.

**Correct behavior:**
- Historical accruals remain owed until the owner does a final payout to zero them out.
- Once paid out, all rows move to settled.

**Diagnose:**
1. Run: `SELECT COUNT(*), SUM(barber_net_amount) FROM service_transactions WHERE barber_id = '...' AND payment_method IN ('card','link') AND fee_settlement_status = 'pending'`
2. If count > 0, those are pre-Connect accruals. Owner needs to do a final payout.
3. Verify `fee_settlement_status = 'auto_split'` on transactions AFTER the Connect enable date.

---

## Waive Didn't Propagate

**Symptom:**
- Owner clicks "Waive" on a cash transaction
- Transaction disappears from "Outstanding" tab
- But the barber still sees it owed on their personal page

**Root cause:**
`src/app/api/commission/waive/route.ts` must update ALL THREE:
1. The source row (queue_entries or bookings) — `fee_settlement_status = 'waived'`
2. `service_transactions` — `fee_settlement_status = 'waived'`, `waived_by`, `waived_at`
3. `cash_fee_ledger` — `status = 'waived'`, `settled_at`, `settled_by`, `notes`

If only one or two update, the UI shows inconsistent state.

**Diagnose:**
1. Read `src/app/api/commission/waive/route.ts`. Verify the three updates happen atomically.
2. If the waive happened recently, query the three tables for the affected IDs and confirm `fee_settlement_status` matches across all.
3. If mismatch: the waive endpoint has a bug. Report and wait for approval before fixing.

---

## Connect Routing Never Fires (2026-04-20 audit)

**Symptom:**
- Owner commission dashboard shows "Owed to Barber: $X" for a barber WITH Stripe Connect
- Same barber's own dashboard shows $0 owed
- SQL: 0 transactions in the entire table have `fee_settlement_status = 'auto_split'`

**Distinct from "Pre-Connect Accruals" incident above.** That incident is about HISTORICAL txns stuck in pending. This one is about NEW txns that should route through Connect but never do.

**Root cause:**
- `determinePaymentRouting()` in `src/lib/stripe/connect-helpers.ts` is the only code that sets `fee_settlement_status = 'auto_split'`
- It's ONLY called by `/api/payments/checkout` and `/api/payments/send-link` (Stripe-initiated flows)
- The 4 completion handlers (`queue/entry/[id]`, `queue/complete`, `bookings/[id]`, `bookings/quick-complete`) hardcode: `fee_settlement_status = payment_method === 'cash' ? 'cash_owed' : 'pending'`
- Result: a Connect barber completing a card/link txn through PATCH (not checkout) lands as `pending`, not `auto_split` → dashboard treats it as Ledger B (shop owes barber)
- Because `barber-summary` gates `earnings_owed` on `!hasStripeConnect`, the barber never sees this — but the owner does

**Diagnose:**
1. Run audit query #17 (Connect-enabled barbers with zero auto_split). Any row = this incident.
2. Grep: `grep -rn "determinePaymentRouting" src/app/api/`. If only checkout+send-link call it, Connect completions through PATCH are broken.
3. Check the specific txns: `SELECT fee_settlement_status FROM service_transactions WHERE barber_id='...' AND payment_method IN ('card','link')`. All `pending` + barber has Connect = this incident.

**Fix requires:** approval to modify the 4 completion handlers to call `determinePaymentRouting()` before setting `fee_settlement_status`. This is an "existing system" change — user approval mandatory per HARD RULE §8.

---

## Tips Collected but Not Persisted (2026-04-20 audit — UPDATED 2026-04-21)

**Symptom:**
- `PaymentCollectionModal` shows quick-tip buttons + custom input
- SQL: 0 rows across `service_transactions`, `queue_entries`, `bookings` have `tip_amount > 0`

**Impact:**
- Ledger B's "shop owes barber" under-reports by the full tip amount when tips ARE given but not recorded
- Barber tip cards + tip analytics show $0 everywhere

**Verified 2026-04-21:** The tip pipeline is ACTUALLY WIRED CORRECTLY:
- `PaymentCollectionModal.tsx` sends `tip_amount` in every PATCH payload (lines 116, 143, 158, 171, 196, 209, 525)
- `queueEntryStatusSchema` accepts `tip_amount` (schemas.ts line 54)
- `bookingsSchema` accepts `tip_amount` (bookings/[id]/route.ts line 67)
- Route handlers write `tip_amount` to `updates` when defined (queue/entry line 326-327, bookings/[id] line 152)
- Stripe checkout sets `metadata.tip_amount` (payments/checkout line 237)
- Webhook reads `metadata.tip_amount` and persists it (webhooks/stripe lines 202, 216, 254, 267)

**Conclusion: this is NOT a code bug.** The $0 tip rate across 249 transactions is a USAGE pattern — either barbers aren't entering tips in the modal, or customers at MT don't digitally tip (cash tips go directly to barber, off-record by design).

**If tips ever START appearing non-zero:** the pipeline is ready to catch them. No code fix required.

**If the owner WANTS to force tip entry:** that's a UX change (make tip entry mandatory in the modal before "Complete Service" button enables), not a data-pipeline fix.

**Audit signal changes:** Query #18 remains useful as a tip-usage canary, but should not be interpreted as a bug. If `tip_rate_pct > 0`, the pipeline is working.

---

## daily_summaries Drift vs service_transactions

**Symptom:**
- Owner home dashboard totals (which read `daily_summaries`) don't match commission dashboard totals for the same date
- `summary_barber_net` can be higher OR lower than the sum of underlying `service_transactions.barber_net_amount` for that (day, barber, location)

**Root cause:**
- `update_daily_summary(date, barber_id, location_id)` RPC (migration 011) aggregates from `queue_entries` and `bookings` directly — NOT from `service_transactions`
- It's fired by triggers on `queue_entries` / `bookings` INSERT/UPDATE
- `service_transactions` is populated by its own trigger (or by app code) from the same source rows
- If the two paths use different filters, or if the `service_transactions` row is inserted but the queue_entry trigger for `update_daily_summary` didn't re-run, the two diverge

**Diagnose:**
1. Run audit query #4. Which rows drift?
2. For a specific drift row, query `service_transactions` vs `queue_entries`+`bookings` for that (date, barber_id, location_id). The discrepancy shows which side is missing/extra.

**Fix requires:** approval. Typically reconciliation = make `update_daily_summary` read from `service_transactions` (the authoritative source) rather than the two source tables.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Any commission fix tempts you to write test data | STOP. Zero Contamination rule | MEMORY.md + debugging-protocol.md §9 |
| Dashboard totals differ from ledger sum | propagation gap or missing insert | `src/app/api/commission/waive/route.ts` + the 4 completion handlers |
| Payout recorded but barber not paid | design — recording only | `src/app/api/commission/payout/route.ts` |
| Grace expired prematurely | grace date never set at creation | `src/app/api/auth/create-barber/route.ts` |
| Connect barber still has card owed (historical) | pre-Connect accruals | SQL on service_transactions |
| Connect barber has NEW card txns stuck in pending | Connect routing never fires | audit query #17 + 4 completion handlers |
| Tip_amount always 0 everywhere | tip pipeline broken | audit query #18 + invariants C8 |
| Owner home dashboard ≠ commission dashboard on same date | daily_summaries drift | audit query #4 |
| Waive didn't propagate | waive endpoint bug | `src/app/api/commission/waive/route.ts` |
