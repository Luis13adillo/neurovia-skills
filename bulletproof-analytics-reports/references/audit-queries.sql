-- =============================================================================
-- Bulletproof Analytics & Reports — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- All date aggregation uses America/New_York timezone (Eastern).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- D1. CRITICAL — daily_summaries drift vs service_transactions (30 days)
-- Expected: 0 rows
-- Any row means update_daily_summary missed a write path — report is stale.
-- -----------------------------------------------------------------------------
WITH st_agg AS (
  SELECT
    (service_completed_at AT TIME ZONE 'America/New_York')::date AS d,
    barber_id,
    location_id,
    SUM(service_amount) AS st_revenue,
    SUM(tip_amount) AS st_tips,
    COUNT(*) AS st_cuts
  FROM service_transactions
  WHERE payment_status = 'paid'
    AND service_completed_at >= NOW() - INTERVAL '30 days'
  GROUP BY 1, 2, 3
)
SELECT
  ds.date,
  ds.barber_id,
  ds.location_id,
  ds.total_revenue AS ds_revenue,
  st.st_revenue,
  (ds.total_revenue - st.st_revenue) AS revenue_delta,
  ds.total_tips AS ds_tips,
  st.st_tips,
  ds.total_cuts AS ds_cuts,
  st.st_cuts
FROM daily_summaries ds
JOIN st_agg st
  ON st.d = ds.date
  AND st.barber_id = ds.barber_id
  AND st.location_id = ds.location_id
WHERE (ds.total_revenue <> st.st_revenue
    OR ds.total_tips <> st.st_tips
    OR ds.total_cuts <> st.st_cuts)
ORDER BY ds.date DESC, ds.barber_id;


-- -----------------------------------------------------------------------------
-- D2. CRITICAL — Completed queue_entries missing service_transactions row (30d)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT qe.id, qe.client_name, qe.assigned_barber_id, qe.location_id, qe.end_time
FROM queue_entries qe
LEFT JOIN service_transactions st ON st.queue_entry_id = qe.id
WHERE qe.status = 'completed'
  AND qe.end_time >= NOW() - INTERVAL '30 days'
  AND st.id IS NULL
ORDER BY qe.end_time DESC;


-- -----------------------------------------------------------------------------
-- D3. CRITICAL — Completed bookings missing service_transactions row (30d)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id, b.client_name, b.barber_id, b.scheduled_date, b.scheduled_time
FROM bookings b
LEFT JOIN service_transactions st ON st.booking_id = b.id
WHERE b.status = 'completed'
  AND b.deleted_at IS NULL
  AND b.scheduled_date >= CURRENT_DATE - INTERVAL '30 days'
  AND st.id IS NULL
ORDER BY b.scheduled_date DESC;


-- -----------------------------------------------------------------------------
-- D4. HIGH — Orphan service_transactions (FK to missing barber/location)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT st.id, st.barber_id, st.location_id, st.service_completed_at,
       st.service_amount, st.payment_status
FROM service_transactions st
LEFT JOIN barbers b ON b.id = st.barber_id
LEFT JOIN locations l ON l.id = st.location_id
WHERE b.id IS NULL OR l.id IS NULL;


-- -----------------------------------------------------------------------------
-- D5. HIGH — daily_summaries referencing deleted barber/location
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT ds.id, ds.date, ds.barber_id, ds.location_id, ds.total_revenue
FROM daily_summaries ds
LEFT JOIN barbers b ON b.id = ds.barber_id
LEFT JOIN locations l ON l.id = ds.location_id
WHERE b.id IS NULL OR l.id IS NULL;


-- -----------------------------------------------------------------------------
-- D6. CRITICAL — Commission fee totals reconcile (30 days)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH st_fees AS (
  SELECT
    (service_completed_at AT TIME ZONE 'America/New_York')::date AS d,
    SUM(owner_fee_amount) AS total
  FROM service_transactions
  WHERE service_completed_at >= NOW() - INTERVAL '30 days'
    AND payment_status = 'paid'
  GROUP BY 1
),
ds_fees AS (
  SELECT date AS d, SUM(total_owner_fees) AS total
  FROM daily_summaries
  WHERE date >= CURRENT_DATE - INTERVAL '30 days'
  GROUP BY 1
)
SELECT
  COALESCE(s.d, d.d) AS date,
  s.total AS st_fees,
  d.total AS ds_fees,
  COALESCE(s.total, 0) - COALESCE(d.total, 0) AS fee_delta
