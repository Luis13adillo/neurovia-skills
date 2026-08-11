# Schedule Invariants

Severities: CRITICAL / HIGH / MEDIUM / LOW. All SQL is SELECT-only.

---

## HARD RULE — One Barber, One Location, Forever (locked 2026-04-25)

**Every barber works at exactly ONE physical location, on every day they work. There is NO operational case where a barber's `barber_schedules` rows reference more than one `location_id`.** Owner stated this explicitly on 2026-04-25 — split-location weeks do not exist in this business and never will.

### 0. All of a barber's active schedule rows share the same location_id [CRITICAL — supersedes everything below]
```sql
-- Any barber whose active schedule rows reference more than one location_id is corrupt data.
-- Repair = collapse all rows to barbers.preferred_location_id (or owner-confirmed location).
SELECT
  bs.barber_id,
  p.first_name,
  p.last_name,
  COUNT(DISTINCT bs.location_id) AS distinct_location_count,
  ARRAY_AGG(DISTINCT l.name ORDER BY l.name) AS locations_seen
FROM barber_schedules bs
JOIN barbers b ON b.id = bs.barber_id
LEFT JOIN profiles p ON p.id = b.profile_id
LEFT JOIN locations l ON l.id = bs.location_id
WHERE bs.is_active = true
  AND b.is_active = true
GROUP BY bs.barber_id, p.first_name, p.last_name
HAVING COUNT(DISTINCT bs.location_id) > 1;
-- Expected: 0 rows. ANY result = HARD RULE violation. Flag every row in the audit report.
```

### 0b. Every active barber's schedule rows match their `preferred_location_id` anchor [CRITICAL]
```sql
SELECT
  bs.barber_id,
  p.first_name,
  p.last_name,
  b.preferred_location_id AS anchor,
  ARRAY_AGG(DISTINCT bs.location_id) AS schedule_location_ids
FROM barber_schedules bs
JOIN barbers b ON b.id = bs.barber_id
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE bs.is_active = true
  AND b.is_active = true
  AND b.preferred_location_id IS NOT NULL
GROUP BY bs.barber_id, p.first_name, p.last_name, b.preferred_location_id
HAVING ARRAY_AGG(DISTINCT bs.location_id) <> ARRAY[b.preferred_location_id]::uuid[];
-- Expected: 0 rows. Drift = bug. The anchor and the schedule rows MUST agree.
```

**Audit rule:** invariants 0 and 0b are P0 / blocking. If either returns rows, the audit report header must say "HARD RULE VIOLATION — split-location weeks present" and recommend collapsing all rows to the anchor before any other finding is investigated.

---

## Data-level

### 1. Every active barber has ≥1 active schedule row [HIGH]
```sql
SELECT b.id AS barber_id, b.slug, p.first_name, p.last_name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
LEFT JOIN barber_schedules bs ON bs.barber_id = b.id AND bs.is_active = true
WHERE b.is_active = true
GROUP BY b.id, b.slug, p.first_name, p.last_name
HAVING COUNT(bs.id) = 0;
-- Expected: 0 rows
```

### 2. Every schedule row's location_id exists in locations [CRITICAL]
```sql
SELECT bs.id AS schedule_id, bs.barber_id, bs.day_of_week, bs.location_id
FROM barber_schedules bs
LEFT JOIN locations l ON l.id = bs.location_id
WHERE bs.is_active = true
  AND l.id IS NULL;
-- Expected: 0 rows
```

### 3. day_of_week in [0,6] [HIGH]
Enforced by CHECK constraint, but verify no drift.
```sql
SELECT id, barber_id, day_of_week
FROM barber_schedules
WHERE day_of_week < 0 OR day_of_week > 6;
-- Expected: 0 rows
```

### 4. start_time strictly less than end_time [HIGH]
```sql
SELECT id, barber_id, day_of_week, start_time, end_time
FROM barber_schedules
WHERE is_active = true
  AND start_time >= end_time;
-- Expected: 0 rows
```

