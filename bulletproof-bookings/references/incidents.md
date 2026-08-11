# Bookings Incident Registry

---

## Booksy Timezone Bug (2026-03-28)

**Symptom:**
- Ron Whitaker's 8 AM EDT appointment appears at noon on the calendar
- Appointments shift 4 hours forward (EDT) or 5 hours (EST)
- Wednesday bookings appear on Tuesday

**Root cause:**
Vercel UTC runtime. Raw `toISOString().split('T')[0]`, `getDay()`, `getHours()`, `toTimeString().slice()` return UTC values. Without `timeZone: 'America/New_York'`, date/time calculations are off by the timezone offset.

**Correct patterns:**
- Date: `date.toLocaleDateString('en-CA', { timeZone: 'America/New_York' })` → `YYYY-MM-DD`
- Time 24h: `date.toLocaleTimeString('en-GB', { timeZone: 'America/New_York', hour: '2-digit', minute: '2-digit', hour12: false })` → `HH:MM`

**Files fixed:**
- `src/app/api/bookings/from-external/route.ts`
- `src/app/api/bookings/resend/inbound/route.ts` (notifications + `resolveBarberLocation`)
- `src/app/api/bookings/migrate-appointments/route.ts`

**Safe (already correct):**
- `src/app/api/bookings/availability/route.ts` — uses ET throughout
- `src/lib/booksy/parser.ts` — handles EDT/EST offset detection

**Calendar filter:** `src/lib/hooks/useCalendarEvents.ts` filters Booksy events with `.in('status', ['confirmed'])` — excludes both `cancelled` AND `converted`.

**Diagnose checklist:**
1. Find where the wrong timestamp is rendered or written.
2. Grep for banned patterns in that file + its callees.
3. Fix with Eastern-aware patterns.

---

## Overbooking Prevention — btree_gist Constraint (2026-04-01)

**Symptom:**
- Two bookings appear in the same time slot for the same barber
- Calendar shows overlap
- Second booking was accepted despite an existing one

**Root cause (historical):**
Before migration `20260401000000_booking_overbooking_constraint.sql`, the availability API's overlap check had race conditions under concurrent booking attempts.

**Correct behavior (current):**
DB-level EXCLUDE constraint `bookings_no_time_overlap`:
- Uses btree_gist to prevent overlapping tsrange on `(barber_id, scheduled_date+scheduled_time, duration)`
- Partial: WHERE `status IN ('confirmed','pending','in_progress')` AND `deleted_at IS NULL`
- Second booking insert raises a Postgres exclusion constraint violation — app code catches this and returns a user-friendly error.

**Invariant:** The constraint must NEVER be dropped. Any app-code "overlap check" is defense in depth, not replacement.

