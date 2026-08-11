# Booksy Parser Invariants

All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`. Expected 0 rows unless noted.

---

## Data-level

### 1. `external_calendar_events.message_id` is UNIQUE [CRITICAL]
```sql
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'external_calendar_events'::regclass
  AND contype = 'u';
-- Expected: at least one row naming message_id as UNIQUE.
```

### 2. No duplicate message_id rows [CRITICAL]
If constraint was ever dropped or bypassed by service-role code, duplicates would silently appear.
```sql
SELECT message_id, COUNT(*) AS n
FROM external_calendar_events
GROUP BY message_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows.
```

### 3. `status` values are valid [CRITICAL]
```sql
SELECT status, COUNT(*) AS n
FROM external_calendar_events
WHERE status NOT IN ('confirmed', 'cancelled', 'converted')
GROUP BY status;
-- Expected: 0 rows.
```

### 4. `end_time > start_time` on every row [CRITICAL]
A parse bug or stale row can flip this. Events where end ≤ start cause calendar rendering glitches and make availability math nonsensical.
```sql
SELECT id, barber_id, start_time, end_time
FROM external_calendar_events
WHERE end_time <= start_time;
-- Expected: 0 rows.
```

### 5. `source = 'booksy'` on every row this skill owns [HIGH]
Defensive — other integrations may one day write to this table.
```sql
SELECT source, COUNT(*) AS n
FROM external_calendar_events
GROUP BY source;
-- Expected: only 'booksy' rows (today). If new sources appear, audit them separately.
```

### 6. Every confirmed event has a matching success log [MEDIUM]
Confirmed events without a success log suggest the logs table lost rows.
```sql
SELECT e.id, e.message_id, e.barber_id, e.start_time
FROM external_calendar_events e
LEFT JOIN booksy_sync_logs l
  ON l.message_id = SPLIT_PART(e.message_id, '#', 1)
 AND l.parse_status = 'success'
WHERE e.status = 'confirmed'
  AND e.created_at > now() - interval '30 days'
  AND l.id IS NULL;
-- Expected: 0 rows, or a small number if the logs table was purged.
```

### 7. Orphan events: barber_id points at inactive/deleted barber [HIGH]
```sql
SELECT e.id, e.barber_id, e.start_time, e.client_name
FROM external_calendar_events e
LEFT JOIN barbers b ON b.id = e.barber_id
WHERE b.id IS NULL OR b.is_active = false;
-- Expected: 0 rows for active barbers. Inactive barbers may have historical Booksy rows; acceptable.
```

### 8. Orphan events: location_id points at missing location [MEDIUM]
```sql
SELECT e.id, e.location_id
FROM external_calendar_events e
LEFT JOIN locations l ON l.id = e.location_id
WHERE e.location_id IS NOT NULL AND l.id IS NULL;
-- Expected: 0 rows.
```

### 9. Barber sync config is self-consistent [HIGH]
```sql
-- Barbers with sync enabled but no forwarding email set
SELECT id, name, booksy_sync_enabled, booksy_sync_email
FROM barbers
WHERE booksy_sync_enabled = true
  AND (booksy_sync_email IS NULL OR booksy_sync_email = '');
-- Expected: 0 rows.

-- Barbers whose forwarding email is not unique
SELECT booksy_sync_email, COUNT(*) AS n
FROM barbers
WHERE booksy_sync_email IS NOT NULL
GROUP BY booksy_sync_email
HAVING COUNT(*) > 1;
-- Expected: 0 rows.
```

### 10. Opted-in barbers actually receive emails [HIGH]
A silent dead forwarder is the worst failure mode — no error, no log, no events.
```sql
SELECT b.id, b.name, b.booksy_sync_email,
       (SELECT MAX(received_at) FROM booksy_sync_logs l WHERE l.barber_id = b.id) AS last_seen
FROM barbers b
WHERE b.is_active = true
  AND b.booksy_sync_enabled = true
ORDER BY last_seen NULLS FIRST;
-- Review: any barber whose last_seen is NULL or > 30 days old is a red flag.
```

### 11. Opted-in barbers have at least one active custom service [HIGH]
Without a custom service, convert-to-booking fails 100% of the time.
```sql
SELECT b.id, b.name
FROM barbers b
WHERE b.is_active = true
  AND b.booksy_sync_enabled = true
  AND NOT EXISTS (
    SELECT 1 FROM barber_custom_services bcs
    WHERE bcs.barber_id = b.id AND bcs.is_active = true
  );
