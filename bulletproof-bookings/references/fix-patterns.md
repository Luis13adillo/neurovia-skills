# Bookings — Fix Patterns

Paste-ready patterns for the MT Barbershop bookings system. When the audit (`SKILL.md` → audit mode) flags a failure, point to a numbered pattern here and the user gets a concrete change. These patterns are canonical — if you deviate, document why and confirm before editing.

Every pattern cites either an incident from `references/incidents.md` or an invariant from `references/invariants.md`. Do not invent patterns — if the gap is new, write a real incident first, then add the pattern.

All patterns assume:
- `createClient` imported from `@/lib/supabase/server` for user-authed routes
- `createAdminClient` imported from `@/lib/supabase/admin` for cron / webhook / service-role contexts
- Supabase factories wrap `global.fetch` with `cache: 'no-store'` (do NOT strip this — see the Next.js 14 Data Cache rule in `MEMORY.md`)
- Eastern Time is `America/New_York`. Vercel runs UTC. Every `toLocaleDateString` / `toLocaleTimeString` / `getDay` / `getHours` call MUST pass `{ timeZone: 'America/New_York' }`.

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Run this sequence for EVERY pattern before the Edit. All steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "Before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If anything differs → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Is this live breakage (customer-visible right now) or latent (defensive hardening)? Run the relevant audit query in `references/audit-queries.sql` or the grep listed in SKILL.md. Report finding to user.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes` before editing.
4. **Apply** — Single `Edit` call. One pattern per invocation. Never bundle unrelated patterns.
5. **Verify** — Run the pattern's "Post-fix verification" (grep + `npx tsc --noEmit` + SQL probe if data-level). Every check must pass.
6. **Mirror** — If the change touches a dashboard page (`/barber/calendar`, `/dashboard/my-chair/calendar`, etc.), invoke the `mirror-check` skill. API-only routes do not need mirroring.
7. **Handoff** — Stop at `bulletproof-ship`. Do NOT commit from this skill. Never write directly to main.

If any step fails, stop and report. Do not proceed.

---

## Pattern 1 — Booksy timezone: date computed in UTC instead of Eastern

**When:** Symptom is "appointment appears on wrong day" or "time is shifted 4–5 hours." A date or day-of-week is derived without `timeZone: 'America/New_York'`.

Cites: `incidents.md` → "Booksy Timezone Bug (2026-03-28)" and `invariants.md` → C2, C4.

**Before:**
```ts
// src/app/api/bookings/from-external/route.ts (or resend/inbound, or barber/migrate-appointments)
const scheduledDate = appointmentDate.toISOString().split('T')[0]
const dayOfWeek = appointmentDate.getDay()
const scheduledTime = appointmentDate.toTimeString().slice(0, 5)
```

**After:**
```ts
const scheduledDate = appointmentDate.toLocaleDateString('en-CA', {
  timeZone: 'America/New_York',
}) // YYYY-MM-DD in ET

const scheduledTime = appointmentDate.toLocaleTimeString('en-GB', {
  timeZone: 'America/New_York',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
}) // HH:MM in ET

const dayShort = appointmentDate.toLocaleDateString('en-US', {
  timeZone: 'America/New_York',
  weekday: 'short',
}) // Mon, Tue, ...
const dayOfWeek = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(dayShort)
```

**Post-fix verification:**
- `grep -n "toISOString().split('T')" src/app/api/bookings/from-external/route.ts src/app/api/webhooks/resend/inbound/route.ts src/app/api/barber/migrate-appointments/route.ts` → 0 matches
- `grep -n "toTimeString().slice" <same files>` → 0 matches
- `grep -n "America/New_York" <edited file>` → ≥1 match per date/time extraction
- `npx tsc --noEmit` → no new errors
- Data probe: `SELECT id, scheduled_date, scheduled_time FROM bookings WHERE barber_id = '<test>' ORDER BY created_at DESC LIMIT 5;` — times match what Booksy shows in Eastern.

---

## Pattern 2 — Availability API missing `in_progress` in status filter

**When:** Customer books a slot while a barber is mid-service with the previous client — duplicate booking slips through because availability didn't see the in-progress booking.

Cites: `incidents.md` → "In-Progress Bookings Block Availability" and `invariants.md` → C2, data invariant #2.