**Diagnose:**
1. Run audit query: does the constraint exist?
2. If a duplicate slipped through, query whether BOTH rows have the guarded status. If one is `completed` or `cancelled`, the constraint correctly allowed it (completed bookings don't block future slots of the same stamp).

---

## In-Progress Bookings Block Availability

**Symptom (user confusion, not a bug):**
- Barber is mid-service with Client A at 2:00 PM
- Client B tries to book 2:30 PM on the public wizard
- 2:30 is shown unavailable even though it's 30 min from now

**Behavior:** Correct. Availability API filters `status IN ('confirmed','pending','in_progress')` — in_progress bookings block subsequent slots for their duration.

**When to diagnose:** Only if an in_progress booking is stuck (stale because the barber didn't complete it). Check if the user actually wants `quick-complete` or `no_show` flow. File: `src/app/api/bookings/quick-complete/route.ts`.

---

## Soft-Delete Filter Missing

**Symptom:**
- A booking was cancelled/deleted but still appears on a calendar
- Wrong count in "today's bookings"
- Cross-comparison between old and new UI shows different totals

**Root cause:**
Some query missed `.is('deleted_at', null)`. Soft-deleted rows leak in.

**Correct pattern:**
Every non-admin booking query applies `.is('deleted_at', null)`. Utilities in `src/lib/db/bookings.ts` do this. Hooks in `src/lib/hooks/useBookings.ts` and `useCalendarEvents.ts` do this.

**Diagnose:**
```bash
grep -rn "from.*bookings\|('bookings')" src/app/api/ src/lib/ | grep -v deleted_at
```
Then cross-reference with file-by-file review. Any file that queries `bookings` without a soft-delete filter is suspect.

---

## Confirmation Code Collision / Public Manage 404

**Symptom:**
- `/book/manage/[code]` returns "booking not found" even though the user has a valid code
- Rate limit appears to fire on valid traffic

**Root cause (rare):**
`nanoid(6)` gives ~2.1 billion codes; collision virtually impossible. If it happens, the UNIQUE partial index catches it at INSERT time.

If 404: more likely the code was entered with wrong casing or the booking was cancelled. The manage endpoint returns 404 for cancelled bookings (`.neq('status', 'cancelled')`).

**Diagnose:**
1. Check the code in the URL vs. DB: `SELECT id, status FROM bookings WHERE confirmation_code = 'MT-XXXXXX'` (admin query).
2. If status is `cancelled`, the endpoint correctly returns 404 — customer must book fresh.
3. If status is NULL or anything else — the endpoint has a regression.

---

## Cancel/Reschedule Flow — Known Open Bugs

From `.planning/TODO.md` (as of last audit):

- **Bug #3:** Calendar cancel has no confirmation dialog — `CalendarEventDetailModal` line ~515 fires cancel directly on click. UNRESOLVED.
- **Bug #4:** Stripe webhook cancel notification — placeholder at `api/webhooks/stripe/route.ts:520`. DEFERRED (Twilio/Antigravity blocker).

**If a user reports "I accidentally cancelled a booking":** this is Bug #3. Report it, don't silently fix (still pending user decision).

---

## "Any Barber" Does NOT Apply to Bookings

**User confusion (not a bug):**
- User on `/queue` selects "Any Barber" — system assigns via fair rotation
- User on `/book` must select a specific barber — no "Any Barber" option

**Invariant:** The booking wizard (`/src/app/(public)/book/page.tsx` step 2) requires explicit barber selection. The `/api/bookings/quick` route CAN accept `barber_id=null` as a future capability but the public wizard does not surface it.

If a barber asks "why can't my bookings go through Any Barber rotation" — explain this is by design. Advance bookings commit to a specific barber; walk-ins take whoever's free.

---

## Reminder SMS Duplicates

**Symptom:**
- Client gets the same 24h reminder SMS twice
- Client gets a reminder for a cancelled booking

**Root cause (to verify):**
`reminder_sent` flag not updated atomically with SMS send, or SMS sent before soft-delete/cancel filter was added.

**Correct pattern:**
Reminder cron `src/app/api/bookings/reminders/route.ts`:
1. Query bookings where `scheduled_date` in [now, now+25h] AND `reminder_sent = false` AND `status = 'confirmed'` AND `deleted_at IS NULL`.
2. Send SMS via Twilio.
3. UPDATE `reminder_sent = true` in same request.

**Diagnose:**
1. Read the file. Verify the UPDATE happens after SMS success.
2. Check `.is('deleted_at', null)` is present in the SELECT.
3. Check the status filter excludes cancelled/completed.

---

## Slot Grid Alignment (2026-04-27 — locked)

**Background:**
Before 2026-04-27 the slot grid was hardcoded to 30 minutes everywhere — the customer booking page, the dashboard manual-add sheet, and the reschedule modal all generated slots at `interval = 30` with `Math.ceil(start / 30) * 30`. Result: a 60-min haircut could be booked at 9:30, ending 10:30, then the next 60-min slot was 10:30→11:30, walking the day off the hour grid. Production data showed ~5% of native bookings were off the 30-min grid; owner Gustavo wanted his 60-min cuts on the hour only. Booksy-imported bookings carried whatever time Booksy gave us (more drift).

**Behavior shipped (`feat(bookings)` commit `0c0c0ff`, deploy `dpl_5aq3ANp6c7ZAdMvv1idJNwthfvgw`):**
The slot grid steps by the **selected service's duration_minutes**, anchored to the barber's `barber_schedules.start_time` for that day.
- 30-min service at 9:00 start → 9:00, 9:30, 10:00, 10:30, ...
- 60-min service at 9:00 start → 9:00, 10:00, 11:00, ...
- 45-min service at 9:00 start → 9:00, 9:45, 10:30, 11:15, ... (the math, not a bug)
- 90-min service at 9:00 start → 9:00, 10:30, 12:00, ...

**Server contract:** the 3 native write paths (`bookings/route.ts`, `bookings/quick/route.ts`, `bookings/[id]/reschedule/route.ts`) call `isOnSlotGrid` from `src/lib/utils/booking-slot.ts` and return `400 { error: 'OFF_GRID_SLOT', detail: ... }` on fail. `from-external/route.ts` (Booksy import) is intentionally exempt and keeps the literal time.

**API contract:** `/api/bookings/availability` returns `slotInterval: <requestedDuration>` in its JSON. Removing or renaming this field breaks `TimeSlotPicker.tsx` and `ManualBookingSheet.tsx`.

**Existing pre-fix bookings:** NOT migrated. Audit query #17 in `audit-queries.sql` filters out anything created before 2026-04-27 plus Booksy-tagged rows (`notes LIKE '%Booksy%'`) so the off-grid count only catches new violations.

**Symptoms that map to this rule:**
- "I see slots like 9:15 / 10:45 on the booking page that shouldn't be there." → check that the API response includes `slotInterval` and the UI is reading it.
- "Booking creation returns 400 OFF_GRID_SLOT." → expected behavior; the input time isn't on the grid. Fix the caller to pick a valid slot.
- "Reschedule rejects times I just saw on the picker." → check that the picker is fetching availability with the booking's actual `duration_minutes`, not a default 30.

**Diagnose:**
1. `grep -rn 'interval = 30' src/components/booking/ src/components/dashboard/calendar/ src/app/api/bookings/` — should return ZERO results in active code paths. If a hardcoded 30 leaks back in, that's the bug.
2. `grep -rn 'isOnSlotGrid' src/app/api/bookings/` — must show 3 imports + calls in `route.ts`, `quick/route.ts`, `[id]/reschedule/route.ts`. If any is missing, that path will accept off-grid bookings silently.
3. Run audit-queries.sql query #17. Any non-zero row count = a write path slipped past the check (or a new from-external import is mis-tagged).

**HARD RULE for fix mode:** never re-introduce the 30-min hardcode "for simplicity." The grid IS the simplicity — duration drives interval, period. Adding a per-barber override column is a feature change, not a bug fix.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Times off by 4-5h | Booksy Timezone Rule | the file writing/rendering the timestamp |
| Double-booking same barber | btree_gist constraint missing or dropped | run audit query for the constraint |
| Cancelled booking still on calendar | soft-delete filter missing | the specific hook/query showing it |
| Public manage 404 | cancelled status or wrong code | query DB directly |
| Duplicate reminder SMS | reminder_sent flag race | `src/app/api/bookings/reminders/route.ts` |
| Client wants "Any Barber" for advance booking | not a bug — explain by-design | - |
| Booking time at :15/:45 from native flow | Slot Grid Alignment regression | `src/lib/utils/booking-slot.ts` + the 3 write routes |
| 400 OFF_GRID_SLOT on a previously-valid time | Service duration changed mid-flow OR client sent stale time | the caller (TimeSlotPicker / ManualBookingSheet) |