-- Expected: 0 rows.
```

### 12. Parse failure rate is healthy [MEDIUM]
```sql
SELECT parse_status, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM booksy_sync_logs
WHERE received_at > now() - interval '7 days'
GROUP BY parse_status
ORDER BY n DESC;
-- 'failed' should be < 5% of total. If higher, Booksy template likely drifted.
```

### 13. Converted events have a matching booking [HIGH]
If status='converted' but no booking points back to the event, conversion wrote partial state.
This is defensive; the API uses a single SQL path, so drift should be rare.
```sql
SELECT e.id, e.start_time, e.barber_id, e.client_name
FROM external_calendar_events e
LEFT JOIN bookings bk
  ON bk.barber_id = e.barber_id
 AND bk.scheduled_date = (e.start_time AT TIME ZONE 'America/New_York')::date
 AND bk.scheduled_time = (e.start_time AT TIME ZONE 'America/New_York')::time
 AND bk.deleted_at IS NULL
WHERE e.status = 'converted'
  AND bk.id IS NULL;
-- Expected: 0 rows. Drift here means convert-to-booking left state inconsistent.
```

### 14. RLS enabled on both Booksy tables [CRITICAL]
```sql
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN ('external_calendar_events', 'booksy_sync_logs');
-- Expected: relrowsecurity = true on both rows.
```

### 15. Tables in realtime publication [HIGH]
```sql
SELECT tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('external_calendar_events', 'booksy_sync_logs');
-- Expected: external_calendar_events present (so calendar UI updates). booksy_sync_logs optional.
```

---

## Code-level (verify via Read / Grep)

### C1. Parser supports English AND Spanish keywords [CRITICAL]
- File: `src/lib/booksy/parser.ts`
- See `references/parser-languages.md` for the full keyword list per type (new / rescheduled / cancelled / verification).
- Run:
  ```bash
  grep -n "nueva reserva\|nueva cita\|cancelada\|canceló\|reprogramada\|modificó" src/lib/booksy/parser.ts
  ```
  Expected: hits inside `parseBooksyEmail`'s type-detection switch.

### C2. Both parse paths use `America/New_York` round-trip [CRITICAL]
- File: `src/lib/booksy/parser.ts` → `parseDateTime()` and `parseDateTimeSpanish()`.
- Both must build a UTC candidate for each offset (-04:00 then -05:00) and verify via `Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', ... })` that the wall-clock round-trips.
- Grep:
  ```bash
  grep -n "America/New_York\|Intl.DateTimeFormat" src/lib/booksy/parser.ts
  ```
  Expected: multiple hits on each parse helper.

### C3. No banned timezone patterns in `src/lib/booksy/` or Booksy routes [CRITICAL]
- Banned list (per MEMORY.md "Booksy Timezone Rule"):
  - `toISOString().split('T')[0]` for a "local" date.
  - `toTimeString().slice(...)` for a "local" time.
  - `getHours()`/`getMinutes()`/`getDay()` without TZ adjustment.
  - Naked `new Date(str).getTime()` on a string that lacks a timezone suffix — ambiguous.
- Grep:
  ```bash
  grep -rn "toISOString().split\|toTimeString().slice" src/lib/booksy/ src/app/api/webhooks/resend/ src/app/api/bookings/from-external/ src/app/api/bookings/migrate-appointments/
  ```
  Expected: 0 hits. Any hit is a bug — see incidents.md Pattern #1.

### C4. Resend inbound route verifies Svix signature [CRITICAL]
- File: `src/app/api/webhooks/resend/inbound/route.ts`
- Grep:
  ```bash
  grep -n "svix\|RESEND_WEBHOOK_SECRET\|signature" src/app/api/webhooks/resend/inbound/route.ts
  ```
  Expected: signature verification fires BEFORE any DB write, throws 401 on failure.

### C5. Barber resolution is by `booksy_sync_email` only [HIGH]
- Grep the inbound route:
  ```bash
  grep -n "booksy_sync_email" src/app/api/webhooks/resend/inbound/route.ts
  ```
  Expected: one .eq('booksy_sync_email', recipientEmail) lookup. No fallback to sender or name.