FROM st_fees s
FULL OUTER JOIN ds_fees d ON d.d = s.d
WHERE COALESCE(s.total, 0) <> COALESCE(d.total, 0)
ORDER BY date DESC;


-- -----------------------------------------------------------------------------
-- D7. CRITICAL — Duplicate service_transactions per queue_entry or booking
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT 'queue_entry' AS source, queue_entry_id::text AS id, COUNT(*) AS n
FROM service_transactions
WHERE queue_entry_id IS NOT NULL
GROUP BY queue_entry_id
HAVING COUNT(*) > 1
UNION ALL
SELECT 'booking' AS source, booking_id::text, COUNT(*)
FROM service_transactions
WHERE booking_id IS NOT NULL
GROUP BY booking_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- D8. HIGH — service_transactions with NULL service_completed_at
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, barber_id, location_id, payment_status, service_amount, payment_completed_at
FROM service_transactions
WHERE service_completed_at IS NULL
ORDER BY payment_completed_at DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- D9. MEDIUM — service_transactions index coverage
-- Expected: indexes on service_completed_at (alone and combined with barber_id/location_id)
-- -----------------------------------------------------------------------------
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'service_transactions'
ORDER BY indexname;


-- -----------------------------------------------------------------------------
-- D10. HIGH — daily_summaries UNIQUE(date, barber_id, location_id)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT date, barber_id, location_id, COUNT(*) AS n
FROM daily_summaries
GROUP BY date, barber_id, location_id
HAVING COUNT(*) > 1
ORDER BY date DESC;


-- -----------------------------------------------------------------------------
-- D11. HIGH — Home-summary vs reports reconciliation (today)
-- Expected: identical values across both result rows
-- -----------------------------------------------------------------------------
SELECT 'service_transactions' AS source,
       SUM(service_amount) AS revenue,
       SUM(tip_amount) AS tips,
       COUNT(*) AS cuts
FROM service_transactions
WHERE (service_completed_at AT TIME ZONE 'America/New_York')::date = CURRENT_DATE
  AND payment_status = 'paid'
UNION ALL
SELECT 'daily_summaries' AS source,
       SUM(total_revenue),
       SUM(total_tips),
       SUM(total_cuts)::bigint
FROM daily_summaries
WHERE date = CURRENT_DATE;


-- -----------------------------------------------------------------------------
-- D12. MEDIUM — Activity feed source table index coverage
-- Expected: at least one index per (timestamp, filter) pair
-- -----------------------------------------------------------------------------
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE tablename IN ('queue_entries', 'bookings', 'service_transactions')
  AND indexdef ~* '(check_in_time|end_time|scheduled_date|service_completed_at|created_at)'
ORDER BY tablename, indexname;


-- =============================================================================
-- RECONCILE — single-day deep walk-through
-- Parameterize: replace :target_date with the date in question (default CURRENT_DATE)
-- =============================================================================


-- R1. Service transactions that day, per barber
SELECT
  b.slug,
  p.first_name,
  st.barber_id,
  st.location_id,
  COUNT(*) AS cuts,
  SUM(st.service_amount) AS revenue,
  SUM(st.tip_amount) AS tips,
  SUM(st.total_amount) AS gross,
  SUM(st.owner_fee_amount) AS fees,
  SUM(st.barber_net_amount) AS net
FROM service_transactions st
JOIN barbers b ON b.id = st.barber_id
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE (st.service_completed_at AT TIME ZONE 'America/New_York')::date = CURRENT_DATE
  AND st.payment_status = 'paid'
GROUP BY b.slug, p.first_name, st.barber_id, st.location_id
ORDER BY revenue DESC;


-- R2. daily_summaries that day, per barber (what the home page / cached reports see)
SELECT
  b.slug,
  p.first_name,
  ds.barber_id,
  ds.location_id,
  ds.total_cuts,
  ds.total_revenue,
  ds.total_tips,
  ds.cash_amount,
  ds.card_amount,
  ds.link_amount,
  ds.total_owner_fees,
  ds.total_barber_net
