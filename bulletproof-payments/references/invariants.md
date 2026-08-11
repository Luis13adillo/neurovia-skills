# Payments Invariants

SELECT-only. **Verify schema first** via preflight.

---

## Data-level

### 1. stripe_webhook_events idempotency [CRITICAL]
```sql
SELECT stripe_event_id, COUNT(*) AS n
FROM stripe_webhook_events
GROUP BY stripe_event_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 2. No duplicate stripe_payment_id across service_transactions [CRITICAL]
```sql
SELECT stripe_payment_id, COUNT(*) AS n, array_agg(id) AS transaction_ids
FROM service_transactions
WHERE stripe_payment_id IS NOT NULL
GROUP BY stripe_payment_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 3. payment_method values valid [HIGH]
```sql
SELECT payment_method, COUNT(*) AS n
FROM service_transactions
WHERE payment_method IS NOT NULL
  AND payment_method NOT IN ('cash', 'card', 'link')
GROUP BY payment_method;
-- Expected: 0 rows
```

Repeat for `queue_entries` and `bookings`.

### 4. payment_status values valid [HIGH]
```sql
SELECT payment_status, COUNT(*) AS n
FROM service_transactions
WHERE payment_status IS NOT NULL
  AND payment_status NOT IN ('pending', 'paid', 'failed', 'refunded')
GROUP BY payment_status;
-- Expected: 0 rows
```

### 5. Completed transactions with pending payment status (spot-check) [HIGH]
```sql
SELECT id, service_completed_at, payment_method, payment_status, service_amount
FROM service_transactions
WHERE payment_status = 'pending'
  AND service_completed_at < now() - interval '24 hours'
LIMIT 50;
-- Expected: few/none. Stale pending likely means Stripe webhook failure.
```

### 6. Tip values are sane [MEDIUM]
```sql
SELECT id, service_amount, tip_amount, total_amount
FROM service_transactions
WHERE tip_amount < 0
   OR tip_amount > (service_amount * 2);
-- Expected: 0 rows (no negative tips; tips > 200% of service = likely data error)
```

### 7. Total = service + tip (within rounding) [CRITICAL]
Same as bulletproof-commission invariant #4 — repeated here because this skill also owns it.
```sql
SELECT id, service_amount, tip_amount, total_amount,
       ROUND((total_amount - (service_amount + COALESCE(tip_amount, 0)))::numeric, 2) AS delta
FROM service_transactions
WHERE ABS(total_amount - (service_amount + COALESCE(tip_amount, 0))) > 0.01;
-- Expected: 0 rows
```

### 8. Refunded transactions should have commission reversal [HIGH]
```sql
-- Transactions refunded but cash_fee_ledger still marks owed for that source
SELECT st.id AS transaction_id,
       st.queue_entry_id,
       st.booking_id,
       cfl.status AS ledger_status
FROM service_transactions st
LEFT JOIN cash_fee_ledger cfl
       ON (cfl.queue_entry_id = st.queue_entry_id OR cfl.booking_id = st.booking_id)
WHERE st.payment_status = 'refunded'
  AND cfl.status = 'owed'
LIMIT 50;
-- Expected: 0 rows
```

### 9. Stripe charges present in DB [HIGH]
This is a reverse-check — hard to do without Stripe API access. Spot-check instead:
```sql
-- Recent successful card transactions must have stripe_payment_id
SELECT id, service_completed_at, payment_method, payment_status, stripe_payment_id
FROM service_transactions
WHERE payment_method IN ('card', 'link')
  AND payment_status = 'paid'
  AND stripe_payment_id IS NULL
  AND service_completed_at > now() - interval '30 days';
-- Expected: 0 rows
```

### 10. Send-link transactions have stripe_payment_link [HIGH]
```sql
SELECT id, service_completed_at, payment_method, stripe_payment_link
FROM service_transactions
WHERE payment_method = 'link'
  AND stripe_payment_link IS NULL
  AND service_completed_at > now() - interval '30 days';
-- Expected: 0 rows
```

### 11. Cash transactions have NO stripe_payment_id [MEDIUM]
```sql
SELECT id, service_completed_at, payment_method, stripe_payment_id
FROM service_transactions
WHERE payment_method = 'cash'
  AND stripe_payment_id IS NOT NULL;
-- Expected: 0 rows (cash = no Stripe)
```

### 12. Webhook processing recency [MEDIUM]
```sql
SELECT MAX(processed_at) AS most_recent_webhook,
       MIN(processed_at) AS oldest_tracked,
       COUNT(*) AS total_events
FROM stripe_webhook_events;
-- most_recent_webhook should be within minutes of a live transaction
```

---

## Code-level

### C1. Stripe webhook signature verification [CRITICAL]
- `src/app/api/webhooks/stripe/route.ts`
- Uses `stripe.webhooks.constructEvent()` with `STRIPE_WEBHOOK_SECRET`.
- Returns 400 on signature failure.

### C2. Webhook idempotency check [CRITICAL]
- Same file. Before processing: check `stripe_webhook_events.stripe_event_id`.
- If exists → return 200 without re-processing. Else INSERT and process.

### C3. Checkout session creates metadata [HIGH]
- `src/app/api/payments/checkout/route.ts`
- Metadata must include `queue_entry_id` OR `booking_id`, `barber_id`, `location_id`.

### C4. Webhook handler uses metadata [HIGH]
- Same webhook file. On `checkout.session.completed`, pulls metadata to find source row.

### C5. Refund handler reverses commission [HIGH]
- On `charge.refunded`:
  - UPDATE service_transactions.payment_status = 'refunded'
  - UPDATE source (queue_entries or bookings) payment_status = 'refunded'
  - Handle cash_fee_ledger reversal (delete or waive)
- **This may not be fully implemented.** Flag to user if diagnose reveals a gap.

### C6. PaymentCollectionModal polling [MEDIUM]
- Component polls queue_entries.payment_status after Stripe redirect.
- Must time out gracefully after ~60s with a "Mark as paid manually?" fallback.

### C7. Env key separation [CRITICAL]
- `STRIPE_SECRET_KEY` server-side only.
- `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` is OK to be public.
- Production uses `sk_live_*`. Dev uses `sk_test_*`. Never mixed.
