-- =============================================================================
-- Bulletproof Schedules — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. HIGH — Active barbers with no active schedule row
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id, b.slug, p.first_name, p.last_name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
LEFT JOIN barber_schedules bs ON bs.barber_id = b.id AND bs.is_active = true
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name
HAVING COUNT(bs.id) = 0;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Schedule rows referencing nonexistent locations
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT bs.id AS schedule_id, bs.barber_id, bs.day_of_week, bs.location_id
FROM barber_schedules bs
LEFT JOIN locations l ON l.id = bs.location_id
WHERE bs.is_active = true
  AND l.id IS NULL;


-- -----------------------------------------------------------------------------
-- 3. HIGH — day_of_week out of range
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, barber_id, day_of_week
FROM barber_schedules
WHERE day_of_week < 0 OR day_of_week > 6;


-- -----------------------------------------------------------------------------
-- 4. HIGH — start_time >= end_time
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, barber_id, day_of_week, start_time, end_time
FROM barber_schedules
WHERE is_active = true
  AND start_time >= end_time;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Break times don't fit within schedule window
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, barber_id, day_of_week, start_time, end_time, break_start, break_end
FROM barber_schedules
WHERE is_active = true
  AND break_start IS NOT NULL
  AND (break_start < start_time
       OR break_end > end_time
       OR break_start >= break_end);


-- -----------------------------------------------------------------------------
-- 6. HIGH — Duplicate schedule rows per (barber, day)
-- Expected: 0 rows (UNIQUE constraint should prevent this)
-- -----------------------------------------------------------------------------
SELECT barber_id, day_of_week, COUNT(*) AS n, array_agg(id) AS schedule_ids
FROM barber_schedules
WHERE is_active = true
GROUP BY barber_id, day_of_week
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 7. HIGH — location_change_requests with invalid barber or location FK
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT lcr.id, lcr.barber_id, lcr.requested_location_id, lcr.status
FROM location_change_requests lcr
LEFT JOIN barbers b ON b.id = lcr.barber_id
LEFT JOIN locations l ON l.id = lcr.requested_location_id
WHERE b.id IS NULL OR l.id IS NULL;


-- -----------------------------------------------------------------------------
-- 8. MEDIUM — Duplicate pending requests per (barber, day)
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT barber_id, day_of_week, COUNT(*) AS n
FROM location_change_requests
WHERE status = 'pending'
GROUP BY barber_id, day_of_week
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — Approved/declined requests missing reviewer/timestamp
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, status, reviewed_by, reviewed_at
FROM location_change_requests
WHERE status IN ('approved', 'declined')
  AND (reviewed_by IS NULL OR reviewed_at IS NULL);


-- -----------------------------------------------------------------------------
-- 10. HIGH — barbers.preferred_location_id column exists in schema
-- Expected: 1 row
-- -----------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'preferred_location_id';


-- -----------------------------------------------------------------------------
-- 11. LOW — update_source values are sane
-- Expected: subset of {barber_self, owner_dashboard, seed}
-- -----------------------------------------------------------------------------
SELECT DISTINCT update_source, COUNT(*) AS n
FROM barber_schedules
WHERE update_source IS NOT NULL
GROUP BY update_source;


-- -----------------------------------------------------------------------------
-- 12. INFO — Schedule coverage per active barber (for scale planning)
-- -----------------------------------------------------------------------------
SELECT b.id AS barber_id, b.slug, p.first_name, p.last_name,
       COUNT(bs.id) AS scheduled_days,
       array_agg(DISTINCT bs.location_id) AS locations_worked
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
LEFT JOIN barber_schedules bs ON bs.barber_id = b.id AND bs.is_active = true
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name
ORDER BY scheduled_days ASC, p.first_name;


-- -----------------------------------------------------------------------------
-- 13. INFO — Pending location change requests by target location
-- -----------------------------------------------------------------------------
SELECT l.name AS requested_location, l.slug, COUNT(*) AS pending_requests
FROM location_change_requests lcr
JOIN locations l ON l.id = lcr.requested_location_id
WHERE lcr.status = 'pending'
GROUP BY l.name, l.slug;


-- -----------------------------------------------------------------------------
-- 14. INFO — Recent schedule changes (audit trail)
-- -----------------------------------------------------------------------------
SELECT bs.updated_at, bs.barber_id, bs.day_of_week, bs.location_id,
       bs.update_source, bs.updated_by
FROM barber_schedules bs
WHERE bs.updated_at > now() - interval '7 days'
ORDER BY bs.updated_at DESC
LIMIT 50;
