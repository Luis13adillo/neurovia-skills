# Commission Invariants

All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`.

---

## Data-level

### 1. Production config is in expected state [CRITICAL]
Not a violation check — a snapshot. Run first. Expected values per MEMORY.md (2026-03-23).
```sql
SELECT id, flat_rate, owner_percentage, is_active, apply_to_owner_cuts,
       earnings_alert_threshold, updated_at, updated_by
FROM walkin_fee_config LIMIT 1;
-- Expected: owner_percentage=30, flat_rate=40, earnings_alert_threshold=200,
--           apply_to_owner_cuts=false, is_active=true, exactly 1 row
```

### 2. Every cash service_transaction WITH AN ACTIVE FEE has a matching cash_fee_ledger row [CRITICAL]
Waived transactions are excluded: if `fee_settlement_status = 'waived'` at completion, no ledger row is expected — the 4 completion handlers only insert into `cash_fee_ledger` when the fee is actively owed.
```sql
SELECT st.id AS transaction_id, st.barber_id, st.service_amount,
       st.owner_fee_amount, st.fee_settlement_status, st.payment_method,
       st.service_completed_at
FROM service_transactions st
LEFT JOIN cash_fee_ledger cfl
       ON (cfl.queue_entry_id = st.queue_entry_id OR cfl.booking_id = st.booking_id)
      AND cfl.barber_id = st.barber_id
WHERE st.payment_method = 'cash'
  AND st.owner_fee_amount > 0
  AND st.fee_settlement_status IS DISTINCT FROM 'waived'
  AND cfl.id IS NULL;
-- Expected: 0 rows
```

### 3. Fee math checks out per transaction [CRITICAL]
`service_amount` should equal `owner_fee_amount + barber_net_amount` within rounding.
```sql
SELECT id, service_amount, owner_fee_amount, barber_net_amount,
       ROUND(service_amount - owner_fee_amount - barber_net_amount, 2) AS delta
FROM service_transactions
WHERE ABS(service_amount - owner_fee_amount - barber_net_amount) > 0.01;
-- Expected: 0 rows
```

### 4. Total math: service + tip = total [HIGH]
```sql
SELECT id, service_amount, tip_amount, total_amount,
       ROUND(total_amount - (service_amount + COALESCE(tip_amount, 0)), 2) AS delta
FROM service_transactions
WHERE ABS(total_amount - (service_amount + COALESCE(tip_amount, 0))) > 0.01;
-- Expected: 0 rows
```

### 5. daily_summaries.total_owner_fees matches sum of source transactions [HIGH]
```sql
WITH tx_totals AS (
  SELECT (service_completed_at AT TIME ZONE 'America/New_York')::date AS day,
         barber_id, location_id,
         SUM(owner_fee_amount) AS sum_owner_fees,
         SUM(barber_net_amount) AS sum_barber_net
  FROM service_transactions
  GROUP BY day, barber_id, location_id
)
SELECT ds.date, ds.barber_id, ds.location_id,
       tt.sum_owner_fees AS transactions_owner_fees,
       ds.total_owner_fees AS summary_owner_fees,
       tt.sum_barber_net AS transactions_barber_net,
       ds.total_barber_net AS summary_barber_net
FROM daily_summaries ds
JOIN tx_totals tt ON tt.day = ds.date
                  AND tt.barber_id = ds.barber_id
                  AND tt.location_id = ds.location_id
WHERE ABS(ds.total_owner_fees - tt.sum_owner_fees) > 0.01
   OR ABS(ds.total_barber_net - tt.sum_barber_net) > 0.01;
-- Expected: 0 rows
```

### 6. fee_settlement_status takes valid values [HIGH]
Valid values: `'pending' | 'cash_owed' | 'auto_split' | 'settled' | 'waived'`. `cash_owed` is set explicitly by the 4 completion handlers for cash payments (distinct from `pending` which is for card/link awaiting settlement or payout).
```sql
SELECT fee_settlement_status, COUNT(*) AS n
FROM service_transactions
WHERE fee_settlement_status IS NOT NULL
  AND fee_settlement_status NOT IN ('pending', 'cash_owed', 'auto_split', 'settled', 'waived')
