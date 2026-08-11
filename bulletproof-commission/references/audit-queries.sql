-- =============================================================================
-- Bulletproof Commission — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- Revenue-critical domain — NEVER modify these to INSERT/UPDATE/DELETE.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. INFO — Production config snapshot (always run first)
-- Expected: owner_percentage=30, flat_rate=40, earnings_alert_threshold=200,
--           apply_to_owner_cuts=false, is_active=true, exactly 1 row
-- -----------------------------------------------------------------------------
SELECT id, flat_rate, owner_percentage, is_active, apply_to_owner_cuts,
       earnings_alert_threshold, updated_at, updated_by
FROM walkin_fee_config LIMIT 1;


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Cash service_transactions missing matching cash_fee_ledger row
-- Exclude waived transactions: when a fee is waived at completion time, no ledger
-- row is expected (the 4 completion handlers only insert into cash_fee_ledger when
-- the fee is actively owed). Waived = intentional, not missing.
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT st.id AS transaction_id,
       st.barber_id,
       st.queue_entry_id,
       st.booking_id,
       st.service_amount,
       st.owner_fee_amount,
       st.fee_settlement_status,
       st.service_completed_at
FROM service_transactions st
LEFT JOIN cash_fee_ledger cfl
       ON (cfl.queue_entry_id = st.queue_entry_id OR cfl.booking_id = st.booking_id)
      AND cfl.barber_id = st.barber_id
WHERE st.payment_method = 'cash'
  AND st.owner_fee_amount > 0
  AND st.fee_settlement_status IS DISTINCT FROM 'waived'
  AND cfl.id IS NULL;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Fee math per transaction (service = owner_fee + barber_net ±0.01)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, service_amount, owner_fee_amount, barber_net_amount,
       ROUND((service_amount - owner_fee_amount - barber_net_amount)::numeric, 2) AS delta
FROM service_transactions
WHERE ABS(service_amount - owner_fee_amount - barber_net_amount) > 0.01;


-- -----------------------------------------------------------------------------
-- 3. HIGH — Total = service + tip (within rounding)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, service_amount, tip_amount, total_amount,
       ROUND((total_amount - (service_amount + COALESCE(tip_amount, 0)))::numeric, 2) AS delta
FROM service_transactions
WHERE ABS(total_amount - (service_amount + COALESCE(tip_amount, 0))) > 0.01;


-- -----------------------------------------------------------------------------
-- 4. HIGH — daily_summaries match sum of underlying transactions
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH tx_totals AS (
  SELECT (service_completed_at AT TIME ZONE 'America/New_York')::date AS day,
         barber_id, location_id,
         SUM(owner_fee_amount)  AS sum_owner_fees,
         SUM(barber_net_amount) AS sum_barber_net
  FROM service_transactions
  GROUP BY day, barber_id, location_id
)
SELECT ds.date, ds.barber_id, ds.location_id,
       tt.sum_owner_fees  AS transactions_owner_fees,
       ds.total_owner_fees AS summary_owner_fees,
       tt.sum_barber_net   AS transactions_barber_net,
       ds.total_barber_net AS summary_barber_net
FROM daily_summaries ds
JOIN tx_totals tt ON tt.day = ds.date
                  AND tt.barber_id = ds.barber_id
                  AND tt.location_id = ds.location_id
WHERE ABS(ds.total_owner_fees - tt.sum_owner_fees) > 0.01
   OR ABS(ds.total_barber_net - tt.sum_barber_net) > 0.01;


-- -----------------------------------------------------------------------------
-- 5. HIGH — fee_settlement_status values in valid enum
-- Valid values: 'pending' | 'cash_owed' | 'auto_split' | 'settled' | 'waived'
--   - 'cash_owed' is set for cash payments (distinct from 'pending' which is card/link awaiting settlement)
--   - 'auto_split' is set when Stripe Connect routing applied (barber got paid directly)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT fee_settlement_status, COUNT(*) AS n
FROM service_transactions
WHERE fee_settlement_status IS NOT NULL
  AND fee_settlement_status NOT IN ('pending', 'cash_owed', 'auto_split', 'settled', 'waived')
GROUP BY fee_settlement_status;


-- -----------------------------------------------------------------------------
-- 6. HIGH — cash_fee_ledger status values in valid enum
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT status, COUNT(*) AS n
FROM cash_fee_ledger
WHERE status NOT IN ('owed', 'settled', 'waived')
GROUP BY status;


