-- =============================================================================
-- Bulletproof Locations — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- Location data is sacred per CLAUDE.md — NEVER modify without explicit approval.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — 3 active locations with canonical slugs
-- Expected: 3 rows with slugs new-castle, newark, wilmington
-- -----------------------------------------------------------------------------
SELECT id, slug, name, is_active, accepts_walk_ins
FROM locations
WHERE is_active = true
ORDER BY slug;


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — Full canonical snapshot for comparison
-- Check each row against CLAUDE.md "Multi-Location System" values.
-- -----------------------------------------------------------------------------
SELECT slug, name, address, city, state, zip, phone,
       hours_json, is_active, accepts_walk_ins
FROM locations
ORDER BY
  CASE slug
    WHEN 'wilmington' THEN 1
    WHEN 'newark' THEN 2
    WHEN 'new-castle' THEN 3
    ELSE 99
  END;


-- -----------------------------------------------------------------------------
-- 3. HIGH — No deprecated phone numbers in DB
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, slug, phone
FROM locations
WHERE phone SIMILAR TO '%(998[- ]?0900|369[- ]?0900|555[- ]?[0-9]{4})%';


-- -----------------------------------------------------------------------------
-- 4. HIGH — hours_json has all 7 days + max_queue_size
-- Expected: all true for every active location
-- -----------------------------------------------------------------------------
SELECT slug,
       hours_json ? 'monday'         AS has_monday,
       hours_json ? 'tuesday'        AS has_tuesday,
       hours_json ? 'wednesday'      AS has_wednesday,
       hours_json ? 'thursday'       AS has_thursday,
       hours_json ? 'friday'         AS has_friday,
       hours_json ? 'saturday'       AS has_saturday,
       hours_json ? 'sunday'         AS has_sunday,
       hours_json ? 'max_queue_size' AS has_max_queue_size
FROM locations
WHERE is_active = true;


-- -----------------------------------------------------------------------------
-- 5. HIGH — Newark is closed Sundays
-- Expected: hours_json->>'sunday' IS NULL (or null JSON value)
-- -----------------------------------------------------------------------------
SELECT slug, hours_json -> 'sunday' AS sunday_value
FROM locations
WHERE slug = 'newark';


-- -----------------------------------------------------------------------------
-- 6. CRITICAL — Unique slugs
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT slug, COUNT(*) AS n
FROM locations
GROUP BY slug
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 7. MEDIUM — accepts_walk_ins explicitly set for all active
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, slug, accepts_walk_ins
FROM locations
WHERE is_active = true
  AND accepts_walk_ins IS NULL;


-- -----------------------------------------------------------------------------
-- 8. MEDIUM — All MT locations are in DE
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, slug, state
FROM locations
WHERE is_active = true
  AND state != 'DE';


-- -----------------------------------------------------------------------------
-- 9. HIGH — No "Houston" anywhere in DB
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, name, city, state, address
FROM locations
WHERE city ILIKE '%houston%'
   OR state = 'TX'
   OR address ILIKE '%houston%';


-- -----------------------------------------------------------------------------
-- 10. INFO — Barber coverage per location (for scale planning)
-- -----------------------------------------------------------------------------
SELECT l.slug,
       l.name,
       COUNT(DISTINCT bs.barber_id) AS active_barbers,
       COUNT(bs.id) AS total_schedule_rows
FROM locations l
LEFT JOIN barber_schedules bs
       ON bs.location_id = l.id
      AND bs.is_active = true
LEFT JOIN barbers b
       ON b.id = bs.barber_id
      AND b.is_active = true
WHERE l.is_active = true
GROUP BY l.slug, l.name
ORDER BY l.slug;


-- -----------------------------------------------------------------------------
-- 11. INFO — Today's operational snapshot
-- -----------------------------------------------------------------------------
SELECT l.slug,
       l.name,
       COUNT(DISTINCT ss.barber_id) FILTER (WHERE ss.status = 'clocked_in') AS clocked_in_now,
       COUNT(DISTINCT ss.barber_id) FILTER (WHERE ss.status = 'with_client') AS serving_now,
       COUNT(qe.id) FILTER (WHERE qe.status = 'waiting') AS waiting,
       COUNT(b.id) FILTER (
         WHERE b.scheduled_date = (now() AT TIME ZONE 'America/New_York')::date
           AND b.status = 'confirmed'
           AND b.deleted_at IS NULL
       ) AS confirmed_today
FROM locations l
LEFT JOIN staff_status ss   ON ss.location_id = l.id
LEFT JOIN queue_entries qe  ON qe.location_id = l.id
                           AND qe.check_in_time >= (now() AT TIME ZONE 'America/New_York')::date
LEFT JOIN bookings b        ON b.location_id = l.id
WHERE l.is_active = true
GROUP BY l.slug, l.name
ORDER BY l.slug;


-- -----------------------------------------------------------------------------
-- 12. INFO — Cascading FK dependencies on locations
-- Shows what gets cascade-deleted if a location is removed.
-- -----------------------------------------------------------------------------
SELECT tc.table_name,
       kcu.column_name,
       rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON kcu.constraint_name = tc.constraint_name
 AND kcu.table_schema = tc.table_schema
JOIN information_schema.referential_constraints rc
  ON rc.constraint_name = tc.constraint_name
 AND rc.constraint_schema = tc.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND ccu.table_name = 'locations'
ORDER BY tc.table_name;