FROM daily_summaries ds
JOIN barbers b ON b.id = ds.barber_id
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE ds.date = CURRENT_DATE
ORDER BY ds.total_revenue DESC;


-- R3. Completed queue entries that day (source records that SHOULD have produced service_transactions)
SELECT qe.id, qe.client_name, qe.assigned_barber_id, qe.location_id,
       qe.end_time, qe.total_amount, qe.payment_status,
       CASE WHEN st.id IS NULL THEN 'MISSING' ELSE 'OK' END AS txn_status
FROM queue_entries qe
LEFT JOIN service_transactions st ON st.queue_entry_id = qe.id
WHERE qe.status = 'completed'
  AND (qe.end_time AT TIME ZONE 'America/New_York')::date = CURRENT_DATE
ORDER BY qe.end_time DESC;


-- R4. Completed bookings that day (same)
SELECT b.id, b.client_name, b.barber_id, b.location_id,
       b.scheduled_date, b.scheduled_time, b.total_amount, b.payment_status,
       CASE WHEN st.id IS NULL THEN 'MISSING' ELSE 'OK' END AS txn_status
FROM bookings b
LEFT JOIN service_transactions st ON st.booking_id = b.id
WHERE b.status = 'completed'
  AND b.deleted_at IS NULL
  AND b.scheduled_date = CURRENT_DATE
ORDER BY b.scheduled_time DESC;


-- R5. Activity feed preview — what /api/activity-feed SHOULD return (limit 15)
-- Merges the 3 source queries the endpoint runs in parallel.
WITH queue_events AS (
  SELECT check_in_time AS ts, 'queue_join' AS event_type,
         client_name AS title, location_id
  FROM queue_entries
  WHERE check_in_time >= NOW() - INTERVAL '24 hours'
),
booking_events AS (
  SELECT created_at AS ts, 'booking_created' AS event_type,
         client_name AS title, location_id
  FROM bookings
  WHERE created_at >= NOW() - INTERVAL '24 hours'
    AND deleted_at IS NULL
),
payment_events AS (
  SELECT service_completed_at AS ts, 'service_completed' AS event_type,
         client_name AS title, location_id
  FROM service_transactions
  WHERE service_completed_at >= NOW() - INTERVAL '24 hours'
    AND payment_status = 'paid'
)
SELECT * FROM (
  SELECT * FROM queue_events
  UNION ALL SELECT * FROM booking_events
  UNION ALL SELECT * FROM payment_events
) merged
ORDER BY ts DESC
LIMIT 15;


-- =============================================================================
-- SCALE — ready-for-5th-location checklist
-- =============================================================================


-- S1. Per-location volume distribution (30 days)
-- Identifies whether analytics aggregates are location-balanced at scale
SELECT l.name, l.slug,
       COUNT(*) AS transactions,
       SUM(st.service_amount) AS revenue,
       AVG(st.service_amount) AS avg_ticket
FROM service_transactions st
JOIN locations l ON l.id = st.location_id
WHERE st.service_completed_at >= NOW() - INTERVAL '30 days'
  AND st.payment_status = 'paid'
GROUP BY l.id, l.name, l.slug
ORDER BY revenue DESC;


-- S2. Per-barber volume distribution (30 days)
-- Identifies whether any per-barber loop at request time will dominate (N+1 risk)
SELECT b.slug, p.first_name,
       COUNT(*) AS transactions
FROM service_transactions st
JOIN barbers b ON b.id = st.barber_id
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE st.service_completed_at >= NOW() - INTERVAL '30 days'
  AND st.payment_status = 'paid'
GROUP BY b.slug, p.first_name
ORDER BY transactions DESC;


-- S3. 1-year daily bucket count (Recharts stress)
-- /dashboard/analytics?period=1y will render this many buckets
SELECT COUNT(DISTINCT (service_completed_at AT TIME ZONE 'America/New_York')::date) AS distinct_days
FROM service_transactions
WHERE service_completed_at >= NOW() - INTERVAL '1 year'
  AND payment_status = 'paid';
