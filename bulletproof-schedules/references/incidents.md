# Schedules Incident Registry

---

## Per-Day Location Overwrite (commit `d03b8ef`, 2026-04-19)

**Symptom (as user sees it):**
- Barber changes schedule on `/barber/schedule` or `/dashboard/my-chair/schedule`
- One day's location change saves correctly
- Other days silently revert to a single "preferred" location
- Dashboard shows barber at wrong location on certain days
- Booking confirmation shows wrong address for certain weekdays

**Root cause:**
Previous code in `src/app/api/barber/schedule/route.ts` resolved a single `preferred_location_id` up front and wrote it to ALL inserted schedule rows on save. Per-day assignments set by the owner or by earlier saves got overwritten.

**Correct implementation (after d03b8ef):**
1. Read existing `barber_schedules` rows FIRST, build `existingLocationByDay: Record<number, string>` map.
2. Delete old rows.
3. Re-insert rows, keeping each day's prior `location_id` verbatim.
4. Fall back to `barbers.preferred_location_id` → `staff_status.location_id` ONLY for brand-new days that had no prior row.
5. Return 400 if a day needs the fallback AND none is available.
6. Ignore `locationId` from the request body — barbers cannot change location via this endpoint (use the location-request workflow).

**File:** `src/app/api/barber/schedule/route.ts` lines ~129-193.

**Diagnose checklist:**
1. Read the file. Confirm step 1 (read-first) exists and isn't accidentally removed.
2. Verify `existingLocationByDay` map is populated BEFORE the delete.
3. Verify each inserted row uses `existingLocationByDay[day_of_week]` with fallback only for missing days.
4. Check `git log --oneline src/app/api/barber/schedule/route.ts` — commit `d03b8ef` should be present.

---

## Booksy Timezone Rule (2026-03-28)

**Symptom:**
- Booking created at 8 AM EDT shows as noon on the calendar
- Wrong day of week for appointments
- Schedule availability returns slots that are 4-5 hours off

**Root cause:**
Vercel runs UTC. `toISOString().split('T')[0]`, `getDay()`, `getHours()`, `toTimeString().slice()` return UTC values when the developer expected Eastern. Without explicit `timeZone: 'America/New_York'`, the value the database stores or the UI renders is wrong.

**Correct patterns:**
- Date: `date.toLocaleDateString('en-CA', { timeZone: 'America/New_York' })` → `YYYY-MM-DD`
- Time 24h: `date.toLocaleTimeString('en-GB', { timeZone: 'America/New_York', hour: '2-digit', minute: '2-digit', hour12: false })` → `HH:MM`
- Day of week: `date.toLocaleDateString('en-US', { timeZone: 'America/New_York', weekday: 'short' })` then map to number

**Files fixed:**
- `src/app/api/bookings/from-external/route.ts`
- `src/app/api/bookings/resend/inbound/route.ts`
- `src/app/api/bookings/migrate-appointments/route.ts`

**Safe (already correct):**
- `src/app/api/bookings/availability/route.ts` — uses ET throughout (lines 232, 262, 271, 290)
- `src/lib/booksy/parser.ts`

**Diagnose checklist:**
1. `grep -rn "toISOString().split('T')" src/app/api/bookings/ src/lib/`
2. `grep -rn "\.getDay()\|\.getHours()" src/app/api/bookings/`
3. Any match must be accompanied by `timeZone: 'America/New_York'` upstream (the Date object already localized) OR fixed to use `toLocaleDateString('en-CA', ...)`.

---

## Location Change Request — Dual-Update Missing

**Symptom:**
- Barber requests location change for Friday to Newark
- Owner approves
- Barber's `/barber/schedule` shows Newark on Friday correctly
- But at the moment of approval, if barber is clocked in, queue check-ins at Wilmington still route to the barber
- Barber's `staff_status.location_id` stayed on Wilmington

**Root cause:**
PATCH handler in `src/app/api/barber/location-request/route.ts` updated `barber_schedules` only, not `staff_status`. The queue and TV display read from `staff_status.location_id` in real-time.

**Correct implementation:**
When a request is approved, the PATCH handler must:
1. Update `barber_schedules` row for that (barber_id, day_of_week) with the new `location_id`.
2. If the approval is for TODAY and the barber has a `staff_status` row with status in (`clocked_in`, `on_break`, `with_client`), update `staff_status.location_id` atomically so queue routing takes effect immediately.
3. Set `status='approved'`, `reviewed_by=owner_profile_id`, `reviewed_at=now()`.

**Diagnose checklist:**
1. Read `src/app/api/barber/location-request/route.ts` PATCH handler.
2. Confirm both updates (barber_schedules + conditional staff_status) happen in the same transaction.
3. Verify the conditional check: approval date = today AND barber currently clocked in.

---

## `preferred_location_id` Column Drift Risk

**Symptom:**
- Schedule save returns 500 error
- Error mentions `column barbers.preferred_location_id does not exist`
- Works in production but fails on a fresh dev DB

**Root cause:**
`barbers.preferred_location_id` is referenced in code (`src/app/api/barber/schedule/route.ts`, `src/app/api/barber/location/route.ts`) but the column does NOT appear in any committed migration file. The column was manually added to production Supabase.

**Impact:**
- Code uses `(admin as any)` type assertion to bypass TypeScript check.
- Any fresh environment without the manual column addition will break on schedule save when falling back to preferred location for a new day.
- Adding a new location is affected: new-location fallback chain assumes this column works.

**Resolution (not a fix, a note):**
- Flag to user during scale-check and diagnose.
- Suggest creating a migration file to make the column explicit and survive fresh DB setups.
- Do NOT silently add the migration — explicit user approval required.

**Diagnose query:**
```sql
SELECT column_name
FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'preferred_location_id';
-- Expected: 1 row (it exists). If 0 rows: flag as missing migration.
```

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Per-day location resets on save | d03b8ef regression | `src/app/api/barber/schedule/route.ts` |
| Wrong day-of-week or 4h-off times | Booksy Timezone Rule | the file that renders/writes the timestamp |
| Approved location request, queue still routes old | location-request dual-update missing | `src/app/api/barber/location-request/route.ts` PATCH |
| "column barbers.preferred_location_id does not exist" | column drift | migration audit |
| Barber invisible in booking despite active | missing barber_schedules rows | run audit query 13 from bulletproof-queue |