GROUP BY fee_settlement_status;
-- Expected: 0 rows
```

### 7. cash_fee_ledger.status takes valid values [HIGH]
```sql
SELECT status, COUNT(*) AS n
FROM cash_fee_ledger
WHERE status NOT IN ('owed', 'settled', 'waived')
GROUP BY status;
-- Expected: 0 rows
```

### 8. Settled ledger entries have settled_by + settled_at [MEDIUM]
```sql
SELECT id, status, settled_by, settled_at
FROM cash_fee_ledger
WHERE status IN ('settled', 'waived')
  AND (settled_by IS NULL OR settled_at IS NULL);
-- Expected: 0 rows
```

### 9. Waived transactions have waived_by + waived_at [MEDIUM]
```sql
SELECT id, fee_settlement_status, waived_by, waived_at
FROM service_transactions
WHERE fee_settlement_status = 'waived'
  AND (waived_by IS NULL OR waived_at IS NULL);
-- Expected: 0 rows
```

### 10. barber_payouts have positive amount and valid method [HIGH]
```sql
SELECT id, barber_id, amount, payout_method
FROM barber_payouts
WHERE amount <= 0
   OR payout_method NOT IN ('venmo', 'zelle', 'cash', 'bank_transfer', 'other');
-- Expected: 0 rows
```

### 11. No overpayment per barber [HIGH]
Sum of payouts should not exceed sum of card/link gross earnings (service − fee + tip) that have actually been paid. Formula MUST match `/api/commission/payout` (route.ts lines 69-74): includes tip, requires `payment_status = 'paid'`, excludes Connect-routed transactions.
```sql
WITH earned AS (
  SELECT barber_id,
         SUM(service_amount - owner_fee_amount + COALESCE(tip_amount, 0)) AS total_earned
  FROM service_transactions
  WHERE payment_method IN ('card', 'link')
    AND fee_settlement_status IS DISTINCT FROM 'auto_split'
    AND payment_status = 'paid'
  GROUP BY barber_id
),
paid AS (
  SELECT barber_id, SUM(amount) AS total_paid
  FROM barber_payouts
  GROUP BY barber_id
)
SELECT p.barber_id,
       COALESCE(e.total_earned, 0) AS total_earned,
       p.total_paid,
       ROUND((p.total_paid - COALESCE(e.total_earned, 0))::numeric, 2) AS overpaid
FROM paid p
LEFT JOIN earned e ON e.barber_id = p.barber_id
WHERE p.total_paid > COALESCE(e.total_earned, 0) + 0.01;
-- Expected: 0 rows
```

### 12. Owner barber exempt from walk-in fees when config says so [HIGH]
If `walkin_fee_config.apply_to_owner_cuts = false`, no cash ledger entries should exist for the owner's walk-in transactions.
```sql
-- First check config
-- Then:
SELECT cfl.id, cfl.barber_id, cfl.fee_amount, cfl.created_at
FROM cash_fee_ledger cfl
JOIN walkin_fee_config cfg ON true
WHERE cfl.barber_id = 'b0010000-0000-0000-0000-000000000001'
  AND cfg.apply_to_owner_cuts = false
  AND cfl.status = 'owed';
