-- =============================================================================
-- Bulletproof Bookings — Audit Queries
-- =============================================================================
-- SELECT-only. Run via mcp__supabase-mt__execute_sql. Project: MT Barbershop.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. CRITICAL — btree_gist overlap constraint exists
-- Expected: 1 row
-- -----------------------------------------------------------------------------
SELECT conname AS constraint_name,
       pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conname = 'bookings_no_time_overlap';


-- -----------------------------------------------------------------------------
-- 2. CRITICAL — No overlapping bookings per barber
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
WITH ranges AS (
  SELECT id,
         barber_id,
         scheduled_date,
         scheduled_time,
         duration_minutes,
         tsrange(
           (scheduled_date + scheduled_time)::timestamp,
           (scheduled_date + scheduled_time + (COALESCE(duration_minutes, 30) || ' minutes')::interval)::timestamp
         ) AS window
  FROM bookings
  WHERE status IN ('confirmed', 'pending', 'in_progress')
    AND deleted_at IS NULL
)
SELECT a.id AS booking_a,
       b.id AS booking_b,
       a.barber_id,
       a.scheduled_date,
       a.scheduled_time,
       b.scheduled_time
FROM ranges a
JOIN ranges b
  ON a.barber_id = b.barber_id
 AND a.id < b.id
 AND a.window && b.window;


-- -----------------------------------------------------------------------------
-- 3. HIGH — Future confirmed/pending with scheduled_date < today
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, scheduled_date, scheduled_time, status, client_name
FROM bookings
WHERE status IN ('confirmed', 'pending')
  AND deleted_at IS NULL
  AND scheduled_date < (now() AT TIME ZONE 'America/New_York')::date;


-- -----------------------------------------------------------------------------
-- 4. CRITICAL — Bookings with invalid FK or missing service reference
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id,
       b.barber_id,
       b.location_id,
       b.service_id,
       b.custom_service_id,
       (ba.id IS NULL) AS barber_missing,
       (l.id IS NULL) AS location_missing,
       (b.service_id IS NULL AND b.custom_service_id IS NULL) AS no_service
FROM bookings b
LEFT JOIN barbers ba ON ba.id = b.barber_id
LEFT JOIN locations l ON l.id = b.location_id
WHERE b.deleted_at IS NULL
  AND (ba.id IS NULL
       OR l.id IS NULL
       OR (b.service_id IS NULL AND b.custom_service_id IS NULL));


-- -----------------------------------------------------------------------------
-- 5. HIGH — Completed bookings missing payment info
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, status, payment_method, payment_status, service_amount, end_time
FROM bookings
WHERE status = 'completed'
  AND deleted_at IS NULL
  AND (payment_status IS NULL OR payment_method IS NULL);


-- -----------------------------------------------------------------------------
-- 6. HIGH — Duplicate confirmation codes
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT confirmation_code, COUNT(*) AS n, array_agg(id) AS booking_ids
FROM bookings
WHERE confirmation_code IS NOT NULL
GROUP BY confirmation_code
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 7. HIGH — Malformed confirmation codes
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, confirmation_code
FROM bookings
WHERE confirmation_code IS NOT NULL
  AND confirmation_code !~ '^MT-[A-Z0-9]{6}$'
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 8. HIGH — Duplicate stripe_payment_id
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT stripe_payment_id, COUNT(*) AS n, array_agg(id) AS booking_ids
FROM bookings
WHERE stripe_payment_id IS NOT NULL
GROUP BY stripe_payment_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 9. MEDIUM — client_id referencing nonexistent client
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT b.id, b.client_id
FROM bookings b
LEFT JOIN clients c ON c.id = b.client_id
WHERE b.client_id IS NOT NULL
  AND c.id IS NULL;


-- -----------------------------------------------------------------------------
-- 10. CRITICAL — status values outside valid set
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT status, COUNT(*) AS n
FROM bookings
WHERE status NOT IN ('confirmed', 'pending', 'in_progress', 'called',
                     'completed', 'cancelled', 'no_show')
GROUP BY status;


-- -----------------------------------------------------------------------------
-- 11. HIGH — in_progress bookings missing start_time
-- Expected: 0 rows
-- -----------------------------------------------------------------------------
SELECT id, status, start_time, called_at
FROM bookings
WHERE status = 'in_progress'
  AND deleted_at IS NULL
  AND start_time IS NULL;


