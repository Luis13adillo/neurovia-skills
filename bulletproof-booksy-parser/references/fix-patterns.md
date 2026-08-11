# Booksy Parser Fix Patterns

Each pattern is a small, SCOPED, reversible change that maps to a specific incident in `incidents.md`. Fix mode is OPT-IN — it only fires when the user says `apply pattern N` / `fix <symptom>` / `enter fix mode`.

Every pattern includes:
- **Symptom** — how the bug shows up.
- **Scope** — the exact files that may change. Anything outside this list = STOP and ask.
- **Before** — representative "bad" shape of the code. Line numbers will have drifted — match on structure.
- **After** — the minimal TZ-safe / bug-free replacement.
- **Post-fix check** — the grep or SQL or test you run to confirm it worked.
- **Mirror impact** — whether cross-dashboard mirror enforcement applies.

Do not bundle patterns. One fix-mode invocation = one pattern.

---

## Pattern #1: Restore `America/New_York` timezone extraction

### Symptom
A Booksy event lands 4 hours off. A grep finds a banned pattern in `src/lib/booksy/` or a Booksy-adjacent route.

### Scope
Any ONE of:
- `src/lib/booksy/parser.ts`
- `src/app/api/webhooks/resend/inbound/route.ts`
- `src/app/api/bookings/from-external/route.ts`
- `src/app/api/bookings/migrate-appointments/route.ts`

Do NOT broaden scope to other files in the same fix. If the grep finds hits in multiple files, ship one pattern per file.

### Before
```ts
const scheduledDate = startAt.toISOString().split('T')[0]
const scheduledTime = startAt.toTimeString().slice(0, 5)
```

### After
```ts
const scheduledDate = startAt.toLocaleDateString('en-CA', {
  timeZone: 'America/New_York',
})
const scheduledTime = startAt.toLocaleTimeString('en-GB', {
  timeZone: 'America/New_York',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
})
```

### Post-fix check
```bash
grep -rn "toISOString().split\|toTimeString().slice" src/lib/booksy/ src/app/api/webhooks/resend/ src/app/api/bookings/from-external/ src/app/api/bookings/migrate-appointments/
# Expected: 0 hits.
```
Then:
```bash
npx tsc --noEmit
npx tsx tests/unit/booksy-parser.test.ts
```

### Mirror impact
None — Booksy intake is single-path, not mirrored per-dashboard.

---

## Pattern #2: Add missing keyword to language switch

### Symptom
A known-valid Booksy subject (English or Spanish) produces `parse_status='skipped'` because the type-detection switch doesn't recognize it.

### Scope
- `src/lib/booksy/parser.ts` — the type-detection section of `parseBooksyEmail()`.
- `tests/unit/booksy-parser.test.ts` — add a fixture that would have caught this.

### Before
```ts
if (s.includes('new appointment') || s.includes('nueva reserva')) {
  return 'new'
}
```

### After
```ts
if (
  s.includes('new appointment') ||
  s.includes('new booking') ||
  s.includes('booking confirmation') ||
  s.includes('nueva reserva') ||
  s.includes('nueva cita') ||
  s.includes('confirmación de reserva')
) {
  return 'new'
}
```

Exact keywords list → `references/parser-languages.md`. Only add the specific keyword being missed, plus any obvious sibling terms on the same language path.

### Post-fix check
- `npx tsx tests/unit/booksy-parser.test.ts` — includes new fixture and passes.
- `npx tsc --noEmit`.

### Mirror impact
None.

---

## Pattern #3: Fix reschedule duplication (add / reorder match strategy)

### Symptom
A Booksy reschedule creates a new event instead of updating the existing one. Two rows appear for the same client + barber.

### Scope
- `src/app/api/webhooks/resend/inbound/route.ts` — the reschedule-matching function only.

### Before (missing strategy 3)
```ts
// Strategy 1: external_id
// Strategy 2: previousStartTime + clientName ±5 min
// insert new row (wrong — should try strategy 3 first)
```

### After
```ts
// Strategy 1: external_id
// Strategy 2: previousStartTime + clientName ±5 min
// Strategy 3: clientName within ±30 min of new start time
//   - If exactly 1 match → update that row's start_time/end_time to new values
//   - If 0 or 2+ matches → insert as new (log ambiguity)
// insert as last resort
```

Keep strategies in this order. Never flip — earlier strategies produce fewer false matches.

### Post-fix check
```bash
npx tsc --noEmit
```
And a sanity SQL query:
```sql
-- Pick a known reschedule's new message_id and confirm exactly ONE row updated, not two inserted
SELECT id, status, updated_at FROM external_calendar_events WHERE message_id = '<new-message-id>';
```

### Mirror impact
None.

---

## Pattern #4: Restore `status='confirmed'` filter on calendar query

### Symptom
Cancelled Booksy events render on the calendar. Availability API still blocks slots for cancelled events.