-- Expected: 0 rows (if apply_to_owner_cuts=false, owner shouldn't owe cash fees on walk-ins)
```

### 12b. Connect-enabled barber has at least one auto_split txn [CRITICAL]
If any barber has `stripe_charges_enabled = true` with a valid `acct_1…` account AND recent card/link transactions, at least some of those transactions should be `auto_split`. If ALL are `pending`, the completion handlers bypassed `determinePaymentRouting()`. See query #17 in audit-queries.sql.
```sql
-- Full query in audit-queries.sql #17. Expected: 0 rows.
SELECT b.id, b.slug, COUNT(*) FILTER (WHERE st.fee_settlement_status = 'auto_split') AS auto_split_count
FROM barbers b
JOIN service_transactions st ON st.barber_id = b.id
 AND st.payment_method IN ('card','link')
 AND st.service_completed_at > now() - interval '30 days'
WHERE b.stripe_charges_enabled = true
  AND b.stripe_account_id LIKE 'acct_1%'
GROUP BY b.id, b.slug
HAVING COUNT(*) FILTER (WHERE st.fee_settlement_status = 'auto_split') = 0;
```

### 12c. Cash backlog per barber under threshold [MEDIUM]
Ledger A parallel to #12. Barbers whose unpaid cash fees (`cash_fee_ledger.status='owed'`) exceed `walkin_fee_config.earnings_alert_threshold` should trigger an owner alert. Currently no alert channel for this direction — flag as backlog. See query #19.

### 13. Stripe Connect consistency [MEDIUM]
```sql
-- Barbers with Connect should have auto_split on recent card transactions
SELECT b.id, b.slug, b.stripe_charges_enabled,
       COUNT(st.id) FILTER (WHERE st.fee_settlement_status = 'pending') AS pending_card_txns,
       COUNT(st.id) FILTER (WHERE st.fee_settlement_status = 'auto_split') AS auto_split_txns
FROM barbers b
LEFT JOIN service_transactions st
       ON st.barber_id = b.id
      AND st.payment_method IN ('card', 'link')
      AND st.service_completed_at > now() - interval '30 days'
WHERE b.stripe_charges_enabled = true
GROUP BY b.id, b.slug, b.stripe_charges_enabled
HAVING COUNT(st.id) FILTER (WHERE st.fee_settlement_status = 'pending') > 0;
-- Expected: 0 rows (recent card txns for Connect barbers should be auto_split, not pending)
```

---

## Code-level

### C1. `determinePaymentRouting()` is the single fee source [CRITICAL]
- File: `src/lib/stripe/connect-helpers.ts`
- Every fee calculation must go through this function.

### C2. Stripe webhook idempotency [CRITICAL]
- File: `src/app/api/webhooks/stripe/route.ts`
- Check `stripe_webhook_events.stripe_event_id` before processing. Table per migration 036.

### C3. Waive atomicity [HIGH]
- File: `src/app/api/commission/waive/route.ts`
- Updates source row + service_transactions + cash_fee_ledger in one logical operation.

### C4. Payout validation [HIGH]
- File: `src/app/api/commission/payout/route.ts`
- Rejects `amount <= 0`, rejects overpayment, creates `barber_payouts` row, optionally marks related transactions settled.

### C5. Cash ledger insert paths [CRITICAL]
NO trigger exists for auto-populating `cash_fee_ledger`. The planning doc and migration 041 comments imply one, but in production only `tr_referral_conversion` is on `service_transactions`. Cash ledger rows are inserted by app code in these 4 places — grep should find all 4:
```bash
grep -rn "from('cash_fee_ledger').insert\|from(\"cash_fee_ledger\").insert" src/app/api/
# Expected files:
#   src/app/api/queue/entry/[id]/route.ts
#   src/app/api/queue/complete/route.ts
#   src/app/api/bookings/[id]/route.ts
#   src/app/api/bookings/quick-complete/route.ts
```
Each insert is wrapped in try/catch and writes an `owner_alerts` row on failure — a silent failure = a missing ledger row that only query #1 can find.

### C7. Connect routing is actually invoked in completion paths [CRITICAL]
`determinePaymentRouting()` is the ONLY place that sets `fee_settlement_status = 'auto_split'`. The 4 completion handlers above must call it (or delegate to the Stripe checkout path) when `barber.stripe_charges_enabled = true` AND the payment method is `card` or `link`. Current production state: they do NOT call it, so ZERO `auto_split` rows exist.
```bash
grep -rn "determinePaymentRouting" src/app/api/
# Expected: called from queue/entry/[id]/route.ts, queue/complete/route.ts,
#           bookings/[id]/route.ts, bookings/quick-complete/route.ts,
#           payments/checkout/route.ts, payments/send-link/route.ts
# As of 2026-04-20: only checkout + send-link call it. The 4 completion handlers do not.
```

### C8. Tip values persist to service_transactions.tip_amount [HIGH]
`PaymentCollectionModal` collects tips. They must reach `service_transactions.tip_amount`. Verify each link in the chain:
```bash
# 1. Modal emits tip_amount in PATCH payload
grep -n "tip_amount" src/components/dashboard/PaymentCollectionModal.tsx
# 2. Queue/booking route accepts + writes tip_amount
grep -n "tip_amount" src/app/api/queue/entry/\[id\]/route.ts src/app/api/bookings/\[id\]/route.ts
# 3. Stripe metadata round-trips tip_amount
grep -n "tip_amount" src/app/api/payments/checkout/route.ts src/app/api/payments/send-link/route.ts src/app/api/webhooks/stripe/route.ts
```
Cross-check with SQL query #18 — if tip_rate_pct across all completed txns in the last 30 days is 0%, the pipeline is broken.

### C6. Rate config values are not hardcoded in code [HIGH]
- Grep: `grep -rn "0\.30\|30%\|flatRate\s*=\s*40" src/app/ src/lib/`
- All rates must read from `walkin_fee_config`, not be hardcoded.
