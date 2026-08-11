-- =============================================================================
-- Maguey Bulletproof Dashboard — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- This skill is the DASHBOARD SHELL. These queries only catch things that
-- surface ON the dashboard as a visual anomaly. Deep domain audits (orders
-- integrity, event lifecycle, scan correctness) live in sibling skills.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   orders.total is numeric DOLLARS (confirmed via sample: $25–$950 range).
--   tickets.price is numeric DOLLARS. No price_cents on GA; VIP side uses cents.
--   orders.status is free-form text. Values observed: pending, paid, completed,
--     refunded. No CHECK constraint.
--   tickets.status is free-form text. current_status constrained to
--     inside|outside|left (scanner re-entry logic).
--   events.is_active (boolean NOT NULL), events.status (text nullable free-form).
--   ticket_types.total_inventory (int nullable) is the capacity source.
--     No is_active column.
--   scanner_heartbeats.is_online (boolean NOT NULL) is a stored column —
--     not derived. Staleness detection belongs to the scanner skill.
--   email_queue.status values: pending, processing, delivered, failed.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Orders marked 'completed' but with 0 tickets
-- Dashboard shows these in Recent Purchases with ticket_count=0, confusing.
-- Expected: 0 rows (completed order should have at least 1 ticket).
-- -----------------------------------------------------------------------------
SELECT o.id, o.purchaser_email, o.total, o.status, o.created_at
FROM orders o
LEFT JOIN tickets t ON t.order_id = o.id
WHERE o.status = 'completed'
GROUP BY o.id, o.purchaser_email, o.total, o.status, o.created_at
HAVING COUNT(t.id) = 0;


-- -----------------------------------------------------------------------------
-- 2. HIGH — orders.total sanity check
-- If min < 0 or max > 100000, investigate. A value > 100000 in a DOLLARS
-- column is almost certainly a row stored in cents (schema drift).
-- Expected: min >= 0, max reasonable (< $10k for a single nightclub order).
-- -----------------------------------------------------------------------------
SELECT
  MIN(total) AS min_total,
  MAX(total) AS max_total,
  AVG(total)::numeric(12,2) AS avg_total,
  COUNT(*) FILTER (WHERE total < 0) AS negative_rows,
  COUNT(*) FILTER (WHERE total > 100000) AS suspiciously_large_rows,
  COUNT(*) AS total_rows
FROM orders
WHERE total IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 3. MEDIUM — Upcoming events with NULL or empty name
-- The dashboard's UpcomingEventsCard renders .name directly — null = empty card.
-- Expected: 0 rows.
-- -----------------------------------------------------------------------------
SELECT id, name, event_date, is_active, status
FROM events
WHERE is_active = true
  AND event_date >= current_date
  AND (name IS NULL OR trim(name) = '')
ORDER BY event_date;


-- -----------------------------------------------------------------------------
-- 4. HIGH — Duplicate device_id in scanner_heartbeats
-- The Scanner Status widget groups by device_id. Duplicates double-count online.
-- Expected: 0 rows.
-- -----------------------------------------------------------------------------
SELECT device_id, COUNT(*) AS dup_count
FROM scanner_heartbeats
GROUP BY device_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 5. HIGH — email_queue rows stuck in 'processing' > 1 hour
-- The Email Delivery widget counts these as "pending", misleading the owner.
-- Expected: 0 rows.
-- -----------------------------------------------------------------------------
SELECT id, email_type, recipient_email, status, created_at, updated_at,
       (now() - updated_at) AS stuck_for
FROM email_queue
WHERE status = 'processing'
  AND updated_at < now() - interval '1 hour'
ORDER BY updated_at
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 6. MEDIUM — ticket_types with NULL total_inventory on upcoming events
-- Dashboard falls back to capacity=100 when all tiers are NULL, producing
-- misleading "% sold" numbers.
-- Expected: low count; a high count means the owner is ignoring inventory.
-- -----------------------------------------------------------------------------
SELECT tt.event_id, e.name AS event_name, tt.name AS tier, tt.total_inventory
FROM ticket_types tt
JOIN events e ON e.id = tt.event_id
WHERE e.is_active = true
  AND e.event_date >= current_date
  AND tt.total_inventory IS NULL
ORDER BY e.event_date
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 7. MEDIUM — Upcoming events where metadata->>'location' is missing
-- The UpcomingEventsCard reads metadata.location. When null, the card
-- shows no location text. Prefer venue_name (first-class column).
-- Expected: low count or 0.
-- -----------------------------------------------------------------------------
SELECT id, name, event_date, venue_name, metadata
FROM events
WHERE is_active = true
  AND event_date >= current_date
  AND (metadata IS NULL OR NOT (metadata ? 'location'))
ORDER BY event_date
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 8. INFO — orders.status vocabulary in production
-- Ensures the dashboard's `status === 'completed'` filter matches reality.
-- If 'paid' is common but not in the filter, AOV is wrong.
-- Expected: see which statuses exist and at what volume.
-- -----------------------------------------------------------------------------
SELECT status, COUNT(*) AS rows, MIN(created_at) AS first_seen, MAX(created_at) AS last_seen
FROM orders
GROUP BY status
ORDER BY rows DESC;


-- -----------------------------------------------------------------------------
-- 9. INFO — tickets.status vocabulary in production
-- Same concern for CheckInProgress which filters status IN ('scanned','used').
-- -----------------------------------------------------------------------------
SELECT status, COUNT(*) AS rows
FROM tickets
GROUP BY status
ORDER BY rows DESC;


-- -----------------------------------------------------------------------------
-- 10. INFO — scan_logs success rate last 24h
-- Not a pass/fail query — a smoke check. If success rate dips below 90%,
-- the scanner skill has a real problem and the dashboard will show it.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*) FILTER (WHERE scan_success = true) AS ok,
  COUNT(*) FILTER (WHERE scan_success = false) AS fail,
  COUNT(*) FILTER (WHERE scan_success IS NULL) AS unknown,
  COUNT(*) AS total,
  ROUND(100.0 * COUNT(*) FILTER (WHERE scan_success = true) / NULLIF(COUNT(*),0), 2) AS pct_ok
FROM scan_logs
WHERE scanned_at > now() - interval '24 hours';


-- -----------------------------------------------------------------------------
-- 11. INFO — Supabase Realtime publication coverage
-- useDashboardRealtime subscribes to 7 tables. Each must be a publication
-- member or the subscription is silent. If this returns 0 rows, check
-- `SELECT * FROM pg_publication` — the pub might be named differently.
-- Hand off to maguey-bulletproof-sync if the pub isn't standard.
-- -----------------------------------------------------------------------------
SELECT tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('tickets','orders','scan_logs','email_queue','scanner_heartbeats','events','vip_reservations')
ORDER BY tablename;


-- -----------------------------------------------------------------------------
-- 12. INFO — Active publications (fallback if query #11 returns 0)
-- -----------------------------------------------------------------------------
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication;
