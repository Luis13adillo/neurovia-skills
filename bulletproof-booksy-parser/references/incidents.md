# Booksy Parser Incidents & Diagnostic Patterns

Each pattern documents a real (or realistic) failure mode and the smallest fix. Use `diagnose` mode to match a symptom to a pattern. Fix only via `fix` mode with explicit user activation.

---

## Pattern #1: Appointment lands 4 hours late (or at midnight ET)

### Symptom
- Customer books an 8 AM EDT appointment on Booksy.
- MT calendar shows it at 12:00 PM ET or 4:00 AM ET.
- Happens consistently across multiple barbers or a specific date range.

### Root cause (the canonical incident)
Vercel runs in UTC. A naive `toISOString().split('T')[0]` on a local-time date returns the *UTC* date. Same with `toTimeString().slice(0,5)`. Either breaks the EDT/EST round-trip.

This exact bug hit production 2026-03-28 (Ron Whitaker 8 AM appointment stored at 12 PM UTC). The fix moved all date/time extraction to `toLocaleDateString('en-CA', { timeZone: 'America/New_York' })` + `toLocaleTimeString('en-GB', { timeZone: 'America/New_York', hour12: false })`.

### Diagnose
1. SQL: run the "Events where start_time is between midnight and 4 AM Eastern" query from `audit-queries.sql`. Any cluster = regression.
2. Grep: `grep -rn "toISOString().split\|toTimeString().slice" src/lib/booksy/ src/app/api/webhooks/resend/ src/app/api/bookings/from-external/ src/app/api/bookings/migrate-appointments/` — expected 0 hits.
3. Read `parseDateTime()` and `parseDateTimeSpanish()` in `src/lib/booksy/parser.ts` — confirm both still round-trip via `Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York' })`.

### Fix
Fix pattern #1 in `fix-patterns.md`. Always replace the banned call with the TZ-safe form. Do NOT "just subtract 4 hours" — that breaks in EST (November–March).

---

## Pattern #2: Spanish email produces no event

### Symptom
- Barber has Spanish Booksy locale.
- Inbound email arrives (visible in `booksy_sync_logs`) but `parse_status = 'skipped'` or `'failed'`.
- No `external_calendar_events` row appears.

### Root cause
One of:
- A Spanish keyword ("canceló", "reprogramada", etc.) is missing from the type-detection switch, so the email falls through to `type: 'unknown'`.
- `parseDateTimeSpanish()` choked on a date format the parser hasn't seen (e.g., "mié 5 de diciembre, 2025" with comma).
- Spanish month abbreviation is missing from the map (e.g., "set" for "septiembre" — variant of "sep").

### Diagnose
1. `SELECT email_subject, parse_status, error_message FROM booksy_sync_logs WHERE barber_id = '<uuid>' ORDER BY received_at DESC LIMIT 5;`
2. Confirm the subject contains expected Spanish keywords from `parser-languages.md`.
3. Read the switch in `parseBooksyEmail()` and verify the keyword list matches the reference.
4. If parse_status is `'failed'`, the error_message will name the throwing function — likely `parseDateTimeSpanish`.

### Fix
Fix pattern #2 in `fix-patterns.md`. Add the missing keyword OR extend the Spanish date parser. Always add a unit-test fixture for the specific subject + body before shipping.

---

## Pattern #3: Reschedule creates a duplicate instead of updating

### Symptom
- Client reschedules their appointment in Booksy.
- Old event still shows on the MT calendar at the original time.
- New event appears at the new time.
- Same client, same barber — two rows.

### Root cause
Reschedule-match fallback chain failed:
- `external_id` wasn't present (common — Booksy doesn't always include a booking ID).
- `previousStartTime + clientName` didn't match because the email didn't carry the old time (e.g., confirmed-proposal email).
- The third strategy (`clientName` within ±30 min of new time) wasn't reached OR had too-strict bounds.

The fallback ORDER matters — don't reorder without thinking about false positives.

### Diagnose
1. Find both rows: `SELECT id, message_id, start_time, status, client_name FROM external_calendar_events WHERE barber_id = '<uuid>' AND client_name ILIKE '<name>' ORDER BY start_time;`
2. Log row: `SELECT email_subject, parse_status FROM booksy_sync_logs WHERE message_id = '<new-message-id>';`
3. Read the reschedule-match function in the inbound route. Confirm all three strategies attempt before inserting a new row.
4. If the email lacks old time AND the barber has multiple appointments within ±30 min, the ambiguity is genuine — parser should skip reschedule and log it. Check log for that note.

