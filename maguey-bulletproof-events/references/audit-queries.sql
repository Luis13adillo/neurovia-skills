-- =============================================================================
-- Maguey Bulletproof Events — Audit Queries
-- =============================================================================
-- SELECT-only. Run one at a time via mcp__supabase__execute_sql.
-- Project: Maguey Nightclub (djbzjasdrwvbsoifxqzd.supabase.co)
-- Expected: 0 rows unless noted.
--
-- SCHEMA REALITY CHECK (verified 2026-04-21):
--   ticket_types columns: id, event_id, code, name, price (numeric dollars,
--     NOT price_cents), fee, limit_per_order, total_inventory (NOT capacity),
--     description, created_at, updated_at, tickets_sold.
--     NO is_active column — availability derives from total_inventory + tickets_sold.
--   events.status is free-form text (no CHECK). events.is_active is a separate
--     boolean flag (NOT NULL). events.cancellation_status is varchar.
--   event_vip_configs columns: id, event_id, vip_enabled, refund_policy_text,
--     disclaimer_text, created_at, updated_at. (Simpler than older drafts said.)
--   vip_table_templates has NO default_price_cents / bottles / packages —
--     templates are layout-only (table_number, default_tier, default_capacity,
--     position_x/y/row).
--   event_reminder_log columns: id, ticket_id, event_id, reminder_type,
--     sent_at, status.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Published upcoming events with no ticket_types
-- Expected: 0 rows (can't be purchased)
-- -----------------------------------------------------------------------------
SELECT e.id, e.name, e.event_date, e.status, e.is_active
FROM events e
LEFT JOIN ticket_types tt ON tt.event_id = e.id
WHERE e.status = 'published'
  AND e.is_active = true
  AND e.event_date >= current_date
GROUP BY e.id, e.name, e.event_date, e.status, e.is_active
HAVING COUNT(tt.id) = 0;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — vip_enabled events without any event_vip_tables
-- Expected: 0 rows (VIP auto-setup failed)
-- -----------------------------------------------------------------------------
SELECT e.id, e.name, e.event_date, e.vip_enabled
FROM events e
LEFT JOIN event_vip_tables evt ON evt.event_id = e.id
WHERE e.vip_enabled = true
  AND e.event_date >= current_date
GROUP BY e.id, e.name, e.event_date, e.vip_enabled
HAVING COUNT(evt.id) = 0;


-- -----------------------------------------------------------------------------
-- 3. MEDIUM — Past events still marked 'published' or is_active=true > 7 days
-- Expected: 0 rows (should have been archived / deactivated)
-- -----------------------------------------------------------------------------
SELECT id, name, event_date, status, is_active, updated_at
FROM events
WHERE (status = 'published' OR is_active = true)
  AND event_date < current_date - interval '7 days'
ORDER BY event_date DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- 4. CRITICAL — Events with NULL event_date (data integrity)
-- Expected: 0 rows (column is NOT NULL in schema, so should never have rows)
-- -----------------------------------------------------------------------------
SELECT id, name, status, created_at
FROM events
WHERE event_date IS NULL;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Cancelled events missing cancellation metadata
-- Expected: 0 rows (cancelled_at + cancellation_reason required for audit)
-- -----------------------------------------------------------------------------
SELECT id, name, cancellation_status, cancelled_at, cancellation_reason, updated_at
FROM events
WHERE cancellation_status = 'cancelled'
  AND (cancelled_at IS NULL OR cancellation_reason IS NULL OR cancellation_reason = '');


-- -----------------------------------------------------------------------------
-- 6. MEDIUM — Duplicate (name, event_date) pairs
-- Expected: 0 rows outside archived events
-- -----------------------------------------------------------------------------
SELECT name, event_date, COUNT(*) AS dup_count, array_agg(id) AS event_ids
FROM events
WHERE status IS DISTINCT FROM 'archived'
GROUP BY name, event_date
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 7. MEDIUM — Orphan ticket_types without parent event
-- Expected: 0 rows (FK should prevent but verify)
-- -----------------------------------------------------------------------------
SELECT tt.id, tt.name, tt.event_id, tt.created_at
FROM ticket_types tt
LEFT JOIN events e ON e.id = tt.event_id
WHERE e.id IS NULL;


-- -----------------------------------------------------------------------------
-- 8. MEDIUM — Orphan event_vip_tables without parent event
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT evt.id, evt.table_number, evt.event_id, evt.created_at
FROM event_vip_tables evt
LEFT JOIN events e ON e.id = evt.event_id
WHERE e.id IS NULL;


-- -----------------------------------------------------------------------------
-- 9. HIGH — Upcoming published events: reminder coverage
-- Informational: which events have reminder_log entries for their tickets
-- -----------------------------------------------------------------------------
SELECT e.id, e.name, e.event_date,
       (e.event_date - current_date) AS days_out,
       COUNT(DISTINCT erl.ticket_id) AS tickets_with_reminder_logged,
       COUNT(DISTINCT t.id) AS total_tickets
FROM events e
LEFT JOIN tickets t ON t.event_id = e.id AND t.status NOT IN ('cancelled', 'refunded')
LEFT JOIN event_reminder_log erl ON erl.ticket_id = t.id
WHERE e.status = 'published'
  AND COALESCE(e.cancellation_status, 'active') <> 'cancelled'
  AND e.event_date >= current_date
  AND e.event_date < current_date + interval '7 days'
GROUP BY e.id, e.name, e.event_date
ORDER BY e.event_date;


-- -----------------------------------------------------------------------------
-- 10. HIGH — Cancelled event but tickets still marked valid (refund incomplete)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT t.id AS ticket_id,
       t.status AS ticket_status,
       e.name AS event_name,
       e.cancellation_status,
       e.cancelled_at
FROM tickets t
JOIN events e ON e.id = t.event_id
WHERE e.cancellation_status = 'cancelled'
  AND t.status NOT IN ('refunded', 'cancelled')
  AND t.created_at < e.cancelled_at;


-- -----------------------------------------------------------------------------
-- 11. CRITICAL — ticket_types sold out for a published event but event still shows
-- Informational — no capacity column; uses total_inventory.
-- -----------------------------------------------------------------------------
SELECT tt.event_id, e.name AS event_name,
       tt.name AS tier_name,
       tt.total_inventory,
       tt.tickets_sold,
       (tt.tickets_sold >= tt.total_inventory) AS sold_out
FROM ticket_types tt
JOIN events e ON e.id = tt.event_id
WHERE e.status = 'published'
  AND e.event_date >= current_date
  AND tt.total_inventory IS NOT NULL
  AND tt.tickets_sold >= tt.total_inventory
ORDER BY e.event_date, tt.name;


-- -----------------------------------------------------------------------------
-- 12. INFO — Event summary: next 30 days
-- -----------------------------------------------------------------------------
SELECT e.id, e.name, e.event_date, e.status, e.cancellation_status, e.vip_enabled,
       e.is_active,
       COUNT(DISTINCT tt.id) AS ticket_type_count,
       SUM(tt.total_inventory) AS ga_total_inventory,
       SUM(tt.tickets_sold) AS ga_tickets_sold,
       COUNT(DISTINCT evt.id) AS vip_table_count
FROM events e
LEFT JOIN ticket_types tt ON tt.event_id = e.id
LEFT JOIN event_vip_tables evt ON evt.event_id = e.id
WHERE e.event_date >= current_date
  AND e.event_date < current_date + interval '30 days'
GROUP BY e.id, e.name, e.event_date, e.status, e.cancellation_status, e.vip_enabled, e.is_active
ORDER BY e.event_date;


-- -----------------------------------------------------------------------------
-- 13. MEDIUM — Events with age_restriction (review before door)
-- Expected: informational
-- -----------------------------------------------------------------------------
SELECT id, name, age_restriction, event_date, status
FROM events
WHERE age_restriction IS NOT NULL
  AND age_restriction <> ''
  AND age_restriction <> 'none'
  AND event_date >= current_date - interval '30 days'
ORDER BY event_date DESC;


-- -----------------------------------------------------------------------------
-- 14. INFO — Images/flyers storage usage
-- -----------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM storage.objects WHERE bucket_id = 'event-images') AS event_image_count,
  (SELECT SUM((metadata->>'size')::bigint) / 1024 / 1024
   FROM storage.objects WHERE bucket_id = 'event-images') AS event_image_mb,
  (SELECT COUNT(*) FROM events WHERE image_url IS NOT NULL) AS events_with_image_url,
  (SELECT COUNT(*) FROM events WHERE flyer_url IS NOT NULL) AS events_with_flyer_url,
  (SELECT COUNT(*) FROM events WHERE banner_url IS NOT NULL) AS events_with_banner_url;


-- -----------------------------------------------------------------------------
-- 15. MEDIUM — Events created in bulk recently (detect bulk import spikes)
-- Expected: informational
-- -----------------------------------------------------------------------------
SELECT date_trunc('day', created_at) AS day,
       COUNT(*) AS events_created
FROM events
WHERE created_at > now() - interval '30 days'
GROUP BY 1
HAVING COUNT(*) >= 5
ORDER BY 1 DESC;
