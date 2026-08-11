-- =============================================================================
-- Maguey Bulletproof Waitlist — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   waitlist columns: id, event_id, event_name, ticket_type, customer_name,
--     customer_email, customer_phone, quantity, status, created_at,
--     notified_at, converted_at, metadata.
--   status CHECK ∈ (waiting, notified, converted, cancelled).
--   quantity CHECK > 0.
--   FK: event_id → events(id) ON DELETE CASCADE.
--   email_queue.email_type includes 'waitlist_notification' since
--     migration 20260421110004.
--   orders columns: id, user_id, purchaser_email, purchaser_name, event_id,
--     subtotal, fees_total, total, payment_provider, payment_reference,
--     status, created_at, updated_at, metadata, promo_code_id, referral_code.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. HIGH — Stale 'waiting' entries (event already happened)
-- Customers waiting on events that have passed. Should be auto-cancelled by a
-- scheduled cleanup; if you see >0 here, that cleanup isn't running.
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT w.id, w.event_name, w.customer_email, w.created_at,
       e.event_date, e.event_time
FROM waitlist w
LEFT JOIN events e ON e.id = w.event_id
WHERE w.status = 'waiting'
  AND e.event_date IS NOT NULL
  AND (e.event_date::date) < (now()::date)
ORDER BY e.event_date DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Duplicate active waitlist entries
-- Same (event_name, customer_email) appearing more than once with status='waiting'.
-- isOnWaitlist() should prevent this. >0 rows means the dedupe was bypassed.
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT event_name, customer_email, count(*) AS dupe_count,
       array_agg(id ORDER BY created_at) AS row_ids
FROM waitlist
WHERE status = 'waiting'
GROUP BY event_name, customer_email
HAVING count(*) > 1
ORDER BY dupe_count DESC;


-- -----------------------------------------------------------------------------
-- 3. CRITICAL — 'notified' entries with no waitlist_notification email_queue row
-- Status was flipped but the email never enqueued (notify button race or
-- auto-detect path which doesn't enqueue email).
-- Expected: 0 rows for manually-notified entries; rows here may be from auto-detect.
-- -----------------------------------------------------------------------------
SELECT w.id, w.event_name, w.customer_email, w.notified_at
FROM waitlist w
WHERE w.status = 'notified'
  AND w.notified_at > now() - interval '30 days'
  AND NOT EXISTS (
    SELECT 1
    FROM email_queue eq
    WHERE eq.email_type = 'waitlist_notification'
      AND eq.recipient_email ILIKE w.customer_email
      AND eq.related_id::uuid = w.id
  )
ORDER BY w.notified_at DESC
LIMIT 100;


-- -----------------------------------------------------------------------------
-- 4. INFO — Conversion lag P50 / P95 (notified → converted)
-- How long does it take customers to act on a notification?
-- High lag = email subject/CTA needs improvement.
-- -----------------------------------------------------------------------------
SELECT
  count(*)                                                       AS converted_with_lag,
  ROUND(EXTRACT(EPOCH FROM percentile_cont(0.5)
    WITHIN GROUP (ORDER BY (converted_at - notified_at))) / 60, 1) AS p50_minutes,
  ROUND(EXTRACT(EPOCH FROM percentile_cont(0.95)
    WITHIN GROUP (ORDER BY (converted_at - notified_at))) / 60, 1) AS p95_minutes,
  MIN(converted_at - notified_at) AS fastest,
  MAX(converted_at - notified_at) AS slowest
FROM waitlist
WHERE status = 'converted'
  AND notified_at IS NOT NULL
  AND converted_at IS NOT NULL
  AND converted_at > now() - interval '90 days';


-- -----------------------------------------------------------------------------
-- 5. HIGH — Orphan waitlist entries (event was deleted)
-- ON DELETE CASCADE should clean these up automatically. Rows here mean a
-- migration was run with FK temporarily removed, or event_id was nulled.
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT w.id, w.event_name, w.customer_email, w.created_at
FROM waitlist w
LEFT JOIN events e ON e.id = w.event_id
WHERE w.event_id IS NOT NULL
  AND e.id IS NULL
ORDER BY w.created_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 6. CRITICAL — 'converted' entries with no matching paid order
-- Status flipped but no `orders` row exists for that customer + event.
-- Indicates the saga ran for a different reason (manual mark by owner) OR
-- the order was later refunded/cancelled and the waitlist row didn't follow.
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT w.id, w.event_name, w.customer_email, w.converted_at
FROM waitlist w
WHERE w.status = 'converted'
  AND w.converted_at > now() - interval '90 days'
  AND NOT EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.event_id = w.event_id
      AND o.purchaser_email ILIKE w.customer_email
      AND o.status IN ('paid', 'completed')
  )