### Fix
Fix pattern #3 in `fix-patterns.md`. Typical fix: confirm the ±30 min window covers the real range (expand to ±60 min if barbers legitimately reschedule further), OR add a new strategy matching on `clientPhone`. NEVER silently merge all new emails to the most recent event — that's how you orphan a legitimate second booking from the same client.

---

## Pattern #4: Cancelled Booksy appointment still shows on calendar

### Symptom
- Barber cancels a client in Booksy.
- MT calendar continues to render the appointment in amber.
- Availability API still blocks the slot.

### Root cause
Two possible causes:
A. The cancel-match code path didn't find the row, so the DB still has `status='confirmed'`.
B. The DB has `status='cancelled'` but `useCalendarEvents.ts` or `availability/route.ts` lost its `status='confirmed'` filter in a refactor.

### Diagnose
1. `SELECT id, status, updated_at FROM external_calendar_events WHERE barber_id = '<uuid>' AND client_name ILIKE '<name>' ORDER BY updated_at DESC LIMIT 5;` — is status still 'confirmed'?
2. If yes → inbound cancel-match failed. Check `booksy_sync_logs` for the cancel email. Verify subject contains an English OR Spanish cancel keyword.
3. If status is 'cancelled' → UI filter regression. Grep `useCalendarEvents.ts` for `.in('status', ['confirmed'])`. Grep `availability/route.ts` the same way. One of them probably dropped the filter.