-- -----------------------------------------------------------------------------
-- 7. MEDIUM — Settled / waived ledger rows missing settled_by or settled_at
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, status, settled_by, settled_at, created_at
FROM cash_fee_ledger
WHERE status IN ('settled', 'waived')
  AND (settled_by IS NULL OR settled_at IS NULL);


-- -----------------------------------------------------------------------------
-- 8. MEDIUM — Waived transactions missing waived_by / waived_at
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, fee_settlement_status, waived_by, waived_at
FROM service_transactions
WHERE fee_settlement_status = 'waived'
  AND (waived_by IS NULL OR waived_at IS NULL);


-- -----------------------------------------------------------------------------
-- 9. HIGH — barber_payouts invalid amount or method
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, barber_id, amount, payout_method, created_at
FROM barber_payouts
WHERE amount <= 0
   OR payout_method NOT IN ('venmo', 'zelle', 'cash', 'bank_transfer', 'other');


-- -----------------------------------------------------------------------------
-- 10. HIGH — Over-payout per barber (payouts exceed card/link gross earnings)
-- Formula must match /api/commission/payout line 69-74 and /api/commission/summary line 139-145:
--   gross = service_amount - owner_fee_amount + tip_amount
--   filters: payment_method IN ('card','link'), fee_settlement_status != 'auto_split', payment_status = 'paid'
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
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


-- -----------------------------------------------------------------------------
-- 11. HIGH — Owner barber exempt from walk-in fees when config says so
-- Expected: 0 rows (only if config.apply_to_owner_cuts = false)
-- Run query 0 first to confirm config.
-- -----------------------------------------------------------------------------
SELECT cfl.id, cfl.barber_id, cfl.fee_amount, cfl.status, cfl.created_at
FROM cash_fee_ledger cfl
WHERE cfl.barber_id = 'b0010000-0000-0000-0000-000000000001'
  AND cfl.status = 'owed'
  AND EXISTS (
    SELECT 1 FROM walkin_fee_config WHERE apply_to_owner_cuts = false
  );


-- -----------------------------------------------------------------------------
-- 12. MEDIUM — Stripe Connect barbers with recent card txns still pending
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id, b.slug, b.stripe_charges_enabled,
       COUNT(st.id) AS pending_card_txns_last_30d
FROM barbers b
JOIN service_transactions st
  ON st.barber_id = b.id
 AND st.payment_method IN ('card', 'link')
 AND st.fee_settlement_status = 'pending'
 AND st.service_completed_at > now() - interval '30 days'
WHERE b.stripe_charges_enabled = true
GROUP BY b.id, b.slug, b.stripe_charges_enabled
HAVING COUNT(st.id) > 0;


-- -----------------------------------------------------------------------------
-- 13. INFO — Card earnings owed to non-Connect barbers (payout queue)
-- This is the RECONCILIATION QUERY — it must produce numbers identical to what
-- /api/commission/summary returns for `by_barber[i].owed_to_barber`.
-- Owner-barber is force-zeroed in the endpoint, so it's excluded here too.
-- -----------------------------------------------------------------------------
WITH earned AS (
  SELECT st.barber_id,
         SUM(st.service_amount - st.owner_fee_amount + COALESCE(st.tip_amount, 0)) AS gross_earnings
  FROM service_transactions st
  WHERE st.payment_method IN ('card', 'link')
    AND st.fee_settlement_status IS DISTINCT FROM 'auto_split'
    AND st.payment_status = 'paid'
  GROUP BY st.barber_id
),
paid AS (
  SELECT barber_id, SUM(amount) AS total_paid
  FROM barber_payouts GROUP BY barber_id
)
SELECT b.id AS barber_id, b.slug,
       pr.first_name, pr.last_name,
       COALESCE(e.gross_earnings, 0) AS gross_earnings,
       COALESCE(p.total_paid, 0)     AS total_paid,
       GREATEST(0, COALESCE(e.gross_earnings, 0) - COALESCE(p.total_paid, 0)) AS owed_to_barber
FROM barbers b
LEFT JOIN profiles pr ON pr.id = b.profile_id
LEFT JOIN earned e    ON e.barber_id = b.id
LEFT JOIN paid p      ON p.barber_id = b.id
WHERE b.is_active = true
  AND COALESCE(b.stripe_charges_enabled, false) = false
  AND b.id <> 'b0010000-0000-0000-0000-000000000001'
ORDER BY owed_to_barber DESC;


