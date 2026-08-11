-- =============================================================================
-- Bulletproof Queue — Audit Queries
-- =============================================================================
-- ALL queries are SELECT-only. NEVER add INSERT / UPDATE / DELETE here.
-- Run one at a time via mcp__supabase-mt__execute_sql.
-- Project: MT Barbershop (axkcbijbwhcydsqbhtpu.supabase.co)
--
-- Each block is self-contained. Every query's expected result is commented
-- above it. If the actual result differs, mark it FAIL in the audit report.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — Every active queue entry must have a valid location
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT qe.id, qe.location_id, qe.status, qe.client_name, qe.created_at
FROM queue_entries qe
LEFT JOIN locations l ON l.id = qe.location_id
WHERE l.id IS NULL
  AND qe.status IN ('waiting', 'called', 'in_chair');


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — No two entries in_chair for the same barber
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT assigned_barber_id,
       COUNT(*) AS active_count,
       array_agg(id) AS entry_ids
FROM queue_entries
WHERE status = 'in_chair'
  AND assigned_barber_id IS NOT NULL
GROUP BY assigned_barber_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 3. CRITICAL — No barber is in_chair (queue) AND has active booking today
-- Expected: 0 rows
-- NOTE: 'today' uses America/New_York, not UTC
-- -----------------------------------------------------------------------------
SELECT qe.assigned_barber_id,
       qe.id AS queue_entry_id,
       b.id AS booking_id,
       b.scheduled_date,
       b.status AS booking_status
FROM queue_entries qe
JOIN bookings b
  ON b.barber_id = qe.assigned_barber_id
 AND b.status IN ('confirmed', 'in_progress')
 AND b.scheduled_date = (now() AT TIME ZONE 'America/New_York')::date
WHERE qe.status = 'in_chair';


-- -----------------------------------------------------------------------------
-- 4. CRITICAL — Every completed entry has a service_transactions row
-- Expected: 0 rows
-- Bounded to last 30 days to keep the query fast
-- -----------------------------------------------------------------------------
SELECT qe.id,
       qe.end_time,
       qe.service_amount,
       qe.payment_method
FROM queue_entries qe
LEFT JOIN service_transactions st ON st.queue_entry_id = qe.id
WHERE qe.status = 'completed'
  AND st.id IS NULL
  AND qe.end_time > now() - interval '30 days';


-- -----------------------------------------------------------------------------
-- 5. HIGH — Position sequence contiguous per location (no gaps)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH active AS (
  SELECT location_id,
         position,
         id,
         ROW_NUMBER() OVER (PARTITION BY location_id ORDER BY position) AS expected_pos
  FROM queue_entries
  WHERE status IN ('waiting', 'called', 'in_chair')
)
SELECT location_id, id, position, expected_pos
FROM active
WHERE position != expected_pos;


-- -----------------------------------------------------------------------------
-- 6. HIGH — called_time set only when status = 'called'
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, status, called_time, check_in_time
FROM queue_entries
WHERE (status = 'called' AND called_time IS NULL)
   OR (status = 'waiting' AND called_time IS NOT NULL);


-- -----------------------------------------------------------------------------
-- 7. HIGH — start_time set only for in_chair or later
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, status, start_time, end_time
FROM queue_entries
WHERE (status IN ('in_chair', 'completed') AND start_time IS NULL)
   OR (status IN ('waiting', 'called')     AND start_time IS NOT NULL);


-- -----------------------------------------------------------------------------
-- 8. HIGH — Completed entries must have end_time
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, status, end_time
FROM queue_entries
WHERE status = 'completed'
  AND end_time IS NULL;


-- -----------------------------------------------------------------------------
-- 9. HIGH — Test barber IDs must be is_active = false
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, is_active
FROM barbers
WHERE id IN (
  'a274e1cf-955a-46f1-bc4c-dcd06a0510af',
  'b0020000-0000-0000-0000-000000000002',
  'b0030000-0000-0000-0000-000000000003',
  'b0040000-0000-0000-0000-000000000004'
)
AND is_active = true;


-- -----------------------------------------------------------------------------
-- 10. LOW — No recent TEST- prefixed queue entries (test cleanup hygiene)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, client_name, created_at, status
FROM queue_entries
WHERE (client_name ILIKE 'TEST-%' OR client_name ILIKE 'TEST_%')
  AND created_at > now() - interval '24 hours'
ORDER BY created_at DESC;


