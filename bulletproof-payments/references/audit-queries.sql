-- =============================================================================
-- Bulletproof Payments — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- Revenue-critical — NEVER modify to INSERT/UPDATE/DELETE.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. SCHEMA VERIFICATION — verify column names before trusting queries
-- -----------------------------------------------------------------------------
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('stripe_webhook_events', 'service_transactions',
                     'queue_entries', 'bookings')
  AND (column_name ILIKE '%stripe%' OR column_name ILIKE '%payment%' OR column_name ILIKE '%tip%')
ORDER BY table_name, column_name;


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — stripe_webhook_events idempotency intact
-- Expected: 0 rows (UNIQUE constraint should prevent this)
-- -----------------------------------------------------------------------------
SELECT stripe_event_id, COUNT(*) AS n
FROM stripe_webhook_events
GROUP BY stripe_event_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Duplicate stripe_payment_id across service_transactions
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT stripe_payment_id, COUNT(*) AS n, array_agg(id) AS transaction_ids
FROM service_transactions
WHERE stripe_payment_id IS NOT NULL
GROUP BY stripe_payment_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 3. HIGH — payment_method values valid across tables
-- Expected: 0 rows for all three
-- -----------------------------------------------------------------------------
-- service_transactions
SELECT 'service_transactions' AS source, payment_method, COUNT(*) AS n
FROM service_transactions
WHERE payment_method IS NOT NULL
  AND payment_method NOT IN ('cash', 'card', 'link')
GROUP BY payment_method

UNION ALL

-- queue_entries
SELECT 'queue_entries' AS source, payment_method, COUNT(*) AS n
FROM queue_entries
WHERE payment_method IS NOT NULL
  AND payment_method NOT IN ('cash', 'card', 'link')
GROUP BY payment_method

UNION ALL

-- bookings
SELECT 'bookings' AS source, payment_method, COUNT(*) AS n
FROM bookings
WHERE payment_method IS NOT NULL
  AND payment_method NOT IN ('cash', 'card', 'link')
GROUP BY payment_method;


-- -----------------------------------------------------------------------------
-- 4. HIGH — payment_status values valid
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT 'service_transactions' AS source, payment_status, COUNT(*) AS n
FROM service_transactions
WHERE payment_status IS NOT NULL
  AND payment_status NOT IN ('pending', 'paid', 'failed', 'refunded')
GROUP BY payment_status;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Stale pending payment statuses (Stripe webhook failure signal)
-- Expected: few/none
-- -----------------------------------------------------------------------------
SELECT id,
       service_completed_at,
       payment_method,
       payment_status,
       service_amount,
       stripe_payment_id
FROM service_transactions
WHERE payment_status = 'pending'
  AND payment_method IN ('card', 'link')
  AND service_completed_at < now() - interval '2 hours'
ORDER BY service_completed_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 6. MEDIUM — Sanity check on tip values
-- Expected: 0 rows (no negative tips, no tips > 2× service_amount)
-- -----------------------------------------------------------------------------
SELECT id, service_amount, tip_amount, total_amount, service_completed_at
FROM service_transactions
WHERE tip_amount < 0
   OR tip_amount > (service_amount * 2);


-- -----------------------------------------------------------------------------
-- 7. CRITICAL — total = service + tip (within rounding)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, service_amount, tip_amount, total_amount,
       ROUND((total_amount - (service_amount + COALESCE(tip_amount, 0)))::numeric, 2) AS delta
FROM service_transactions
WHERE ABS(total_amount - (service_amount + COALESCE(tip_amount, 0))) > 0.01;


-- -----------------------------------------------------------------------------
-- 8. HIGH — Refunded transactions without commission reversal
-- Expected: 0 rows (if refund handler is implemented correctly)
-- -----------------------------------------------------------------------------
SELECT st.id AS transaction_id,
       st.queue_entry_id,
       st.booking_id,
       st.payment_status,
       cfl.status AS ledger_status,
       cfl.fee_amount
FROM service_transactions st
LEFT JOIN cash_fee_ledger cfl
       ON (cfl.queue_entry_id = st.queue_entry_id OR cfl.booking_id = st.booking_id)
WHERE st.payment_status = 'refunded'
  AND cfl.status = 'owed'
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 9. HIGH — Paid card/link transactions without stripe_payment_id
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, service_completed_at, payment_method, payment_status, stripe_payment_id
FROM service_transactions
WHERE payment_method IN ('card', 'link')
  AND payment_status = 'paid'
  AND stripe_payment_id IS NULL
  AND service_completed_at > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 10. HIGH — Link payments without stripe_payment_link
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, service_completed_at, payment_method, stripe_payment_link, stripe_payment_id
FROM service_transactions
WHERE payment_method = 'link'
  AND stripe_payment_link IS NULL
  AND service_completed_at > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 11. MEDIUM — Cash transactions incorrectly have stripe_payment_id
-- Expected: 0 rows (cash = no Stripe)
-- -----------------------------------------------------------------------------
SELECT id, service_completed_at, payment_method, stripe_payment_id
FROM service_transactions
WHERE payment_method = 'cash'
  AND stripe_payment_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 12. MEDIUM — Recent webhook processing activity
-- -----------------------------------------------------------------------------
SELECT DATE_TRUNC('day', processed_at) AS day,
       COUNT(*) AS events
FROM stripe_webhook_events
WHERE processed_at > now() - interval '30 days'
GROUP BY day
ORDER BY day DESC;


-- -----------------------------------------------------------------------------
-- 13. INFO — Payment method distribution (last 30 days)
-- -----------------------------------------------------------------------------
SELECT payment_method,
       COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       SUM(service_amount) AS total_service_revenue,
       SUM(tip_amount) AS total_tips
FROM service_transactions
WHERE service_completed_at > now() - interval '30 days'
GROUP BY payment_method
ORDER BY n DESC;


-- -----------------------------------------------------------------------------
-- 14. INFO — Refund rate (last 30 days)
-- -----------------------------------------------------------------------------
SELECT COUNT(*) FILTER (WHERE payment_status = 'refunded') AS refunds,
       COUNT(*) AS total,
       ROUND(100.0 * COUNT(*) FILTER (WHERE payment_status = 'refunded')
             / NULLIF(COUNT(*), 0), 2) AS refund_pct
FROM service_transactions
WHERE service_completed_at > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 15. INFO — Stripe Connect adoption
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) FILTER (WHERE stripe_account_id IS NOT NULL
                    AND stripe_charges_enabled = true) AS with_connect,
  COUNT(*) FILTER (WHERE stripe_account_id IS NULL
                    OR stripe_charges_enabled IS NOT TRUE) AS without_connect,
  COUNT(*) AS total_active
FROM barbers
WHERE is_active = true;


-- -----------------------------------------------------------------------------
-- 16. INFO — Most recent payment events (live pulse check)
-- -----------------------------------------------------------------------------
SELECT id, service_completed_at, payment_completed_at,
       payment_method, payment_status, service_amount, tip_amount,
       stripe_payment_id IS NOT NULL AS has_stripe_id
FROM service_transactions
ORDER BY service_completed_at DESC
LIMIT 20;
