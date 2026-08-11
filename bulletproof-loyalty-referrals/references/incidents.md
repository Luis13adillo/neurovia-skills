# Loyalty & Referrals Incident Registry

---

## Column Name Drift — `current_punches` vs `punches_count`

**Symptom (meta-incident):** CLAUDE.md documents `customer_loyalty.punches_count` / `rewards_earned` but the actual schema uses `current_punches` / `total_punches_earned`.

**Impact:** Any SQL query that assumes CLAUDE.md's column names fails at runtime. Initially caught by `bulletproof-queue`'s audit mode (query #17 referenced `punches_count`; the operator patched it to `current_punches`).

**Rule:** ALWAYS run the schema verification query in the SKILL.md preflight before trusting column names. If you see a query using `punches_count` or `rewards_earned` → it's wrong; fix to `current_punches` / `total_punches_earned`.

**This skill uses the correct names.** But if a newly-written skill or ad-hoc query uses the wrong names, flag it.

---

## Punch Race Condition

**Symptom:**
- Customer has 2 appointments on the same day (back-to-back services)
- Both service completions fire loyalty punch
- Customer's `current_punches` only increments by 1 (one update was lost)

**Root cause:**
Two concurrent `UPDATE customer_loyalty SET current_punches = current_punches + 1 WHERE phone = '...'` can race. PostgreSQL's MVCC reads the value at transaction start; if two txns start with value 5, both SET to 6, last-write-wins.

**Correct pattern:**
`add_loyalty_punch(phone)` RPC uses `SELECT ... FOR UPDATE` row lock to serialize. Atomic increment regardless of concurrency.

**Diagnose:**
1. Read the code path completing services. Does it call `add_loyalty_punch` RPC, or inline UPDATE?
2. `grep -rn "UPDATE customer_loyalty\|add_loyalty_punch" src/`
3. Any inline UPDATE is a race risk.

---

## Reward Redemption Without Punch Decrement

**Symptom:**
- Customer redeems free-cut reward
- Service completes, customer charged $0
- But `customer_loyalty.current_punches` still shows 10 (or whatever the threshold)
- Customer gets a second free cut on their next visit

**Root cause:**
Redeem flow did not decrement punches (or decrement happened in a separate transaction that failed).

**Correct pattern:**
`redeem_loyalty_reward(phone)` RPC does both atomically:
1. Verify `current_punches >= punches_required`.
2. Decrement `current_punches` by `punches_required`.
3. Increment `rewards_redeemed` by 1.
4. Return the updated row.

**Diagnose:**
1. Query the customer's row: `SELECT * FROM customer_loyalty WHERE phone = '...'`.
2. Compare `rewards_redeemed` count vs `total_punches_earned / punches_required` expected.
3. Check which code path called the redeem — RPC or inline?

---

## Gift Card Balance Drift

**Symptom:**
- Customer purchased gift card for $50
- Used it once for a $20 service (reports say balance should be $30)
- `gift_cards.current_balance` shows $40 or $50

**Root cause:**
Redemption did not create a `gift_card_transactions` row AND/OR did not decrement `current_balance`. Atomicity broken.

**Correct pattern:**
```sql
-- Redeem gift card atomically
BEGIN;
  UPDATE gift_cards
  SET current_balance = current_balance - $amount
  WHERE id = $gift_card_id
    AND current_balance >= $amount;

  INSERT INTO gift_card_transactions
    (gift_card_id, amount, transaction_type, queue_entry_id)
  VALUES ($gift_card_id, $amount, 'redeem', $queue_entry_id);
COMMIT;
```

**Diagnose:**
1. Query `gift_card_transactions WHERE gift_card_id = '...' ORDER BY created_at`.
2. Sum `amount` for `transaction_type = 'redeem'`. Compare to `initial_balance - current_balance`. Should match.
3. If mismatch → transaction logic broken OR manual balance edit happened (violates rule).

---

## Referral Conversion Not Tracked

**Symptom:**
- Barber's referral link was clicked
- Customer booked + completed service
- `barber_referrals.total_conversions` didn't increment
- Barber asks "why didn't I get credit?"

**Root cause chain to check:**
1. Did the referral `click` event fire? Check `referral_events WHERE event_type = 'click'`.
2. Did the referral code get attached to the booking? Usually via query param / cookie that persists to booking creation.
3. Did service completion trigger `record_referral_event('conversion')`?

**Correct pattern:**
- Click: URL has `?ref=CODE123` → `/api/referrals/track` logs the click in `referral_events` (event_type='click').
- Visit: if same customer returns within N days with `ref` cookie → log 'visit' event.
- Conversion: when a booking or queue completion is linked to the referral code → log 'conversion' event with service_amount and commission_earned.
- Each event triggers `barber_referrals` counter update.

**Diagnose:**
1. Was `ref` param present on the booking form URL?
2. `referral_events` rows for the customer phone — what events fired?
3. Was the conversion step called on service completion? Grep `record_referral_event`.

---

## Upsell Suggestion Wrong Service

**Symptom:**
- Customer books haircut
- Checkout shows "Add a beard trim? 10% off"
- But the rule is supposed to fire on combo haircut only

**Root cause:**
`upsell_rules.trigger_service_id` matches the wrong service, OR the upsell logic doesn't filter by trigger_service_id correctly.

**Diagnose:**
1. Query `upsell_rules WHERE is_active = true` — list all active rules.
2. Find the one that fired. What's its `trigger_service_id`?
3. Compare to the customer's selected service. Is there a mismatch?

---

## Double-Billed Reward Redemption

**Symptom:**
- Customer redeems free cut
- Service completes
- Customer is charged anyway (cash/card)

**Root cause:**
Redemption flagged `queue_entries.loyalty_reward_applied = true` but the payment flow didn't skip charging.

**Correct pattern:**
PaymentCollectionModal / service completion logic checks `loyalty_reward_applied`. If true:
- `service_amount` still recorded for analytics
- But `payment_status = 'paid'` without Stripe charge OR with $0 charge
- Barber knows it's a comp

**Diagnose:**
1. `SELECT id, loyalty_reward_applied, payment_method, payment_status, service_amount, stripe_payment_id FROM queue_entries WHERE ...`
2. If `loyalty_reward_applied = true` AND `stripe_payment_id IS NOT NULL` → customer was double-billed.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Punches don't increment | inline UPDATE race | grep for `UPDATE customer_loyalty` |
| Reward redeem didn't reset punches | non-atomic redeem path | grep for `redeem_loyalty_reward` |
| Gift card balance drift | transaction not atomic | gift card redeem code |
| Referral conversion missing | event chain broken somewhere | `referral_events` by customer |
| Wrong upsell fired | `trigger_service_id` mismatch | `upsell_rules` query |
| Customer charged + redeemed reward | payment flow didn't honor flag | `PaymentCollectionModal` |