### Scope
- `src/lib/hooks/useCalendarEvents.ts` — Booksy query section.
- OR `src/app/api/bookings/availability/route.ts` — Booksy event section.

### Before
```ts
let booksyQuery = supabase
  .from('external_calendar_events')
  .select('...')
  .eq('source', 'booksy')
  .gte('start_time', startDate.toISOString())
  .lte('start_time', endDate.toISOString())
// missing status filter
```

### After
```ts
let booksyQuery = supabase
  .from('external_calendar_events')
  .select('...')
  .eq('source', 'booksy')
  .in('status', ['confirmed'])
  .gte('start_time', startDate.toISOString())
  .lte('start_time', endDate.toISOString())
```

### Post-fix check
```bash
grep -n "external_calendar_events\|status.*confirmed" src/lib/hooks/useCalendarEvents.ts src/app/api/bookings/availability/route.ts
# Expected: each query includes .in('status', ['confirmed']) or equivalent .eq.
npx tsc --noEmit
```

### Mirror impact
`useCalendarEvents` is used by both `/barber/calendar` and `/dashboard/my-chair/calendar`. No mirror duplication — they share the hook. Still tell the user to hard-refresh both pages and confirm cancelled Booksy events disappear.

---

## Pattern #5: Multi-block message_id suffix de-collision

### Symptom
A single Booksy email contains 2 service blocks (parent + kid). One gets inserted, the second fails with a UNIQUE violation on `message_id` OR both inserts silently collapse.

### Scope
- `src/app/api/webhooks/resend/inbound/route.ts` — the multi-block insert loop.

### Before
```ts
for (const block of blocks) {
  const row = { ...block, message_id }  // same message_id for every block
  await supabase.from('external_calendar_events').insert(row)
}
```

### After
```ts
for (let i = 0; i < blocks.length; i++) {
  const row = {
    ...blocks[i],
    message_id: blocks.length > 1 ? `${message_id}#${i}` : message_id,
  }
  await supabase.from('external_calendar_events').insert(row)
}
```

Single-block emails keep the raw message_id (preserves existing idempotency). Multi-block suffixes `#0`, `#1`, ... per block.

### Post-fix check
```bash
grep -n "message_id.*#\|blocks.length" src/app/api/webhooks/resend/inbound/route.ts
npx tsc --noEmit
```
SQL to confirm no orphan collisions after deploy:
```sql
SELECT message_id, COUNT(*) FROM external_calendar_events
GROUP BY message_id HAVING COUNT(*) > 1;
-- Expected: 0 rows.
```

### Mirror impact
None.

---

## Pattern #6: Enforce barber config invariants at webhook entry

### Symptom
A specific barber stopped syncing; root cause traced to a bad `booksy_sync_email` value (typo, trailing whitespace).

### Scope
- `src/app/api/webhooks/resend/inbound/route.ts` — barber lookup section.

### Before
```ts
const { data: barber } = await supabase
  .from('barbers')
  .select('id, booksy_sync_enabled')
  .eq('booksy_sync_email', recipientEmail)
  .single()
```

### After
```ts
const normalizedRecipient = recipientEmail.trim().toLowerCase()
const { data: barber } = await supabase
  .from('barbers')
  .select('id, booksy_sync_enabled, is_active')
  .eq('booksy_sync_email', normalizedRecipient)
  .maybeSingle()

if (!barber || !barber.is_active || !barber.booksy_sync_enabled) {
  await logSkip(normalizedRecipient, 'no active barber matched')
  return new Response('ok', { status: 200 })
}
```

The change:
- Normalize whitespace + case before lookup (tolerant of mail server quirks).
- Use `.maybeSingle()` to avoid throwing on zero matches.
- Skip when barber is inactive OR opted out, not just missing.
- Always log the skip so audits can see it.

### Post-fix check
```bash
npx tsc --noEmit
```
And a targeted SQL sanity on the barbers table:
```sql
-- Confirm no accidental whitespace/case-drift on existing rows before deploy
SELECT id, name, booksy_sync_email
FROM barbers
WHERE booksy_sync_email IS DISTINCT FROM TRIM(LOWER(booksy_sync_email));
-- Any hit = a row that will mismatch. Fix in DB (requires safe-query skill) OR accept as a config fix target.
```

### Mirror impact
None.

---

## Pattern #7a: Fix multi-block extraction regex

### Symptom
A Booksy email clearly contains multiple service rows, but `extractServiceBlocks()` returns 1 block. Usually appears after a Booksy template refresh.

### Scope
- `src/lib/booksy/parser.ts` — `extractServiceBlocks()` function.
- `tests/unit/booksy-parser.test.ts` — add a fixture from the actual email that failed.

### Approach
This is NOT a one-line fix. Do not apply blindly. Instead:

1. Read the raw_email_body of the failing email.
2. Identify the new row delimiter Booksy is using (bold tag, table row, divider, etc.).
3. Adjust the regex to match BOTH the old and new structure (`|` union) rather than replacing. This keeps old emails parseable.
4. Add TWO test fixtures: one from an old-template email, one from the new one. Both must pass.