-- -----------------------------------------------------------------------------
-- 13b. INFO — Unpaid card/link transactions (money not yet collected)
-- Shows completed services where the payment link hasn't been paid yet.
-- These DO NOT count toward "owed to barber" because shop hasn't received the money.
-- Useful for diagnosing "barber says I'm owed $X, dashboard shows $Y" — the gap
-- is often pending payment links.
-- -----------------------------------------------------------------------------
SELECT st.barber_id, b.slug,
       COUNT(*) AS unpaid_txn_count,
       SUM(st.service_amount - st.owner_fee_amount + COALESCE(st.tip_amount, 0)) AS unpaid_gross
FROM service_transactions st
LEFT JOIN barbers b ON b.id = st.barber_id
WHERE st.payment_method IN ('card', 'link')
  AND st.fee_settlement_status IS DISTINCT FROM 'auto_split'
  AND st.payment_status IS DISTINCT FROM 'paid'
  AND st.service_completed_at > now() - interval '30 days'
GROUP BY st.barber_id, b.slug
ORDER BY unpaid_gross DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 14. INFO — Outstanding cash fees per barber
-- -----------------------------------------------------------------------------
SELECT cfl.barber_id,
       b.slug,
       p.first_name,
       p.last_name,
       COUNT(*) AS owed_entries,
       SUM(cfl.fee_amount) AS total_owed
FROM cash_fee_ledger cfl
LEFT JOIN barbers b ON b.id = cfl.barber_id
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE cfl.status = 'owed'
GROUP BY cfl.barber_id, b.slug, p.first_name, p.last_name
ORDER BY total_owed DESC;


-- -----------------------------------------------------------------------------
-- 15. INFO — Today's commission math per location
-- -----------------------------------------------------------------------------
SELECT l.name AS location,
       COUNT(st.id) AS transactions,
       SUM(st.service_amount) AS service_revenue,
       SUM(st.owner_fee_amount) AS owner_fees,
       SUM(st.barber_net_amount) AS barber_net
FROM service_transactions st
JOIN locations l ON l.id = st.location_id
WHERE (st.service_completed_at AT TIME ZONE 'America/New_York')::date
      = (now() AT TIME ZONE 'America/New_York')::date
GROUP BY l.name
ORDER BY l.name;


-- -----------------------------------------------------------------------------
-- 16. INFO — Triggers on service_transactions
-- Expected: tr_referral_conversion (only). NO cash_fee_ledger trigger exists.
-- The cash ledger is populated by app-code INSERT from 4 API routes:
--   src/app/api/queue/entry/[id]/route.ts, queue/complete/route.ts,
--   bookings/[id]/route.ts, bookings/quick-complete/route.ts
-- -----------------------------------------------------------------------------
SELECT tgname, tgenabled, pg_get_triggerdef(oid) AS definition
FROM pg_trigger
WHERE tgrelid = 'service_transactions'::regclass
  AND NOT tgisinternal;


-- -----------------------------------------------------------------------------
-- 17. CRITICAL — Connect-enabled barbers whose recent txns never went through Connect
-- If a barber has stripe_charges_enabled=true AND a valid acct_1 stripe_account_id,
-- their card/link txns should be fee_settlement_status='auto_split'. If all recent
-- txns are 'pending' or 'cash_owed', the completion handler bypassed determinePaymentRouting().
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id, b.slug,
       b.stripe_account_id,
       COUNT(st.id) AS total_card_link_last_30d,
       COUNT(*) FILTER (WHERE st.fee_settlement_status = 'auto_split') AS auto_split_count,
       COUNT(*) FILTER (WHERE st.fee_settlement_status = 'pending') AS pending_count,
       SUM(st.service_amount - st.owner_fee_amount + COALESCE(st.tip_amount, 0))
         FILTER (WHERE st.fee_settlement_status IS DISTINCT FROM 'auto_split') AS unrouted_gross
FROM barbers b
JOIN service_transactions st
  ON st.barber_id = b.id
 AND st.payment_method IN ('card', 'link')
 AND st.service_completed_at > now() - interval '30 days'
WHERE b.stripe_charges_enabled = true
  AND b.stripe_account_id LIKE 'acct_1%'
  AND LENGTH(b.stripe_account_id) BETWEEN 18 AND 25
