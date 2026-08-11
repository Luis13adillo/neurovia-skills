# Bookings Invariants

All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`.

---

## Data-level

### 1. btree_gist overlap constraint exists on bookings [CRITICAL]
```sql
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conname = 'bookings_no_time_overlap';
-- Expected: 1 row. The EXCLUDE constraint preventing overlaps.
```

### 2. No overlapping bookings for same barber [CRITICAL]
Even with the constraint, verify no violations exist.
```sql
WITH ranges AS (
  SELECT id, barber_id, scheduled_date, scheduled_time, duration_minutes,
         tsrange(
           (scheduled_date + scheduled_time)::timestamp,
           (scheduled_date + scheduled_time + (COALESCE(duration_minutes, 30) || ' minutes')::interval)::timestamp
         ) AS window
  FROM bookings
  WHERE status IN ('confirmed', 'pending', 'in_progress')
    AND deleted_at IS NULL
)
SELECT a.id AS booking_a, b.id AS booking_b, a.barber_id
FROM ranges a
JOIN ranges b ON a.barber_id = b.barber_id AND a.id < b.id AND a.window && b.window;
-- Expected: 0 rows
```

### 3. Future confirmed/pending bookings have scheduled_date >= today [HIGH]
```sql
SELECT id, scheduled_date, status
FROM bookings
WHERE status IN ('confirmed', 'pending')
  AND deleted_at IS NULL
  AND scheduled_date < (now() AT TIME ZONE 'America/New_York')::date;
-- Expected: 0 rows (stale confirmed bookings should be marked completed/no_show)
```

### 4. All bookings reference valid barber, location, and (service OR custom_service) [CRITICAL]
```sql
SELECT b.id, b.barber_id, b.location_id, b.service_id, b.custom_service_id,
       ba.id AS valid_barber, l.id AS valid_location
FROM bookings b
LEFT JOIN barbers ba ON ba.id = b.barber_id
LEFT JOIN locations l ON l.id = b.location_id
WHERE b.deleted_at IS NULL
  AND (ba.id IS NULL OR l.id IS NULL
       OR (b.service_id IS NULL AND b.custom_service_id IS NULL));
-- Expected: 0 rows
```

### 5. Completed bookings have payment_status set [HIGH]
```sql
SELECT id, status, payment_method, payment_status, service_amount
FROM bookings
WHERE status = 'completed'
  AND deleted_at IS NULL
  AND (payment_status IS NULL OR payment_method IS NULL);
-- Expected: 0 rows (or very few legacy rows)
```

### 6. Confirmation codes are unique and format-correct [HIGH]
```sql
-- Duplicates
SELECT confirmation_code, COUNT(*) AS n
FROM bookings
WHERE confirmation_code IS NOT NULL
GROUP BY confirmation_code
HAVING COUNT(*) > 1;
-- Expected: 0 rows

-- Format (MT- followed by 6 alphanumeric)
SELECT id, confirmation_code
FROM bookings
WHERE confirmation_code IS NOT NULL
  AND confirmation_code !~ '^MT-[A-Z0-9]{6}$'
LIMIT 20;
-- Expected: 0 rows
```

### 7. Soft-deleted bookings should be excluded from active queries [HIGH]
Not a data invariant — a code invariant. See code-level checks.

### 8. Reminder flags don't go backward [LOW]
```sql
-- 1h reminder set but 24h reminder not set (unusual)
SELECT id, scheduled_date, scheduled_time, reminder_sent, one_hour_reminder_sent
FROM bookings
WHERE one_hour_reminder_sent = true
  AND reminder_sent = false
  AND deleted_at IS NULL;
-- Expected: few/none. Could happen if 24h window was skipped (booking made <24h out).
```

### 9. Stripe payment IDs are unique per successful payment [HIGH]
```sql
SELECT stripe_payment_id, COUNT(*) AS n
FROM bookings
WHERE stripe_payment_id IS NOT NULL
GROUP BY stripe_payment_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 10. client_id (when set) references a real client [MEDIUM]
```sql
SELECT b.id, b.client_id
FROM bookings b
LEFT JOIN clients c ON c.id = b.client_id
WHERE b.client_id IS NOT NULL
  AND c.id IS NULL;
-- Expected: 0 rows
```

### 11. status values are valid [CRITICAL]
```sql
SELECT status, COUNT(*) AS n
FROM bookings
WHERE status NOT IN ('confirmed', 'pending', 'in_progress', 'called',
                     'completed', 'cancelled', 'no_show')
GROUP BY status;
-- Expected: 0 rows
```

### 12. in_progress bookings have start_time set [HIGH]
```sql
SELECT id, status, start_time, called_at
FROM bookings
WHERE status = 'in_progress'
  AND deleted_at IS NULL
  AND start_time IS NULL;
-- Expected: 0 rows
```

### 13. External calendar events (Booksy) don't leak cancelled/converted into calendar [HIGH]
Code-level check — see `src/lib/hooks/useCalendarEvents.ts` filters `.in('status', ['confirmed'])`.