### Post-fix check
```bash
npx tsx tests/unit/booksy-parser.test.ts
npx tsc --noEmit
```

### Mirror impact
None.

---

## Pattern #7b: Guard father+son split with explicit signal

### Symptom
A legitimate long single-service (e.g., 90-minute cut+beard+style) got split into two 45-minute bookings.

### Scope
- `src/app/api/bookings/from-external/route.ts` — father+son split section.

### Approach
This is a policy call, not a one-liner. Recommended direction (discuss with user before applying):

- Keep the 75-min threshold but ALSO require a positive signal — e.g., the event's `service_name` contains "kids", "niños", or the event has a multi-block marker (`message_id` ends in `#<n>` AND there's a sibling row within ±5 min).
- Without such a signal, a long event stays single.

Do NOT remove the split entirely. Real father+son appointments rely on it.

### Post-fix check
- Unit test covering both paths: long single service → 1 booking, multi-block kids+parent → 2 bookings.

### Mirror impact
None.

---

## Pattern #8: Normalize service-name matching in from-external

### Symptom
Convert-to-booking rejects with "no matching service" even though the barber clearly has the service listed.

### Scope
- `src/app/api/bookings/from-external/route.ts` — service-match section.

### Before
```ts
const match = customs.find((c) => c.name === event.service_name)
```

### After
```ts
const normalize = (s: string) =>
  s.replace(/[\u2018\u2019]/g, "'")  // curly single → straight
   .replace(/[\u201C\u201D]/g, '"')  // curly double → straight
   .replace(/\s+/g, ' ')
   .trim()
   .toLowerCase()

const target = normalize(event.service_name || '')
const match = customs.find((c) => normalize(c.name) === target)
```

The goal is forgiving matching on unicode + whitespace. Do not add fuzzy matching (Levenshtein etc.) — silent approximate matches create worse bugs.

### Post-fix check
```bash
npx tsc --noEmit
```
Spot-check by converting a known-good external event in dev; the conversion should succeed.

### Mirror impact
None.

---

## Pattern #9: Spanish date format disambiguation

### Symptom
A Spanish-locale Booksy email dated 05/12/2025 (meaning 5 December) lands as May 12 in the DB.

### Scope
- `src/lib/booksy/parser.ts` — `parseDateTimeSpanish()`.
- `tests/unit/booksy-parser.test.ts` — add a DD/MM/YYYY fixture.

### Approach
- Prefer the text-month path first — if `parseDateTimeSpanish` finds "5 de diciembre" or "5 dic", use that and skip the numeric path entirely.
- Only if the email has no text month, fall back to numeric. In numeric mode on the Spanish path, ALWAYS parse as DD/MM/YYYY. Never MM/DD/YYYY.
- If parsing is ambiguous (e.g., "05/06/2025"), log a warning and skip rather than guess.

### Post-fix check
- Fixture for "5 de diciembre de 2025" → December 5.
- Fixture for "05/12/2025" in Spanish context → December 5.
- Fixture for "05/06/2025" in Spanish context → parses to June 5 (DD/MM), not May 6.

### Mirror impact
None.

---

## Pattern #10: Backfill Booksy logs (MANUAL, SAFE-QUERY REQUIRED)

### Symptom
A barber's event rows exist but the logs table has no corresponding entries, breaking audit observability.

### Scope
- NOT a code change. This is a data reconciliation.

### Approach
Backfilling production data is a write. It MUST go through the `safe-query` skill, with user approval of each batch. This skill will NOT silently run inserts. The typical shape:

```sql
INSERT INTO booksy_sync_logs (barber_id, message_id, parse_status, email_subject)
SELECT DISTINCT ON (e.message_id)
  e.barber_id,
  SPLIT_PART(e.message_id, '#', 1) AS message_id,
  'success' AS parse_status,
  '(backfilled)' AS email_subject
FROM external_calendar_events e
LEFT JOIN booksy_sync_logs l
  ON l.message_id = SPLIT_PART(e.message_id, '#', 1)
WHERE l.id IS NULL
  AND e.created_at > now() - interval '30 days';
```

### Hard constraints
- Never run without showing the exact count that will be inserted first.
- Never bypass `safe-query`.
- Never backfill to infer "success" if you can't prove the event was produced by a real parse — mark explicitly.

---

## Pattern exclusions

These changes are NOT patterns because they carry too much risk to encode as a template. If the user asks, propose the change, then require `brainstorming` or a full plan before touching:

- Changing the order of reschedule or cancel match strategies.
- Altering the ±5 min / ±30 min / ±2 min time windows.
- Removing or renaming columns on `external_calendar_events`.
- Adding a new language path.
- Changing the father+son split threshold (75 min).
- Replacing the EDT-first DST fallback with a different heuristic.

Any of those should go through `gsd:plan-phase` or at minimum a brainstorm, not a one-shot fix.