GROUP BY b.id, b.slug, b.stripe_account_id
HAVING COUNT(*) FILTER (WHERE st.fee_settlement_status = 'auto_split') = 0
ORDER BY unrouted_gross DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 18. HIGH — Tips are reaching service_transactions
-- PaymentCollectionModal collects tips; they must land in tip_amount.
-- If zero completed card/link txns in the last 30 days have tip_amount > 0,
-- the tip pipeline is broken somewhere between modal → PATCH/webhook → DB.
-- Also cross-checks queue_entries and bookings to narrow the failure point.
-- Expected: tip_rate > 0 for active shops
-- -----------------------------------------------------------------------------
SELECT 'service_transactions' AS source,
       COUNT(*) AS completed_last_30d,
       COUNT(*) FILTER (WHERE COALESCE(tip_amount, 0) > 0) AS with_tip,
       ROUND(100.0 * COUNT(*) FILTER (WHERE COALESCE(tip_amount, 0) > 0)
                   / NULLIF(COUNT(*), 0), 1) AS tip_rate_pct,
       COALESCE(SUM(tip_amount), 0) AS tip_sum
FROM service_transactions
WHERE service_completed_at > now() - interval '30 days'
  AND payment_method IN ('card', 'link', 'cash')
UNION ALL
SELECT 'queue_entries completed', COUNT(*),
       COUNT(*) FILTER (WHERE COALESCE(tip_amount, 0) > 0),
       ROUND(100.0 * COUNT(*) FILTER (WHERE COALESCE(tip_amount, 0) > 0)
                   / NULLIF(COUNT(*), 0), 1),
       COALESCE(SUM(tip_amount), 0)
FROM queue_entries
WHERE status = 'completed' AND end_time > now() - interval '30 days'
UNION ALL
SELECT 'bookings completed', COUNT(*),
       COUNT(*) FILTER (WHERE COALESCE(tip_amount, 0) > 0),
       ROUND(100.0 * COUNT(*) FILTER (WHERE COALESCE(tip_amount, 0) > 0)
                   / NULLIF(COUNT(*), 0), 1),
       COALESCE(SUM(tip_amount), 0)
FROM bookings
WHERE status = 'completed' AND scheduled_date > CURRENT_DATE - interval '30 days';


-- -----------------------------------------------------------------------------
-- 19. HIGH — Cash backlog per barber exceeds reporting threshold
-- Ledger A (barber owes shop). Parallels query #6 in scale-anti-patterns for Ledger B.
-- Uses walkin_fee_config.earnings_alert_threshold as the trigger ($200 in prod).
-- Flag barbers whose unpaid cash fees have grown past the threshold — owner should
-- be collecting, but no alert channel exists for this direction (unlike Ledger B).
-- -----------------------------------------------------------------------------
WITH cfg AS (SELECT earnings_alert_threshold AS threshold FROM walkin_fee_config LIMIT 1)
SELECT cfl.barber_id, b.slug,
       pr.first_name, pr.last_name,
       COUNT(*) AS owed_entries,
       SUM(cfl.fee_amount) AS total_owed,
       cfg.threshold
FROM cash_fee_ledger cfl
CROSS JOIN cfg
LEFT JOIN barbers b ON b.id = cfl.barber_id
LEFT JOIN profiles pr ON pr.id = b.profile_id
WHERE cfl.status = 'owed'
GROUP BY cfl.barber_id, b.slug, pr.first_name, pr.last_name, cfg.threshold
HAVING SUM(cfl.fee_amount) >= (SELECT threshold FROM cfg)
ORDER BY total_owed DESC;


-- -----------------------------------------------------------------------------
-- 20. INFO — Full payment-method × fee_settlement_status × has_connect matrix
-- One-glance view of how every transaction in the last 30 days was classified.
-- Healthy shop should show:
--   cash/cash_owed with owner_fee > 0
--   cash/waived only for owner's own walk-ins
--   card/auto_split when barber has Connect
--   card/pending | link/pending ONLY for non-Connect barbers
-- -----------------------------------------------------------------------------
SELECT
  st.payment_method,
  COALESCE(st.fee_settlement_status, '(null)') AS fee_settlement_status,
  CASE WHEN b.stripe_charges_enabled = true
            AND b.stripe_account_id LIKE 'acct_1%'
       THEN 'connect' ELSE 'no-connect' END AS barber_connect,
  COUNT(*) AS txn_count,
  SUM(st.service_amount) AS service_sum,
  SUM(st.owner_fee_amount) AS owner_fee_sum,
  SUM(st.barber_net_amount) AS barber_net_sum,
  SUM(COALESCE(st.tip_amount, 0)) AS tip_sum
FROM service_transactions st
LEFT JOIN barbers b ON b.id = st.barber_id
WHERE st.service_completed_at > now() - interval '30 days'
GROUP BY st.payment_method, st.fee_settlement_status, barber_connect
ORDER BY st.payment_method, barber_connect, st.fee_settlement_status;