### 5. Break times fit within (start_time, end_time) [HIGH]
Enforced by CHECK constraint that both are set together with `break_start < break_end`, but verify the window fits.
```sql
SELECT id, barber_id, day_of_week, start_time, end_time, break_start, break_end
FROM barber_schedules
WHERE is_active = true
  AND break_start IS NOT NULL
  AND (break_start < start_time OR break_end > end_time OR break_start >= break_end);
-- Expected: 0 rows
```

### 6. UNIQUE(barber_id, day_of_week) enforced [HIGH]
```sql
SELECT barber_id, day_of_week, COUNT(*) AS n
FROM barber_schedules
WHERE is_active = true
GROUP BY barber_id, day_of_week
HAVING COUNT(*) > 1;
-- Expected: 0 rows (unique constraint should prevent this)
```

### 7. location_change_requests reference valid barber + location [HIGH]
```sql
SELECT lcr.id, lcr.barber_id, lcr.requested_location_id, lcr.status
FROM location_change_requests lcr
LEFT JOIN barbers b ON b.id = lcr.barber_id
LEFT JOIN locations l ON l.id = lcr.requested_location_id
WHERE b.id IS NULL OR l.id IS NULL;
-- Expected: 0 rows
```

### 8. Pending requests don't duplicate per (barber, day) [MEDIUM]
```sql
SELECT barber_id, day_of_week, COUNT(*) AS n
FROM location_change_requests
WHERE status = 'pending'
GROUP BY barber_id, day_of_week
HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### 9. Approved requests have reviewed_by + reviewed_at set [MEDIUM]
```sql
SELECT id, status, reviewed_by, reviewed_at
FROM location_change_requests
WHERE status IN ('approved', 'declined')
  AND (reviewed_by IS NULL OR reviewed_at IS NULL);
-- Expected: 0 rows
```

### 10. `barbers.preferred_location_id` column exists in schema [HIGH]
See incidents.md — code depends on this column. Missing = 500 errors on schedule save.
```sql
SELECT column_name
FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'preferred_location_id';
-- Expected: 1 row
```

### 11. `update_source` enum values are sane [LOW]
```sql
SELECT DISTINCT update_source
FROM barber_schedules
WHERE update_source IS NOT NULL;
-- Expected: subset of {barber_self, owner_dashboard, seed}
```

---

## Code-level (verify via Read / Grep)

### C1. Schedule API preserves per-day location_id [CRITICAL]
- File: `src/app/api/barber/schedule/route.ts`
- Must build `existingLocationByDay` map BEFORE delete.
- Must re-insert each row with the prior location_id.
- Fallback (`preferred_location_id` → `staff_status.location_id`) applies only to brand-new days.
- See incidents.md "Per-Day Location Overwrite."

### C2. Availability API uses Eastern TZ [CRITICAL]
- File: `src/app/api/bookings/availability/route.ts`
- Every date/time operation must include `timeZone: 'America/New_York'`.
- No raw `getDay()` / `getHours()` / `toISOString().split('T')` / `toTimeString().slice()` without TZ conversion upstream.

### C3. Inline Supabase clients wrap fetch with `cache: 'no-store'` [HIGH]
- File: `src/app/api/barber/schedule/route.ts`
- File: `src/app/api/barber/location-request/route.ts`
- Per MEMORY.md Next.js 14 Data Cache rule.

### C4. Location request approval dual-updates [HIGH]
- File: `src/app/api/barber/location-request/route.ts` PATCH handler.
- Must update barber_schedules AND (conditionally) staff_status.

### C5. Both schedule UI pages mirrored [HIGH]
- `src/app/(dashboard)/barber/schedule/page.tsx`
- `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx`
- Features, state, and validation must match. See Cross-Dashboard Mirroring Rule in `context-awareness.md`.

### C6. No hardcoded day-of-week business logic [MEDIUM]
- Grep: `dayOfWeek === 0` / `getDay() === 0` patterns with business rules inside.
- Day-specific business rules (like Sunday closures) belong in `locations.hours_json`, not code.