-- -----------------------------------------------------------------------------
-- 11. HIGH — Walk-in services catalog (informational — confirm with UI)
-- Expected: list should match what /queue check-in shows. Compare manually.
-- -----------------------------------------------------------------------------
SELECT id, name, price, duration_minutes, category, is_active
FROM services
WHERE is_active = true
ORDER BY category, name;


-- -----------------------------------------------------------------------------
-- 12. MEDIUM — Newark closed Sundays (inspect hours_json shape)
-- Expected: hours_json.sunday reflects closed state
-- -----------------------------------------------------------------------------
SELECT id, name, slug, hours_json
FROM locations
WHERE slug = 'newark';


-- -----------------------------------------------------------------------------
-- 13. MEDIUM — Every active barber has at least one active schedule row
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id,
       b.is_active,
       p.first_name,
       p.last_name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
LEFT JOIN barber_schedules bs
       ON bs.barber_id = b.id
      AND bs.is_active = true
WHERE b.is_active = true
GROUP BY b.id, p.first_name, p.last_name, b.is_active
HAVING COUNT(bs.id) = 0;


-- -----------------------------------------------------------------------------
-- 14. MEDIUM — Every staff_status row points at a real barber
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT ss.barber_id, ss.status, ss.location_id
FROM staff_status ss
LEFT JOIN barbers b ON b.id = ss.barber_id
WHERE b.id IS NULL;


-- -----------------------------------------------------------------------------
-- 15. HIGH — staff_status.current_queue_entry_id points at a real in_chair entry
-- Expected: 0 rows
-- When status = 'with_client', the linked entry must exist AND be in_chair
-- -----------------------------------------------------------------------------
SELECT ss.barber_id,
       ss.status,
       ss.current_queue_entry_id,
       qe.id AS entry_id,
       qe.status AS entry_status
FROM staff_status ss
LEFT JOIN queue_entries qe ON qe.id = ss.current_queue_entry_id
WHERE ss.status = 'with_client'
  AND (qe.id IS NULL OR qe.status != 'in_chair');


-- -----------------------------------------------------------------------------
-- 16. MEDIUM — No duplicate clients by phone (migration 045 enforces UNIQUE)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT phone, COUNT(*) AS n, array_agg(id) AS client_ids
FROM clients
WHERE phone IS NOT NULL
  AND phone != ''
GROUP BY phone
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 17. LOW — Customer loyalty drift spot-check
-- Expected: few/none. Investigate if many — loyalty accounting drift.
-- NOTE: schema uses current_punches (not punches_count — CLAUDE.md has doc drift here)
-- -----------------------------------------------------------------------------
SELECT c.id,
       c.phone,
       c.visit_count,
       cl.current_punches
FROM clients c
LEFT JOIN customer_loyalty cl ON cl.client_phone = c.phone
WHERE c.visit_count >= 10
  AND (cl.id IS NULL OR cl.current_punches = 0)
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 18. INFO — Today's queue snapshot (for context, not an assertion)
-- -----------------------------------------------------------------------------
SELECT l.name AS location,
       qe.status,
       COUNT(*) AS count
FROM queue_entries qe
JOIN locations l ON l.id = qe.location_id
WHERE qe.check_in_time >= (now() AT TIME ZONE 'America/New_York')::date
GROUP BY l.name, qe.status
ORDER BY l.name, qe.status;


-- -----------------------------------------------------------------------------
-- 19. INFO — Fair rotation preview per location (current state)
-- Shows who is eligible + their cuts_today (lowest is next)
-- -----------------------------------------------------------------------------
SELECT l.name AS location,
       ss.barber_id,
       p.first_name,
       p.last_name,
       ss.status,
       ss.cuts_today,
       ss.last_cut_completed_at
FROM staff_status ss
JOIN locations l ON l.id = ss.location_id
JOIN barbers b ON b.id = ss.barber_id AND b.is_active = true
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE ss.status IN ('clocked_in', 'with_client')
ORDER BY l.name,
         ss.cuts_today ASC,
         ss.last_cut_completed_at ASC NULLS FIRST;


-- -----------------------------------------------------------------------------
-- 20. HIGH — Any dead claim_queue_entry function still exists in DB (6d4e4ff residue)
-- Expected: may still exist as dead code (harmless if NOT called from app).
-- If exists AND grep of src/ shows app-code calls to it → critical regression.
-- -----------------------------------------------------------------------------
SELECT n.nspname AS schema,
       p.proname AS function_name,
       pg_get_function_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname = 'claim_queue_entry';
-- If rows exist: verify app code does NOT call this. See incidents.md "Unauthorized Commit Revert."