**Before:**
```ts
// src/app/api/bookings/availability/route.ts
const { data: conflicts } = await supabase
  .from('bookings')
  .select('scheduled_time, duration_minutes')
  .eq('barber_id', barberId)
  .eq('scheduled_date', date)
  .in('status', ['confirmed', 'pending'])
  .is('deleted_at', null)
```

**After:**
```ts
const { data: conflicts } = await supabase
  .from('bookings')
  .select('scheduled_time, duration_minutes')
  .eq('barber_id', barberId)
  .eq('scheduled_date', date)
  .in('status', ['confirmed', 'pending', 'in_progress'])
  .is('deleted_at', null)
```

**Post-fix verification:**
- `grep -n "'confirmed'" src/app/api/bookings/availability/route.ts` — every `.in('status', ...)` on bookings must include `'in_progress'`.
- Data probe (invariant #2): run the overlap SQL from `invariants.md` → 0 rows.
- Manual: with one `in_progress` booking at 2:00 PM / 30 min duration, the availability call for 2:15 PM slot returns unavailable.

---

## Pattern 3 — Overlap constraint bypass attempt in app code

**When:** A reviewer or junior dev added an app-level "overlap check" that short-circuits around the DB constraint. OR the constraint was dropped in a migration.

Cites: `incidents.md` → "Overbooking Prevention — btree_gist Constraint (2026-04-01)" and `invariants.md` → data invariant #1.

**Before (wrong — deletes the guardrail):**
```sql
-- some new migration
ALTER TABLE bookings DROP CONSTRAINT bookings_no_time_overlap;
```
OR
```ts
// app code that treats overlap as a soft warning and inserts anyway
const { data: existing } = await supabase.from('bookings').select('id').eq(...)
if (existing?.length) console.warn('overlap') // BUT STILL INSERTS
```

**After:** Do not drop the constraint. App code MUST surface the Postgres `exclusion_violation` (SQLSTATE `23P01`) as a user-friendly 409 and stop.

```ts
const { data: inserted, error } = await supabase.from('bookings').insert(row).select().single()
if (error) {
  if (error.code === '23P01' || /bookings_no_time_overlap/.test(error.message)) {
    return NextResponse.json(
      { error: 'That slot was just taken. Please pick another time.' },
      { status: 409 }
    )
  }
  throw error
}
```

**Post-fix verification:**
- Run invariant #1 SQL from `invariants.md` — constraint exists, 1 row.
- `grep -rn "DROP CONSTRAINT bookings_no_time_overlap" supabase/migrations/` → 0 matches.
- Two concurrent `curl` inserts against `/api/bookings/quick` for the same barber+time → exactly one 200, one 409. Never two 200s.

---

## Pattern 4 — Soft-delete filter missing on a booking query

**When:** A cancelled/deleted booking still shows up on a calendar, a report, or the public manage page. Any `bookings` query without `.is('deleted_at', null)`.

Cites: `incidents.md` → "Soft-Delete Filter Missing" and `invariants.md` → C3.

**Before:**
```ts
// src/lib/hooks/useBookings.ts or a new API route
const { data } = await supabase
  .from('bookings')
  .select('*')
  .eq('barber_id', barberId)
  .gte('scheduled_date', todayISO)
```

**After:**
```ts
const { data } = await supabase
  .from('bookings')
  .select('*')
  .eq('barber_id', barberId)
  .gte('scheduled_date', todayISO)
  .is('deleted_at', null)
```

**Scope limit:** ONLY add `.is('deleted_at', null)` where it's missing. Do NOT refactor the surrounding query, rename variables, or change selected columns.

**Post-fix verification:**
- `grep -rn "from('bookings')" src/app/api/ src/lib/ | grep -v "deleted_at\|admin\|reports/cancelled"` — every remaining result must be an explicit admin/reporting exception. If in doubt, add the filter.
- `grep -n ".is('deleted_at', null)" <edited file>` → ≥1 match on the edited query.
- Data probe: soft-delete a test booking (`UPDATE bookings SET deleted_at = now() WHERE id = '<test>'`) — confirm the affected UI surface stops showing it on refresh.

Reminder: the Supabase factory `fetch` wrapper already disables the Next.js Data Cache. `export const dynamic = 'force-dynamic'` alone is not enough. Do NOT touch the cache config while fixing soft-delete.

---

## Pattern 5 — `useCalendarEvents` leaks cancelled/converted Booksy events

**When:** Cancelled Booksy appointments still render on the barber/owner calendar. Typically a missing `.in('status', ['confirmed'])` on the `external_calendar_events` fetch.

Cites: `incidents.md` → calendar filter paragraph in "Booksy Timezone Bug" and `invariants.md` → data invariant #13.

**Before:**
```ts
// src/lib/hooks/useCalendarEvents.ts
const { data: booksy } = await supabase
  .from('external_calendar_events')
  .select('*')
  .eq('barber_id', barberId)
  .eq('source', 'booksy')
```

**After:**
```ts
const { data: booksy } = await supabase
  .from('external_calendar_events')
  .select('*')
  .eq('barber_id', barberId)
  .eq('source', 'booksy')
  .in('status', ['confirmed']) // excludes cancelled AND converted
```

**Post-fix verification:**
- `grep -n "external_calendar_events" src/lib/hooks/useCalendarEvents.ts` — every `.from('external_calendar_events')` read must have `.in('status', ['confirmed'])`.
- `npx tsc --noEmit` → clean.
- Mirror check: `/barber/calendar` and `/dashboard/my-chair/calendar` both consume this hook — invoke the `mirror-check` skill before handoff.

---

## Pattern 6 — Reschedule integrity: old slot stays blocked after PATCH

**When:** Barber reschedules a booking from 2 PM → 3 PM. Availability API still returns 2 PM as blocked.

Cites: `invariants.md` → data invariant #2 (no overlaps) and #12 (in_progress start_time) + `incidents.md` → "Cancel/Reschedule Flow — Known Open Bugs."

**Root cause check first:** The reschedule handler lives in `src/app/api/bookings/[id]/route.ts`. Confirm the PATCH updates `scheduled_date` AND `scheduled_time` atomically, and does NOT create a new row while leaving the old one in a guarded status.

**Before (wrong — insert-then-soft-delete pattern breaks the constraint window):**
```ts
// Pseudo — create new + mark old cancelled in two statements
await supabase.from('bookings').insert({ ...newRow })
await supabase.from('bookings').update({ status: 'cancelled' }).eq('id', oldId)
```

**After:** UPDATE the existing row. The btree_gist exclusion constraint is evaluated on UPDATE too, so the new time is checked against everyone else's bookings atomically.
```ts
const { data, error } = await supabase
  .from('bookings')
  .update({
    scheduled_date: newDate,
    scheduled_time: newTime,
    reminder_sent: false,          // re-arm reminders
    one_hour_reminder_sent: false, // re-arm reminders
  })
  .eq('id', bookingId)
  .is('deleted_at', null)
  .select()
  .single()

if (error?.code === '23P01') {
  return NextResponse.json({ error: 'New slot conflicts with another booking.' }, { status: 409 })
}
```

**Post-fix verification:**
- Run invariant #2 overlap SQL → 0 rows.
- Rearm check: `SELECT reminder_sent, one_hour_reminder_sent FROM bookings WHERE id = '<rescheduled>'` → both `false`.
- Availability probe: GET `/api/bookings/availability?barber_id=<id>&date=<date>` for both the old and new slot — old is free, new is taken.
- SMS: confirm only the reschedule SMS sends, not a new confirmation + a cancel SMS (the known Bug #4 limitation from `incidents.md` — flag if it regresses).

---

## Pattern 7 — Confirmation code collision / public manage 404

**When:** `/book/manage/[code]` returns 404 despite a valid-looking code. Either the UNIQUE index is missing, or the endpoint incorrectly filters cancelled bookings, or the code wasn't generated with `MT-` prefix.

Cites: `incidents.md` → "Confirmation Code Collision / Public Manage 404" and `invariants.md` → C7, data invariant #6.

**Before:**
```ts
// src/app/api/bookings/route.ts POST handler
const confirmationCode = nanoid(6) // missing 'MT-' prefix
```
OR
```ts
// src/app/api/bookings/manage/[code]/route.ts
const { data } = await supabase
  .from('bookings')
  .select('*')
  .eq('confirmation_code', code)
  .single() // no soft-delete filter, no cancelled filter — OK to return cancelled
```

**After (generation):**
```ts
const confirmationCode = `MT-${nanoid(6).toUpperCase()}` // matches ^MT-[A-Z0-9]{6}$
```

**After (manage lookup — intentional behavior):**
```ts
const { data, error } = await supabase
  .from('bookings')
  .select('id, status, ...')
  .eq('confirmation_code', code)
  .is('deleted_at', null)
  .neq('status', 'cancelled') // correct — cancelled bookings should 404
  .maybeSingle()
if (!data) return NextResponse.json({ error: 'Booking not found' }, { status: 404 })
```

**Post-fix verification:**
- Invariant #6 SQL → 0 duplicate codes, 0 malformed codes.
- Migration present: `ls supabase/migrations/20260326000000_unique_confirmation_code.sql`.
- Manual: cancel a test booking, hit `/book/manage/<code>` → 404. Create a new booking → code starts with `MT-`, 6 upper-alnum chars, manage page loads.

---

## Pattern 8 — Reminder cron missing `CRON_SECRET` auth or soft-delete filter

**When:** Duplicate reminder SMS, reminders to cancelled bookings, or the reminder endpoint is publicly callable.

Cites: `incidents.md` → "Reminder SMS Duplicates" and `invariants.md` → C5, data invariant #8.

**Before:**
```ts
// src/app/api/bookings/reminders/route.ts
export async function GET(req: NextRequest) {
  const supabase = await createClient()
  const { data: upcoming } = await supabase
    .from('bookings')
    .select('*')
    .gte('scheduled_date', now)
    .eq('reminder_sent', false)
  // ... sends SMS, then later updates reminder_sent
}
```

**After:**
```ts
export async function GET(req: NextRequest) {
  // 1. Auth — reject anyone without CRON_SECRET
  const authHeader = req.headers.get('authorization')
  if (authHeader !== `Bearer ${process.env.CRON_SECRET}`) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const admin = createAdminClient() // cron has no Supabase session; RLS would block user client

  const { data: upcoming } = await admin
    .from('bookings')
    .select('*')
    .gte('scheduled_date', now)
    .eq('reminder_sent', false)
    .eq('status', 'confirmed')      // never remind cancelled / no_show / completed
    .is('deleted_at', null)         // never remind soft-deleted

  for (const b of upcoming ?? []) {
    const smsOk = await sendReminderSMS(b).catch(() => false)
    if (smsOk) {
      await admin.from('bookings').update({ reminder_sent: true }).eq('id', b.id)
      // ^ UPDATE only on SMS success, same request — prevents duplicate sends on retry
    }
  }
}
```

**Post-fix verification:**
- `grep -n "CRON_SECRET" src/app/api/bookings/reminders/route.ts` → ≥1 match in GET handler.
- `grep -n ".is('deleted_at', null)" src/app/api/bookings/reminders/route.ts` → ≥1 match.
- `grep -n "status.*confirmed" src/app/api/bookings/reminders/route.ts` → ≥1 match.
- `curl https://mtbarbershop.com/api/bookings/reminders` (no auth) → 401.
- `curl -H "Authorization: Bearer $CRON_SECRET" …` → 200 with sent count.

---

## Pattern 9 — Hardcoded location name/address in email or SMS template

**When:** Scale-check flags a direct reference to "Wilmington" / "Kirkwood Hwy" / etc. in a template. Breaks the moment you add location #5, AND drops cross-state state handling for Edwardsville, PA.

Cites: `CLAUDE.md` → "HARD RULE — Location Data Is Sacred" and `MEMORY.md` → Cross-state email fix (2026-04-20).

**Before:**
```ts
// src/lib/email/templates/booking-confirm.ts
return `
  MT Barbershop
  3616 Kirkwood Hwy, Wilmington, DE 19808
  See you soon.
`
```

**After:**
```ts
// Accept location fields from the caller. Pass locationState from DB; never hardcode ', DE'.
export function bookingConfirmEmail(input: {
  locationName: string
  locationAddress: string
  locationCity: string
  locationState: string // 'DE' or 'PA' — from locations.state, never default to 'DE' at call site
  locationZip: string
}) {
  return `
    MT Barbershop — ${input.locationName}
    ${input.locationAddress}, ${input.locationCity}, ${input.locationState} ${input.locationZip}
    See you soon.
  `
}
```

**Post-fix verification:**
- `grep -rn "Wilmington\|Newark\|New Castle\|Edwardsville" src/lib/email/ src/lib/twilio/ src/app/api/bookings/` → 0 matches (copy tests are allowed to reference the name in audit strings, not templates).
- `grep -rn "Kirkwood Hwy\|Marrows Rd\|Penn Mart\|Gateway Shopping" src/lib/email/ src/lib/twilio/` → 0 matches.
- `grep -rn '", DE"' src/lib/email/` → 0 matches.
- Send a test booking for Edwardsville → email footer reads `…, PA 18704`, not `…, DE`.

---

## Pattern 10 — `locations[0]` fallback inside booking flow

**When:** Scale-check flags a `locations[0]?.id` or `locations[0].slug` in the booking wizard, the availability API, or the manage endpoint — a holdover from single-location days.

Cites: SKILL.md → "Mode: scale-check" step 3 and `CLAUDE.md` → Smart Location Routing.

**Before:**
```tsx
// src/app/(public)/book/page.tsx
const defaultLocation = locations[0]?.id
```

**After:** Location is derived from `barber_schedules` for the selected `(barber_id, day_of_week)`. If no schedule row, the UI must surface "barber not available that day" — do NOT silently fall back to location #1.
```tsx
// Fetch schedule-based location after barber + date are selected
const resolvedLocationId = await resolveBarberLocationForDate(barberId, selectedDate)
if (!resolvedLocationId) {
  setError("This barber isn't scheduled on that day. Pick another date.")
  return
}
```

**Post-fix verification:**
- `grep -rn "locations\[0\]" "src/app/(public)/book/" src/app/api/bookings/` → 0 matches.
- Manual: book MT on a Wednesday — confirmation email address matches the Wednesday location row in `barber_schedules`, not Wilmington by default.

---

## Cross-pattern rules

1. **Never drop, weaken, or inline-substitute `bookings_no_time_overlap`.** It is the only race-proof guard against double bookings.
2. **Never remove `.is('deleted_at', null)` from a consumer query** — even "for admin reasons." Admin reporting routes should be the only exceptions, explicitly commented.
3. **Always pass `{ timeZone: 'America/New_York' }`** to every `toLocaleDateString` / `toLocaleTimeString` / weekday / hour derivation that reads a timestamp written by or displayed to a customer.
4. **Never call `.single()` on a query that might return 0 rows** in the manage / confirmation-code / lookup paths — use `.maybeSingle()` so missing rows return null instead of throwing 500s.
5. **Never bypass `CRON_SECRET`** in any cron route. Opening reminders publicly would let anyone spam customers with SMS.
6. **Mirror-check is MANDATORY** for any edit under `src/app/(dashboard)/barber/**` or `src/app/(dashboard)/dashboard/my-chair/**`. API-only edits do not require mirror-check.
7. **Stop at `bulletproof-ship`.** This skill never commits. Never force-pushes. Never touches `main` directly.

---

## When adding a NEW booking-adjacent feature

Checklist before writing code:
1. Does it read `bookings`? Add `.is('deleted_at', null)` (Pattern 4).
2. Does it write `scheduled_date`/`scheduled_time`? Catch Postgres `23P01` and surface a 409 (Pattern 3).
3. Does it compute a day, date, or time from a `Date` object? Pass `timeZone: 'America/New_York'` (Pattern 1).
4. Does it run under cron or a webhook? Use `createAdminClient` and require `CRON_SECRET` (Pattern 8).
5. Does it build a confirmation-style URL? Use the `MT-XXXXXX` format and the UNIQUE partial index (Pattern 7).
6. Does it render an address? Accept all 5 fields — name/address/city/state/zip — from the DB. Never hardcode (Pattern 9).
7. Does it touch `/barber/calendar` OR `/dashboard/my-chair/calendar`? Plan the mirror edit before writing a line (Pattern 5 note).

If any check is "no", stop and fix before shipping.