ORDER BY w.converted_at DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 7. INFO — Quantity exceeds remaining inventory (auto-detect will skip)
-- Customers asking for more tickets than will ever be released in a single
-- batch. Useful to know before mass-notify; consider asking them to reduce
-- quantity or splitting their request.
-- -----------------------------------------------------------------------------
WITH inventory AS (
  SELECT tt.event_id, tt.name AS ticket_type_name,
         tt.total_inventory,
         (SELECT count(*) FROM tickets t
            WHERE t.ticket_type_id = tt.id
              AND t.status IN ('issued','used','scanned')) AS sold,
         GREATEST(tt.total_inventory - (
           SELECT count(*) FROM tickets t
            WHERE t.ticket_type_id = tt.id
              AND t.status IN ('issued','used','scanned')
         ), 0) AS available
  FROM ticket_types tt
)
SELECT w.id, w.event_name, w.customer_email, w.ticket_type, w.quantity,
       inv.available
FROM waitlist w
LEFT JOIN inventory inv
  ON inv.event_id = w.event_id
  AND inv.ticket_type_name = w.ticket_type
WHERE w.status = 'waiting'
  AND inv.available IS NOT NULL
  AND w.quantity > inv.available
ORDER BY w.event_name, w.created_at;


-- -----------------------------------------------------------------------------
-- 8. INFO — Conversion funnel by event (last 30 days)
-- Per-event signup → notify → conversion breakdown.
-- High waiting + low notify rate = owner forgot the dashboard.
-- High notify + low conversion = email body / CTA / timing issue.
-- -----------------------------------------------------------------------------
SELECT event_name,
       count(*) FILTER (WHERE status = 'waiting')   AS waiting,
       count(*) FILTER (WHERE status = 'notified')  AS notified,
       count(*) FILTER (WHERE status = 'converted') AS converted,
       count(*) FILTER (WHERE status = 'cancelled') AS cancelled,
       count(*)                                     AS total,
       ROUND(100.0 *
         count(*) FILTER (WHERE status = 'converted') /
         NULLIF(count(*) FILTER (WHERE status IN ('notified','converted')), 0),
         1
       ) AS conversion_rate_pct
FROM waitlist
WHERE created_at > now() - interval '30 days'
GROUP BY event_name
ORDER BY total DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 9. INFO — Customers on multiple event waitlists (potential VIPs)
-- Repeat demand signal. These are your most engaged future buyers.
-- -----------------------------------------------------------------------------
SELECT customer_email, customer_name,
       count(DISTINCT event_name) AS distinct_events,
       count(*) FILTER (WHERE status = 'converted') AS converted_count,
       array_agg(DISTINCT event_name ORDER BY event_name) AS events
FROM waitlist
GROUP BY customer_email, customer_name
HAVING count(DISTINCT event_name) >= 2
ORDER BY distinct_events DESC, converted_count DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 10. CRITICAL — RLS / policy sanity check
-- Confirm the three expected policies exist on the waitlist table.
-- Expected: 3 rows.
-- -----------------------------------------------------------------------------
SELECT polname, polpermissive,
       pg_get_expr(polqual, polrelid)        AS using_expr,
       pg_get_expr(polwithcheck, polrelid)   AS check_expr
FROM pg_policy
WHERE polrelid = 'public.waitlist'::regclass
ORDER BY polname;
-- Expected names:
--   "Anon can join waitlist"             (INSERT, anon)
--   "Owners manage waitlist"             (ALL, authenticated, owner JWT)
--   "Service role full access waitlist"  (ALL, service_role)