### C6. Multi-block dedup within ±2 min [HIGH]
- File: inbound route.
- Grep:
  ```bash
  grep -n "120 \* 1000\|2 \* 60 \* 1000\|message_id.*#" src/app/api/webhooks/resend/inbound/route.ts
  ```
  Expected: evidence of (a) 2-minute dedup window, (b) `#N` suffix on message_id for multi-block inserts.

### C7. Reschedule match fallback order [CRITICAL]
- File: inbound route.
- The function handling rescheduled emails must attempt matches in this exact order:
  1. external_id
  2. previousStartTime + clientName (±5 min)
  3. clientName within ±30 min of new start time
- Read the function; confirm the order and that an earlier match returns before the later strategy runs.

### C8. Cancel match fallback order [CRITICAL]
- File: inbound route.
- Order:
  1. external_id
  2. clientName + startTime (±5 min)
  3. clientPhone + startTime (±5 min)
  4. startTime only (use only if exactly 1 event matches the window)

### C9. `useCalendarEvents` filters Booksy `status='confirmed'` [CRITICAL]
- File: `src/lib/hooks/useCalendarEvents.ts`
- Grep:
  ```bash
  grep -n "source.*booksy\|external_calendar_events\|status.*confirmed" src/lib/hooks/useCalendarEvents.ts
  ```
  Expected: `.eq('source', 'booksy')` AND `.in('status', ['confirmed'])` on the Booksy query.

### C10. Availability API filters Booksy `status='confirmed'` [CRITICAL]
- File: `src/app/api/bookings/availability/route.ts`
- Same grep as C9 applied here. A cancelled Booksy event must NOT block an availability slot.

### C11. Convert-to-booking idempotency [CRITICAL]
- File: `src/app/api/bookings/from-external/route.ts`
- Reads the event, returns 409 if `status='converted'` before any booking insert.
- On success, transitions the event to `status='converted'`.

### C12. Convert-to-booking uses only `barber_custom_services` [HIGH]
- Grep:
  ```bash
  grep -n "barber_custom_services\|barber_services\b" src/app/api/bookings/from-external/route.ts
  ```
  Expected: reads `barber_custom_services` only. `barber_services` is deprecated (see MEMORY.md) and must not appear here.

### C13. Service-role client is the only writer to Booksy tables [CRITICAL]
- Grep:
  ```bash
  grep -rn "external_calendar_events\|booksy_sync_logs" src/app/ src/lib/
  ```
  Review each hit: writes should happen only in the inbound webhook, from-external route, and owner log viewer (reads only). Any write from an RSC or browser client is a leak.

### C14. All Supabase client factories include `cache: 'no-store'` [HIGH]
Per MEMORY.md "Next.js 14 Data Cache" rule. A cached webhook query can return stale `booksy_sync_email` lookups.
- Files to check:
  - `src/lib/supabase/admin.ts`
  - `src/lib/supabase/server.ts`
  - Any inline `createClient` in the parser-related routes.
- Grep:
  ```bash
  grep -rn "cache: 'no-store'" src/lib/supabase/ src/app/api/webhooks/resend/ src/app/api/bookings/from-external/
  ```

### C15. Parser unit tests cover English AND Spanish [HIGH]
- File: `tests/unit/booksy-parser.test.ts`
- Every supported email type (new/rescheduled/cancelled) must have at least one test fixture per language. If Spanish coverage is missing, the keyword switch can regress silently.

### C16. Father+son split threshold stays at 75 min [MEDIUM]
- File: `src/app/api/bookings/from-external/route.ts`
- Changing this constant silently without updating docs will cause either missed splits (if raised) or unwanted splits (if lowered).
- Grep:
  ```bash
  grep -n "75\b" src/app/api/bookings/from-external/route.ts
  ```

---

## Load-bearing invariants summary

If ANY of these regress, the system is actively misbehaving in production:

- C1 — Spanish support. Half the barbers receive Spanish emails.
- C2 — EDT/EST round-trip. Every non-round-trip produces a 4-hour offset bug.
- C3 — No banned TZ patterns. One slip re-introduces the Ron Whitaker incident (2026-03-28).
- C4 — Svix signature. Missing = anyone can spoof appointment rows.
- C9/C10 — `status='confirmed'` filters. Missing = cancelled appointments block slots and render on calendars forever.
- 1/2 — message_id UNIQUE + no duplicates. Missing = duplicate appointments on every Resend retry.
- 9/11 — barber config consistency. Missing = silent drops for that barber.
