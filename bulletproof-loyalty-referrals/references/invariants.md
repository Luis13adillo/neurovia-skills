# Loyalty & Referrals Invariants

SELECT-only. **Verify schema first** — column names are a known drift risk in this domain.

---

## Data-level — Loyalty

### 1. loyalty_config has exactly 1 row [CRITICAL]
```sql
SELECT COUNT(*) AS n FROM loyalty_config;
-- Expected: 1
```

### 2. punches_required and reward_description set [HIGH]
```sql
SELECT id, punches_required, reward_description, is_active
FROM loyalty_config;
-- Expected: punches_required > 0, reward_description non-null, is_active = true
```

### 3. current_punches never exceeds total_punches_earned [HIGH]
```sql
SELECT client_phone, current_punches, total_punches_earned, rewards_redeemed
FROM customer_loyalty
WHERE current_punches > total_punches_earned;
-- Expected: 0 rows
```

### 4. rewards_redeemed is consistent with punches earned and redeemed [MEDIUM]
```sql
-- Rough invariant: total_punches_earned = current_punches + (rewards_redeemed * punches_required)
WITH cfg AS (SELECT punches_required FROM loyalty_config LIMIT 1)
SELECT cl.client_phone,
       cl.current_punches,
       cl.total_punches_earned,
       cl.rewards_redeemed,
       cfg.punches_required,
       cl.total_punches_earned - cl.current_punches - (cl.rewards_redeemed * cfg.punches_required) AS drift
FROM customer_loyalty cl
CROSS JOIN cfg
WHERE ABS(cl.total_punches_earned - cl.current_punches - (cl.rewards_redeemed * cfg.punches_required)) > 0
LIMIT 50;
-- Expected: 0 rows (minor drift may be OK during concurrent updates — investigate only if >1)
```

### 5. UNIQUE(client_phone) on customer_loyalty [HIGH]
```sql
SELECT client_phone, COUNT(*) AS n
FROM customer_loyalty
WHERE client_phone IS NOT NULL
GROUP BY client_phone
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 6. last_punch_at is within reason [LOW]
```sql
SELECT client_phone, current_punches, last_punch_at
FROM customer_loyalty
WHERE last_punch_at > now()
   OR last_punch_at < '2024-01-01';
-- Expected: 0 rows
```

---

## Data-level — Gift Cards

### 7. Gift card balance math [CRITICAL]
```sql
WITH redemptions AS (
  SELECT gift_card_id, SUM(amount) AS total_redeemed
  FROM gift_card_transactions
  WHERE transaction_type = 'redeem'
  GROUP BY gift_card_id
)
SELECT gc.id, gc.code, gc.initial_balance, gc.current_balance,
       COALESCE(r.total_redeemed, 0) AS redeemed_via_transactions,
       gc.initial_balance - COALESCE(r.total_redeemed, 0) AS expected_balance
FROM gift_cards gc
LEFT JOIN redemptions r ON r.gift_card_id = gc.id
WHERE ABS((gc.initial_balance - COALESCE(r.total_redeemed, 0)) - gc.current_balance) > 0.01
LIMIT 50;
-- Expected: 0 rows
```

### 8. Gift card status values valid [HIGH]
```sql
SELECT status, COUNT(*) AS n
FROM gift_cards
WHERE status NOT IN ('active', 'depleted', 'expired', 'cancelled')
GROUP BY status;
-- Expected: 0 rows
```

### 9. Depleted cards have zero balance [HIGH]
```sql
SELECT id, code, status, current_balance
FROM gift_cards
WHERE status = 'depleted'
  AND current_balance > 0.01;
-- Expected: 0 rows
```

### 10. Active cards have positive balance [MEDIUM]
```sql
SELECT id, code, status, current_balance
FROM gift_cards
WHERE status = 'active'
  AND current_balance <= 0;
