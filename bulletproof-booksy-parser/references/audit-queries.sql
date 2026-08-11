-- Booksy Parser Audit Queries
-- READ-ONLY. Run via mcp__supabase-mt__execute_sql.
-- Expected 0 rows unless a query notes otherwise.
-- Paired with references/invariants.md (same numbering where applicable).

-- ========================================================================
-- STRUCTURE & CONSTRAINTS
-- ========================================================================

-- [I1] Verify message_id UNIQUE constraint exists on external_calendar_events
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'external_calendar_events'::regclass
  AND contype = 'u';
-- Expected: at least one row naming message_id as UNIQUE.

-- [I14] RLS enabled on both tables
SELECT relname, relrowsecurity AS rls_enabled, relforcerowsecurity AS rls_forced
FROM pg_class
WHERE relname IN ('external_calendar_events', 'booksy_sync_logs');
-- Expected: rls_enabled = true on both rows.

-- [I15] Tables in realtime publication
SELECT tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('external_calendar_events', 'booksy_sync_logs');
-- Expected: external_calendar_events row present.

-- ========================================================================
-- ROW-LEVEL HEALTH
-- ========================================================================

-- [I2] No duplicate message_id rows (UNIQUE should prevent; defensive check)
SELECT message_id, COUNT(*) AS n
FROM external_calendar_events
GROUP BY message_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows.

-- [I3] Only valid status values
SELECT status, COUNT(*) AS n
FROM external_calendar_events
WHERE status NOT IN ('confirmed', 'cancelled', 'converted')
GROUP BY status;
-- Expected: 0 rows.

-- [I4] end_time must be strictly greater than start_time
SELECT id, barber_id, start_time, end_time, client_name, service_name
FROM external_calendar_events
WHERE end_time <= start_time
ORDER BY created_at DESC
LIMIT 50;
-- Expected: 0 rows. Any hit indicates parser pushed a bad time range.

-- [I5] Source distribution (should be booksy only today)
SELECT source, COUNT(*) AS n
FROM external_calendar_events
GROUP BY source
ORDER BY n DESC;
-- Expected: only 'booksy'. Any new source = new integration to audit separately.

-- [I7] Orphan events: barber_id points at missing or inactive barber
SELECT e.id, e.barber_id, e.start_time, e.client_name, b.is_active
FROM external_calendar_events e
LEFT JOIN barbers b ON b.id = e.barber_id
WHERE b.id IS NULL
   OR b.is_active = false
ORDER BY e.start_time DESC
LIMIT 50;
-- Expected: 0 rows against active barbers. Historical rows for inactive barbers are acceptable.

-- [I8] Orphan events: location_id points at missing location
SELECT e.id, e.location_id, e.start_time
FROM external_calendar_events e
LEFT JOIN locations l ON l.id = e.location_id
WHERE e.location_id IS NOT NULL
  AND l.id IS NULL;
-- Expected: 0 rows.

-- [I13] Converted events must have a matching live booking
SELECT e.id, e.start_time, e.barber_id, e.client_name
FROM external_calendar_events e
LEFT JOIN bookings bk
  ON bk.barber_id = e.barber_id
 AND bk.scheduled_date = (e.start_time AT TIME ZONE 'America/New_York')::date
 AND bk.scheduled_time = (e.start_time AT TIME ZONE 'America/New_York')::time
 AND bk.deleted_at IS NULL
WHERE e.status = 'converted'
  AND bk.id IS NULL
ORDER BY e.start_time DESC
LIMIT 50;
-- Expected: 0 rows.

-- ========================================================================
-- BARBER READINESS
-- ========================================================================

-- [I9a] Barbers with sync enabled but no forwarding email set
SELECT id, name, booksy_sync_enabled, booksy_sync_email
FROM barbers
WHERE booksy_sync_enabled = true
  AND (booksy_sync_email IS NULL OR booksy_sync_email = '');
-- Expected: 0 rows.

-- [I9b] Barbers whose forwarding email is not unique
SELECT booksy_sync_email, array_agg(id) AS barber_ids, COUNT(*) AS n
FROM barbers
WHERE booksy_sync_email IS NOT NULL
GROUP BY booksy_sync_email
HAVING COUNT(*) > 1;
-- Expected: 0 rows.

-- [I10] Last-seen inbound email per opted-in barber (silent dead forwarder check)
SELECT b.id, b.name, b.booksy_sync_email,
       (SELECT MAX(received_at) FROM booksy_sync_logs l WHERE l.barber_id = b.id) AS last_seen,
       (SELECT COUNT(*) FROM booksy_sync_logs l
         WHERE l.barber_id = b.id AND l.received_at > now() - interval '30 days') AS logs_30d
FROM barbers b
WHERE b.is_active = true
  AND b.booksy_sync_enabled = true
ORDER BY last_seen NULLS FIRST;
-- Review manually: last_seen NULL or > 30 days old = Gmail forwarding likely broken.

-- [I11] Opted-in barbers missing active custom services (convert-to-booking will fail)
SELECT b.id, b.name
FROM barbers b
WHERE b.is_active = true
  AND b.booksy_sync_enabled = true
  AND NOT EXISTS (
    SELECT 1 FROM barber_custom_services bcs
    WHERE bcs.barber_id = b.id AND bcs.is_active = true
  );
-- Expected: 0 rows.