-- -----------------------------------------------------------------------------
-- 12. LOW — 1h reminder sent but 24h reminder not sent
-- Expected: few/none
-- -----------------------------------------------------------------------------
SELECT id, scheduled_date, scheduled_time, reminder_sent, one_hour_reminder_sent
FROM bookings
WHERE one_hour_reminder_sent = true
  AND reminder_sent = false
  AND deleted_at IS NULL;


-- -----------------------------------------------------------------------------
-- 13. MEDIUM — Soft-deleted bookings created recently (hygiene check)
-- Expected: low count per day
-- -----------------------------------------------------------------------------
SELECT DATE(deleted_at AT TIME ZONE 'America/New_York') AS deleted_day,
       COUNT(*) AS n
FROM bookings
WHERE deleted_at IS NOT NULL
  AND deleted_at > now() - interval '30 days'
GROUP BY deleted_day
ORDER BY deleted_day DESC;


-- -----------------------------------------------------------------------------
-- 14. INFO — Today's bookings by location/status
-- -----------------------------------------------------------------------------
SELECT l.name AS location,
       b.status,
       COUNT(*) AS n
FROM bookings b
JOIN locations l ON l.id = b.location_id
WHERE b.scheduled_date = (now() AT TIME ZONE 'America/New_York')::date
  AND b.deleted_at IS NULL
GROUP BY l.name, b.status
ORDER BY l.name, b.status;


-- -----------------------------------------------------------------------------
-- 15. INFO — Pending reminder workload (scale indicator)
-- -----------------------------------------------------------------------------
SELECT
  SUM(CASE WHEN reminder_sent = false THEN 1 ELSE 0 END) AS pending_24h_reminders,
  SUM(CASE WHEN one_hour_reminder_sent = false THEN 1 ELSE 0 END) AS pending_1h_reminders
FROM bookings
WHERE scheduled_date BETWEEN (now() AT TIME ZONE 'America/New_York')::date
                         AND (now() AT TIME ZONE 'America/New_York')::date + interval '2 days'
  AND deleted_at IS NULL
  AND status = 'confirmed';


-- -----------------------------------------------------------------------------
-- 16. INFO — Booksy sync coverage per barber
-- -----------------------------------------------------------------------------
SELECT id, slug, booksy_sync_email, booksy_sync_enabled
FROM barbers
WHERE is_active = true
ORDER BY booksy_sync_enabled DESC, slug;


-- -----------------------------------------------------------------------------
-- 17. HIGH — Native bookings off the service-duration slot grid (post-2026-04-27)
-- Slot grid rule: (slot_min - schedule.start_time_min) % service.duration_min === 0
-- Excludes Booksy imports (notes LIKE '%Booksy%') and pre-fix history.
-- Expected: 0 rows. Any non-zero count = OFF_GRID_SLOT slipped past the server check.
-- -----------------------------------------------------------------------------
WITH eligible AS (
  SELECT b.id, b.barber_id, b.scheduled_date, b.scheduled_time, b.duration_minutes,
         b.notes, b.created_at,
         EXTRACT(DOW FROM b.scheduled_date)::int AS dow,
         (EXTRACT(HOUR FROM b.scheduled_time::time) * 60
          + EXTRACT(MINUTE FROM b.scheduled_time::time))::int AS slot_min
  FROM bookings b
  WHERE b.deleted_at IS NULL
    AND b.created_at >= '2026-04-27'
    AND COALESCE(b.notes, '') NOT LIKE '%Booksy%'
    AND b.duration_minutes IS NOT NULL
    AND b.duration_minutes > 0
)
SELECT e.id, e.barber_id, e.scheduled_date, e.scheduled_time,
       e.duration_minutes, s.start_time AS schedule_start
FROM eligible e
JOIN barber_schedules s
  ON s.barber_id = e.barber_id
 AND s.day_of_week = e.dow
 AND s.is_active = true
WHERE ((e.slot_min
        - (EXTRACT(HOUR FROM s.start_time::time) * 60
           + EXTRACT(MINUTE FROM s.start_time::time))::int)
       % e.duration_minutes) <> 0;