-- Expected: 0 rows (should have transitioned to 'depleted')
```

### 11. Gift card codes unique [CRITICAL]
```sql
SELECT code, COUNT(*) AS n
FROM gift_cards
GROUP BY code
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 12. Transaction types valid [HIGH]
```sql
SELECT transaction_type, COUNT(*) AS n
FROM gift_card_transactions
WHERE transaction_type NOT IN ('purchase', 'redeem', 'refund')
GROUP BY transaction_type;
-- Expected: 0 rows
```

---

## Data-level — Referrals

### 13. Referral codes unique [CRITICAL]
```sql
SELECT code, COUNT(*) AS n
FROM barber_referrals
GROUP BY code
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 14. Referral counter math [HIGH]
Aggregate counters should match underlying events.
```sql
WITH event_counts AS (
  SELECT referral_id,
         COUNT(*) FILTER (WHERE event_type = 'click') AS clicks,
         COUNT(*) FILTER (WHERE event_type = 'visit') AS visits,
         COUNT(*) FILTER (WHERE event_type = 'conversion') AS conversions,
         SUM(service_amount) FILTER (WHERE event_type = 'conversion') AS revenue
  FROM referral_events
  GROUP BY referral_id
)
SELECT br.id, br.code,
       br.total_clicks, ec.clicks AS events_clicks,
       br.total_visits, ec.visits AS events_visits,
       br.total_conversions, ec.conversions AS events_conversions
FROM barber_referrals br
LEFT JOIN event_counts ec ON ec.referral_id = br.id
WHERE br.total_clicks != COALESCE(ec.clicks, 0)
   OR br.total_visits != COALESCE(ec.visits, 0)
   OR br.total_conversions != COALESCE(ec.conversions, 0)
LIMIT 50;
-- Expected: 0 rows
```

### 15. Referral event types valid [HIGH]
```sql
SELECT event_type, COUNT(*) AS n
FROM referral_events
WHERE event_type NOT IN ('click', 'visit', 'conversion')
GROUP BY event_type;
-- Expected: 0 rows
```

### 16. Referral referenced barber exists [HIGH]
```sql
SELECT br.id, br.barber_id
FROM barber_referrals br
LEFT JOIN barbers b ON b.id = br.barber_id
WHERE b.id IS NULL;
-- Expected: 0 rows
```

---

## Data-level — Upsells

### 17. Active upsell rules reference valid services [MEDIUM]
```sql
SELECT ur.id, ur.trigger_service_id, ur.suggested_service_id,
       ts.id AS trigger_exists,
       ss.id AS suggested_exists
FROM upsell_rules ur
LEFT JOIN services ts ON ts.id = ur.trigger_service_id
LEFT JOIN services ss ON ss.id = ur.suggested_service_id
WHERE ur.is_active = true
  AND (ts.id IS NULL OR ss.id IS NULL);
-- Expected: 0 rows
```

### 18. Discount percentages reasonable [LOW]
```sql
SELECT id, discount_percentage
FROM upsell_rules
WHERE discount_percentage < 0
   OR discount_percentage > 100;
-- Expected: 0 rows
```

---

## Code-level

### C1. Loyalty punch via RPC only [CRITICAL]
```bash
grep -rn "add_loyalty_punch\|UPDATE customer_loyalty" src/app/ src/lib/
```
Every increment path must use `add_loyalty_punch` RPC. No raw UPDATEs.

### C2. Reward redemption via RPC only [CRITICAL]
```bash
grep -rn "redeem_loyalty_reward" src/
```
Every redeem path uses the RPC.

### C3. Gift card redemption is atomic [CRITICAL]
- Both UPDATE `gift_cards.current_balance` AND INSERT `gift_card_transactions` row in one transaction.
- No code path does only one.

### C4. Referral events via `record_referral_event` RPC [HIGH]
```bash
grep -rn "record_referral_event\|UPDATE barber_referrals" src/
```
Counter updates happen only through the RPC.

### C5. Upsell filtering checks `is_active` [MEDIUM]
```bash
grep -rn "from('upsell_rules')" src/
```
Every query filters `is_active = true`.

### C6. PaymentCollectionModal respects `loyalty_reward_applied` [HIGH]
Read the component. When `loyalty_reward_applied = true`, the Stripe path should be skipped (service is comped).