-- Barbers opted-in but missing barber_schedules for any day of their working week
-- (convert-to-booking uses resolveBarberLocation which reads schedules by day_of_week)
SELECT b.id, b.name,
       (SELECT COUNT(DISTINCT day_of_week) FROM barber_schedules bs
         WHERE bs.barber_id = b.id AND bs.is_active = true) AS scheduled_days
FROM barbers b
WHERE b.is_active = true
  AND b.booksy_sync_enabled = true
ORDER BY scheduled_days ASC;
-- Review: 0 scheduled days = appointments can't resolve a location.

-- ========================================================================
-- PARSE HEALTH (7-DAY WINDOW)
-- ========================================================================

-- [I12] Parse status distribution over the last 7 days
SELECT parse_status, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM booksy_sync_logs
WHERE received_at > now() - interval '7 days'
GROUP BY parse_status
ORDER BY n DESC;
-- Review: 'failed' should be < 5% of total.

-- Recent failed parses — sample for template drift diagnosis
SELECT id, barber_id, received_at, parse_status, email_subject,
       LEFT(COALESCE(error_message, ''), 200) AS error_snippet
FROM booksy_sync_logs
WHERE parse_status = 'failed'
  AND received_at > now() - interval '7 days'
ORDER BY received_at DESC
LIMIT 20;

-- Parse success but no event created (suspicious — successful parse should emit at least one event)
SELECT l.id, l.barber_id, l.received_at, l.message_id, l.email_subject
FROM booksy_sync_logs l
WHERE l.parse_status = 'success'
  AND l.received_at > now() - interval '7 days'
  AND NOT EXISTS (
    SELECT 1 FROM external_calendar_events e
    WHERE e.message_id = l.message_id
       OR e.message_id LIKE l.message_id || '#%'
  );
-- Expected: 0 rows, OR only cancel/reschedule emails (which may update an existing row rather than insert).

-- ========================================================================
-- MULTI-LOCATION / SCALE
-- ========================================================================

-- Events per barber over last 30 days (spot imbalance indicating config issues)
SELECT b.name, b.booksy_sync_enabled,
       COUNT(e.id) FILTER (WHERE e.created_at > now() - interval '30 days') AS events_30d,
       COUNT(e.id) FILTER (WHERE e.status = 'converted' AND e.created_at > now() - interval '30 days') AS converted_30d,
       COUNT(e.id) FILTER (WHERE e.status = 'cancelled' AND e.created_at > now() - interval '30 days') AS cancelled_30d
FROM barbers b
LEFT JOIN external_calendar_events e ON e.barber_id = b.id
WHERE b.is_active = true
GROUP BY b.id, b.name, b.booksy_sync_enabled
ORDER BY events_30d DESC;

-- Events grouped by location (helps spot hardcoded / wrong location_id)
SELECT COALESCE(l.name, '<NULL>') AS location, e.status, COUNT(*) AS n
FROM external_calendar_events e
LEFT JOIN locations l ON l.id = e.location_id
WHERE e.created_at > now() - interval '30 days'
GROUP BY l.name, e.status
ORDER BY n DESC;
-- Review: every barber's appointments should hit the locations matching their barber_schedules.

-- ========================================================================
-- TIMEZONE SPOT-CHECKS
-- ========================================================================

-- Recent events rendered in Eastern Time (for eyeballing parse correctness)
SELECT e.id,
       (e.start_time AT TIME ZONE 'America/New_York') AS start_et,
       (e.end_time AT TIME ZONE 'America/New_York') AS end_et,
       e.client_name, e.service_name, b.name AS barber
FROM external_calendar_events e
JOIN barbers b ON b.id = e.barber_id
WHERE e.created_at > now() - interval '7 days'
  AND e.status = 'confirmed'
ORDER BY e.created_at DESC
LIMIT 30;
-- Review: start_et should look like a realistic appointment time. Anything at 00:00 or 04:00 ET with a subject
-- that suggests an 8 AM EDT appointment = the 4-hour UTC drift bug is back.

-- Events where start_time is between midnight and 4 AM Eastern (usually a TZ-drift symptom)
SELECT e.id, e.message_id, e.barber_id,
       (e.start_time AT TIME ZONE 'America/New_York') AS start_et,
       e.client_name
FROM external_calendar_events e
WHERE (e.start_time AT TIME ZONE 'America/New_York')::time BETWEEN '00:00' AND '04:00'
  AND e.created_at > now() - interval '30 days';
-- Review: expected to be near-empty. Any cluster here is a strong signal of a TZ regression.

-- ========================================================================
-- CALENDAR VS DB DRIFT
-- ========================================================================

-- Cancelled Booksy events created in the last 30 days — sanity check they're not blocking availability
-- (calendar/availability code filters status='confirmed' only; this just surfaces volume)
SELECT date_trunc('day', created_at) AS day, COUNT(*) AS cancelled
FROM external_calendar_events
WHERE status = 'cancelled'
  AND created_at > now() - interval '30 days'
GROUP BY day
ORDER BY day DESC;

-- Events still 'confirmed' whose start_time is > 30 days in the past (probably should have been converted or cancelled)
SELECT e.id, e.start_time, e.client_name, b.name AS barber
FROM external_calendar_events e
JOIN barbers b ON b.id = e.barber_id
WHERE e.status = 'confirmed'
  AND e.start_time < now() - interval '30 days'
ORDER BY e.start_time;
-- Review: long tail of stale 'confirmed' rows suggests missed cancel/convert emails.