### 14. Native bookings land on the service-duration slot grid [HIGH]
Excludes Booksy imports (notes LIKE '%Booksy%') and pre-2026-04-27 historical drift. Going forward, every native booking time MUST satisfy `(slot_minutes - schedule.start_time_minutes) % service.duration_minutes === 0`.
```sql
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
SELECT e.id, e.barber_id, e.scheduled_date, e.scheduled_time, e.duration_minutes,
       s.start_time AS schedule_start
FROM eligible e
JOIN barber_schedules s
  ON s.barber_id = e.barber_id
 AND s.day_of_week = e.dow
 AND s.is_active = true
WHERE ((e.slot_min
        - (EXTRACT(HOUR FROM s.start_time::time) * 60
           + EXTRACT(MINUTE FROM s.start_time::time))::int)
       % e.duration_minutes) <> 0;
-- Expected: 0 rows. Any non-zero count = OFF_GRID_SLOT slipped past the server check
-- (or the from-external import path tagged a row without a "Booksy" notes marker).
```

---

## Code-level (verify via Read / Grep)

### C1. btree_gist constraint exists in migration [CRITICAL]
- Check `supabase/migrations/20260401000000_booking_overbooking_constraint.sql` exists.
- The constraint definition should guard `status IN ('confirmed','pending','in_progress')` and `deleted_at IS NULL`.

### C2. Availability API correct [CRITICAL]
- File: `src/app/api/bookings/availability/route.ts`
- Uses `timeZone: 'America/New_York'` on: today check, now-time, Booksy event conversion, queue entry start_time conversion.
- Status filter includes `in_progress`.
- Booksy filter: `status='confirmed'` only (not cancelled, not converted).

### C3. Soft-delete filter on all queries [HIGH]
- `grep -rn "from('bookings')" src/app/api/ src/lib/` — every result must also show `.is('deleted_at', null)` nearby.
- Exceptions: admin queries for reporting on cancelled bookings.

### C4. Booksy timezone patterns [CRITICAL]
- Files: `from-external/route.ts`, `resend/inbound/route.ts`, `migrate-appointments/route.ts`.
- Must use `toLocaleDateString('en-CA', { timeZone: 'America/New_York' })` for dates.

### C5. Reminder cron auth [HIGH]
- File: `src/app/api/bookings/reminders/route.ts`
- First check: `CRON_SECRET` header match. Otherwise 401.

### C6. Public manage rate limits [HIGH]
- File: `src/app/api/bookings/manage/[code]/route.ts`
- GET: 30 req/min. POST: 5 req/5min.

### C7. Confirmation code generation [MEDIUM]
- File: `src/app/api/bookings/route.ts` POST handler.
- Uses `nanoid(6)` prefixed with `MT-`.
- UNIQUE partial index at `supabase/migrations/20260326000000_unique_confirmation_code.sql`.

### C8. Cross-dashboard mirror [HIGH]
- Calendar and booking management features on `/barber/calendar` should mirror `/dashboard/my-chair/calendar`. See Cross-Dashboard Mirroring Rule.

### C9. Service-duration-stepped slot grid [CRITICAL — locked 2026-04-27]
- Helper exists: `src/lib/utils/booking-slot.ts` exports `timeToMinutes` and `isOnSlotGrid(scheduledTime, scheduleStartTime, serviceDurationMinutes)`.
- `src/app/api/bookings/availability/route.ts`: slot loop uses `interval = requestedDuration` (NOT hardcoded 30); `alignedStart = workStartMinutes` (anchored, NOT rounded); response includes `slotInterval` field.
- `src/app/api/bookings/route.ts` POST: imports + calls `isOnSlotGrid(time, barberSchedule.start_time, serviceDuration)` BEFORE the conflict check; returns `400 { error: 'OFF_GRID_SLOT' }` on fail.
- `src/app/api/bookings/quick/route.ts` POST: same check using `schedule.start_time` and `duration`.
- `src/app/api/bookings/[id]/reschedule/route.ts`: fetches `barber_schedules` for the NEW date's day_of_week and calls `isOnSlotGrid(new_time, newSchedule.start_time, newDuration)` BEFORE the parallel conflict-source queries.
- `src/app/api/bookings/from-external/route.ts`: deliberately does NOT call `isOnSlotGrid` — Booksy imports keep their literal time. If anyone adds the check here, that's a bug.
- `src/components/booking/TimeSlotPicker.tsx`: passes `&duration=${serviceDuration}` in the availability fetch; reads `slotInterval` from response into FetchState; slot loop uses `interval = slotInterval || serviceDuration` and `alignedStart = startMinutes` (no rounding).
- `src/components/dashboard/calendar/ManualBookingSheet.tsx`: re-fetches availability when selected service changes (effect deps include `selectedService`); slot loop hidden until a service is selected; loop steps by `slotInterval || selectedService.duration_minutes` from `startTotal`.
- Banned in any of the 4 booking write paths: `interval = 30` hardcode, `Math.ceil(startMinutes / interval) * interval` rounding.