### Fix
- If (A): fix the cancel-match chain (pattern #3 shape applies).
- If (B): restore the `status='confirmed'` filter. This is pattern #4 in `fix-patterns.md`.

---

## Pattern #5: Duplicate rows for the same client, same time

### Symptom
- Two identical `external_calendar_events` rows — same barber, same client, same start_time, same service.
- Appears within seconds of each other in `created_at`.

### Root cause
- Resend delivered the same webhook twice (retry on transient timeout).
- The second delivery should have been blocked by the `message_id` UNIQUE constraint, but wasn't because:
  - The message_id suffix logic for multi-block emails glitched and used the same suffix twice.
  - OR a manual backfill inserted rows bypassing the constraint.

### Diagnose
1. `SELECT message_id, COUNT(*) FROM external_calendar_events WHERE barber_id = '<uuid>' GROUP BY message_id HAVING COUNT(*) > 1;` — should return 0 rows.
2. If the message_ids differ but the appointment is clearly duplicate, inspect the raw_email_body of both — is one the `#0` block and the other `#1` of the same email?
3. If yes → the multi-block dedup (±2 min window) didn't fire OR the extractServiceBlocks split a single service into two.

### Fix
Fix pattern #5. Usually a sign the service-block extractor's dedup window is too tight OR the suffix logic needs to index from 0 consistently. DO NOT add a "DELETE duplicates" script without user approval — some "duplicates" are legitimate back-to-back appointments.

---

## Pattern #6: Specific barber stopped syncing N days ago

### Symptom
- "Juan's calendar is empty but he has appointments in Booksy."
- `booksy_sync_logs` for that barber has no rows in the last N days.
- Other barbers still syncing fine.

### Root cause candidates (in order of likelihood)
1. Gmail auto-forward rule on Juan's Booksy-linked Gmail account got disabled by Google (happens monthly — Google requires re-verification).
2. `barbers.booksy_sync_enabled = false` (someone toggled it in the dashboard).
3. `barbers.booksy_sync_email` was updated but the new address isn't verified in Resend.
4. `RESEND_WEBHOOK_SECRET` was rotated and Vercel env not updated — Svix verification rejects every delivery. (If this happens, ALL barbers break, not one.)

### Diagnose
1. `SELECT id, name, booksy_sync_enabled, booksy_sync_email, is_active FROM barbers WHERE id = '<uuid>';` — sanity-check config.
2. `SELECT MAX(received_at) FROM booksy_sync_logs WHERE barber_id = '<uuid>';` — date of last activity.
3. Compare with `SELECT MAX(received_at) FROM booksy_sync_logs WHERE parse_status='success';` — if other barbers are syncing fine, cause is per-barber (Gmail, config).
4. If NO barber has synced recently → webhook-side issue. Check Vercel logs for the inbound route, check Resend dashboard for webhook delivery status, check `RESEND_WEBHOOK_SECRET` is set in Vercel.

### Fix
Usually a configuration fix outside the code: re-verify Gmail forwarding on the barber's account, or sync env vars. If it IS a code issue, that's pattern #6 in `fix-patterns.md`.

---

## Pattern #7: Parent+child booked as one appointment (or split incorrectly)

### Symptom
- Booksy email is one transaction: "Adult Haircut 30 min + Kids Haircut 30 min".
- MT calendar shows either:
  - A single 60-minute event (multi-block extraction missed the split), OR
  - Two events at the exact same time (extraction worked but father+son split fired on top and created a copy).

### Root cause
- `extractServiceBlocks()` failed to detect multiple service rows → one event. Often a Booksy template change.
- OR duration crossed the 75-min threshold for father+son split, so a SINGLE service got split into two bookings at convert-to-booking time.

### Diagnose
1. `SELECT id, start_time, end_time, service_name, message_id FROM external_calendar_events WHERE barber_id = '<uuid>' AND client_name ILIKE '<name>' ORDER BY start_time;`
2. Check raw_email_body — does it contain multiple `<strong>` service rows?
3. If multi-block should have fired but didn't → regex in `extractServiceBlocks()` drifted with Booksy template. Pattern #7a.
4. If duration ≥ 75 min on a legitimate single service and convert-to-booking split it → threshold is too low OR logic should only split based on explicit multi-block signal. Pattern #7b.

### Fix
Fix pattern #7a (multi-block detection) or #7b (father+son threshold). #7b is risky — the 75-min threshold is in place because real father+son bookings DO look like single 75-min services in the email. Don't raise or lower without data.

---

## Pattern #8: Convert-to-booking fails with "no matching service"

### Symptom
- Owner clicks "Convert to booking" on a Booksy event.
- API returns 400 with "service not matched" or "barber has no active custom services."

### Root cause
- The barber has zero rows in `barber_custom_services` where `is_active = true`.
- OR the service name in the Booksy email doesn't match any custom service AND the fallback (first active custom) also fails because there are none.

### Diagnose
1. `SELECT id, name, is_active FROM barber_custom_services WHERE barber_id = '<uuid>';`
2. If empty → barber hasn't set up their booking menu. Send them to `/barber/settings?tab=services`.
3. If present but names don't match → confirm the parser normalized curly quotes. Check the event's `service_name` vs `barber_custom_services.name` — case-insensitive match should succeed. If it doesn't, there's probably a unicode/punctuation mismatch.

### Fix
Not usually a code fix — a config fix by the barber. Code fix (pattern #8) only if the name normalization has a genuine bug (e.g., em-dash vs en-dash).

---

## Pattern #9: Spanish date parses to wrong day (DD/MM vs MM/DD)

### Symptom
- Appointment on 5 December 2025 shows up on 12 May 2025 (or vice versa).
- Specific to Spanish emails using slash-separated dates.

### Root cause
Spanish date format is DD/MM/YYYY. English is MM/DD/YYYY. If the Spanish parser path accidentally falls through to the English parser (or if a mixed-language email confuses the switch), 05/12/2025 gets read as May 12 instead of 5 December.

### Diagnose
1. `SELECT id, start_time, client_name, raw_email_body FROM external_calendar_events WHERE id = '<id>';`
2. Look at raw_email_body — is the date slash-formatted? Which order?
3. Read `parseBooksyEmail()` — which language path did this email take? Is the subject Spanish but body English?

### Fix
Fix pattern #9. Prefer text-month formats ("5 de diciembre" / "Dec 5") when the parser has a choice; only fall back to numeric when required. Never assume MM/DD when you're on the Spanish path.

---

## Pattern #10: Ghost event (row exists, no email log)

### Symptom
- `external_calendar_events` row with status='confirmed' exists for a barber.
- No matching row in `booksy_sync_logs`.
- The event has a valid message_id.

### Root cause candidates
- A manual backfill via `/api/bookings/migrate-appointments` inserted rows without writing a log (by design — migration is a different path).
- OR the logs table was truncated/purged and the events survived.

### Diagnose
1. Check raw_email_body — is it present? Migration backfills often have partial data.
2. Check `migrate-appointments/route.ts` behavior — does it write to `booksy_sync_logs`?

### Fix
Usually informational — not a bug per se. Only a bug if the migration path claims to write logs but doesn't.

---

## When none of the patterns match

- Re-read the user's report. Apply the "User Reports Override Queries" rule (MEMORY.md): if the UI shows X, X is fact. Trace what code path produced the UI.
- Read the email subject + a sample of raw_email_body. That's ground truth for parser input.
- Three-file rule: if you've read 3 files without a diagnosis, STOP and report findings. Don't expand scope.
- Two-strike rule: if two different fixes fail to reproduce or resolve, STOP and ask the user for a different angle.
