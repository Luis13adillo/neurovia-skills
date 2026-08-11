---
name: bulletproof-bookings
description: Audit, diagnose, or scale-check the MT Barbershop bookings system (6-step wizard, availability API, reschedule, cancel, reminders, Booksy integration, btree_gist overlap constraint, soft-delete). Use when bookings show wrong time/location, availability is wrong, overbooking happens, reminders misfire, or before adding a new location. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to the production DB. Never modifies application code without explicit user approval.
---

# Bulletproof Bookings

## HARD RULE — Service-Duration-Stepped Slot Grid (locked 2026-04-27)

**Every native booking time MUST satisfy `(slot_minutes - schedule.start_time_minutes) % service.duration_minutes === 0`.** The slot grid steps by the selected service's `duration_minutes`, anchored to the barber's `barber_schedules.start_time` for that day. So Gustavo's 60-min cut at a 9:00 start_time can only land at 9:00, 10:00, 11:00... His 30-min Kids cut can land at 9:00, 9:30, 10:00, 10:30. A 45-min service legitimately produces :15 / :45 starts after the first booking (9:00, 9:45, 10:30, 11:15) — that's the math, not a bug.

**Routes covered (must call `isOnSlotGrid` from `src/lib/utils/booking-slot.ts` before insert/update):**
- `src/app/api/bookings/route.ts` POST (native customer-facing booking creation)
- `src/app/api/bookings/quick/route.ts` POST (owner/barber dashboard quick-book)
- `src/app/api/bookings/[id]/reschedule/route.ts` PATCH (reschedule to new time)

**Carve-outs (intentional, do NOT add slot-grid check):**
- `src/app/api/bookings/from-external/route.ts` — Booksy imports keep their literal source time. Booksy is the system of record for those bookings; we don't re-align them.
- `src/app/api/webhooks/resend/inbound/route.ts` (Booksy email parser path) — same reason.

**UI surfaces that MUST agree with the API on the grid:**
- `src/components/booking/TimeSlotPicker.tsx` — reads `slotInterval` from `/api/bookings/availability` response, falls back to `serviceDuration` prop. Reused by `RescheduleBookingModal.tsx`, gets the fix transitively.
- `src/components/dashboard/calendar/ManualBookingSheet.tsx` — passes `&duration=${selectedService.duration_minutes}` to the availability fetch and re-fetches when service changes; slot loop steps by service duration anchored to `start_time`.

**Availability API contract:**
- `src/app/api/bookings/availability/route.ts` returns `slotInterval: <requestedDuration>` in the JSON response. Internal slot loop uses `interval = requestedDuration` and `alignedStart = workStartMinutes` (no rounding). Removing or renaming `slotInterval` is a breaking change for both UIs.

**Server error contract:** off-grid attempts return `400 { error: 'OFF_GRID_SLOT', detail: '...' }`. Audit mode flags any booking write path that does NOT return this error code on an off-grid input.

**Why this exists:** before 2026-04-27 the slot grid was hardcoded to 30 min everywhere. A 60-min booking starting at 9:30 would drift into 9:30→10:30, then 10:30→11:30, etc., walking off the hour grid all day. Production data showed ~5% of native bookings off the 30-min grid. Owner Gustavo wanted 60-min cuts to land only on the hour. The fix is service-duration-stepped slots, anchored to start_time, enforced server-side.

**Existing pre-2026-04-27 bookings are NOT migrated.** "Going forward" only — see incidents.md "Slot grid alignment (2026-04-27)" for the rollout decision.

---

## HARD RULE — Inverse Walk-In Eligibility (locked 2026-04-25)

**Booking creation paths MUST respect active walk-ins.** If a barber is currently in a walk-in service (`queue_entries.status` = `called` or `in_chair`) at a time that overlaps a proposed booking, the booking creation route MUST reject the booking. Symmetric counterpart to the walk-in eligibility rule in `bulletproof-queue` (which makes walk-in assignment respect bookings).

**Routes covered by this rule:**
- `src/app/api/bookings/route.ts` POST (native booking creation)
- `src/app/api/bookings/quick/route.ts` POST (owner quick booking)
- `src/app/api/bookings/[id]/reschedule/route.ts` (reschedule into a new slot)
- `src/app/api/bookings/availability/route.ts` (drop overlapping slots from the available list)

**Status (2026-04-25):** the unified walk-in eligibility helper `isBarberAvailableForWalkIn` in `src/lib/queue/booking-conflicts.ts` covers the WALK-IN → booking direction. The inverse (BOOKING → walk-in) is **not yet implemented** — see `.planning/queue-overbooking-prevention-plan-2026-04-25.md` Phase 5. Audit mode MUST flag any booking creation path that doesn't include an active-walk-in check until Phase 5 ships.

**Why this matters:** owner can currently create a 10:30 native booking for Gustavo while he's mid-walk-in at 10:25. Reverse of the Gustavo Booksy bug — same root cause (asymmetric eligibility checks across paths).

---

Bookings are revenue-critical. A wrong time, a double-booked barber, or a reminder that goes to the wrong client erodes customer trust directly. The btree_gist overlap constraint and the Eastern-time handling are the load-bearing invariants that keep this system honest.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "System B: Booking Flow (6 Steps)" section, multi-location routing, timezone rules.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — Booksy Timezone Rule, overbooking constraint, cancel/reschedule pending fixes.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.planning/TODO.md` — open cancel/reschedule bugs (Bug #3, #4).
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.
5. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Mirroring.

Confirm "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**. `audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that edits code, and only under the explicit gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (80+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration. Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one file's behavior depends on another that looks unrelated.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `bookings/route.ts` POST (create) | Availability re-check before insert + `bookings_no_time_overlap` btree_gist constraint + `isOnSlotGrid` slot-grid check (returns 400 OFF_GRID_SLOT) + `confirmation_code` unique index + SMS confirm send + email confirm send (with `locationState`) + reminder scheduling (24h/1h flags) + first-booking exemption / grace-period (commission coupling) + Google Calendar create event (if barber has sync) | Create is the origin — if ANY downstream path is silent, that booking becomes a ghost for reminders, commission, or calendar. |
| `bookings/[id]/reschedule/route.ts` | Availability recheck for NEW slot + overlap constraint re-validation + `isOnSlotGrid` slot-grid check (with NEW barber_schedules.start_time for the new date) + reminder flag reset (`reminder_sent`, `one_hour_reminder_sent` → false) + reminder re-scheduling + Google Calendar event update + `external_calendar_events` re-emit (if barber synced) + SMS update to customer + email update with new time | Reschedule is 7 downstream surfaces. A reschedule that doesn't reset reminder flags = customer gets reminder for OLD time. |
| `bookings/[id]/route.ts` DELETE (cancel) | Soft-delete (`deleted_at` set, status='cancelled') + reminder cancellation + confirmation SMS suppression + cancellation SMS send + Google Calendar event delete + `external_calendar_events` delete + referral_events reversal + commission ledger reversal (if completed) + calendar hook exclusion (`.is('deleted_at', null)`) | Cancel must propagate to 9+ surfaces. Missing any = ghost appointment on calendar or duplicate reminder fires. |
| `bookings/[id]/route.ts` PATCH completion (`→completed`) | `create_service_transaction_from_booking` trigger + `trg_bookings_daily_summary` + `cash_fee_ledger` INSERT (from 4-route app-code path) + first-booking exemption + grace-period lookup + feedback SMS scheduling + loyalty punch + client upsert (CRM) | Completion fires 8+ writes. Divergence from `quick-complete/route.ts` = Defect H7 class. |
| `bookings/quick-complete/route.ts` | Parity with `bookings/[id]/route.ts` completion path — same first-booking logic, same grace-period, same ledger INSERT, same feedback scheduling | Historically skipped first-booking exemption. Must match. |
| `bookings/availability/route.ts` | Eastern TZ in ALL date ops + `bookings_no_time_overlap` still active + busy list includes `confirmed`+`pending`+`in_progress` + `barber_time_blocks` blocking + queue `in_chair` entries blocking + Booksy `external_calendar_events` filtered to `status='confirmed'` (excludes cancelled + converted) + Google Calendar events blocking + slot loop uses `interval = requestedDuration` and `alignedStart = workStartMinutes` (anchored, no rounding) + response includes `slotInterval: requestedDuration` for the UI | Availability is THE gate. Skipping one busy source = double-book. The slot grid contract powers TimeSlotPicker + ManualBookingSheet — drift between API and UI = mismatched options. |
| `bookings/quick/route.ts` (owner/barber manual book) | Availability recheck + overlap constraint + `isOnSlotGrid` slot-grid check + SMS confirm suppression for walk-in-style entries (optional) + reminder flags set correctly for quick-book | Quick-book bypasses the 6-step wizard — must still hit the same guardrails. |
| `bookings/reminders/route.ts` (cron) | `CRON_SECRET` header check + 24h/1h window filtering via Eastern TZ + `reminder_sent` / `one_hour_reminder_sent` atomic update WITH SMS send (avoid duplicate reminders) + soft-delete exclusion + opt-out exclusion via `sms_opt_outs` | Reminder cron firing without atomic flag update = duplicate SMS storms. |
| `bookings/manage/[code]/route.ts` (public self-service) | 30 req/min GET + 5 req/5min POST rate limits + `confirmation_code` unique partial index still present + reschedule path reuses `/reschedule/route.ts` logic (not a parallel path) + cancel path reuses DELETE | Public self-service is the untrusted surface — all rate limits + input validation must be intact. |
| `bookings/from-external/route.ts` (Booksy/iCal import) | EDT/EST offset detection in `booksy/parser.ts` + `external_calendar_events` INSERT + `booksy_sync_logs` parse_status + per-barber `booksy_sync_email` routing + duplicate detection (external_id) + availability API re-read (Booksy events must show as busy) | Booksy import bypasses the wizard — any TZ drift or duplicate = double-booking. |
| `webhooks/resend/inbound/route.ts` | Calls `booksy/parser.ts` with Eastern TZ + routes to correct barber by `booksy_sync_email` + logs to `booksy_sync_logs` + notification to barber on parse failure | Inbound email is the entry point for Booksy — silent parse fail = missed appointment. |
| `barber/sync-calendar/route.ts` (Google Calendar) | Two-way sync — booking change pushes to Google + Google change pulls to bookings + `barbers.google_access_token` refresh + `google_token_expiry` check | Google sync out-of-sync = calendar shows different times than DB. |
| `queue/entry/[id]/route.ts` call-to-chair (booking coupling) | `booking-conflicts.ts` checks overlapping bookings for THIS barber + blocks `→in_chair` if active booking for same barber at same time | Queue in-chair guard depends on bookings state — stale `in_progress` bookings block the guard. |
| `bookings` table soft-delete | All consumer queries filter `.is('deleted_at', null)` — `useBookings`, `useCalendarEvents`, reminder cron, manage route, availability API | Missing soft-delete filter anywhere = ghost bookings leak. |
| Any booking INSERT/UPDATE | Realtime publication on `bookings` includes the change + `cache: 'no-store'` on server reads + calendar hook (`useCalendarEvents`) dedupes Booksy vs Google | New booking must appear on all calendars within 1s. |
| Any use of booking in email/SMS template | `locationState` passed from booking's location (NOT hardcoded `, DE`) — especially for Edwardsville (PA) | MEMORY.md 2026-04-20 cross-state email fix. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the bookings domain values:

```sql
-- 1. Enumerate booking domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('bookings','external_calendar_events','booksy_sync_logs','barber_time_blocks')
ORDER BY table_name;
-- Expected: 4 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on every booking table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('bookings','external_calendar_events','booksy_sync_logs','barber_time_blocks')
ORDER BY tablename, policyname;
-- Expected: at least 1 policy per role per table (see SURFACE_INVENTORY.md section 11).

-- 3. Triggers on booking-touched tables
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('bookings','external_calendar_events')
ORDER BY event_object_table, trigger_name;
-- Expected: create_service_transaction_from_booking, trg_bookings_daily_summary, update_external_calendar_events_updated_at.

-- 4. RPC functions
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('create_service_transaction_from_booking','update_daily_summary');
-- Expected: 2 rows, both has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%booking%' OR name ILIKE '%soft_delete%'
   OR name ILIKE '%booksy%' OR name ILIKE '%confirmation_code%'
   OR name ILIKE '%overbooking%' OR name ILIKE '%time_blocks%'
   OR name ILIKE '%in_progress%' OR name ILIKE '%external_events%'
ORDER BY executed_at;
-- Expected: at least 9 rows (see SURFACE_INVENTORY.md section 12).

-- 6. Overbooking exclusion constraint present
SELECT conname, contype FROM pg_constraint
WHERE conrelid = 'public.bookings'::regclass
  AND conname = 'bookings_no_time_overlap';
-- Expected: 1 row. Missing = CRITICAL.

-- 7. Realtime publications
SELECT tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('bookings','external_calendar_events')
ORDER BY tablename;
-- Expected: bookings present.
```

Attach all 7 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **btree_gist overlap constraint present in DB** — `bookings_no_time_overlap` on `bookings` table, guarding `status IN ('confirmed','pending','in_progress') AND deleted_at IS NULL`. Run the query in `audit-queries.sql`.

2. **Availability API uses Eastern TZ**
   - File: `src/app/api/bookings/availability/route.ts`
   - All date/time ops include `timeZone: 'America/New_York'`.
   - Filters bookings by `status IN ('confirmed','pending','in_progress')` — in_progress is INCLUDED and correctly blocks slots.
   - Filters Booksy events by `status='confirmed'` only (excludes `cancelled` AND `converted`).

3. **Soft-delete filter on all booking queries** — `grep -rn ".is('deleted_at', null)" src/app/api/bookings/ src/lib/db/bookings.ts`. Every non-admin query must filter soft-deleted rows.

4. **Confirmation code UNIQUE partial index** — on `bookings(confirmation_code) WHERE confirmation_code IS NOT NULL`.

5. **Timezone patterns in Booksy integration**
   - Files: `src/app/api/bookings/from-external/route.ts`, `src/app/api/bookings/resend/inbound/route.ts`, `src/app/api/bookings/migrate-appointments/route.ts`
   - Must use `toLocaleDateString('en-CA', { timeZone: 'America/New_York' })` for date and `toLocaleTimeString('en-GB', { timeZone: 'America/New_York', ... })` for time.
   - Banned: `toISOString().split('T')` and `toTimeString().slice` without upstream TZ conversion.

6. **Reminder cron auth** — `src/app/api/bookings/reminders/route.ts` requires `CRON_SECRET` header validation.

7. **Public rate limits** — `src/app/api/bookings/manage/[code]/route.ts` enforces 30 req/min GET and 5 req/5min POST.

### Data-level invariants

Run queries in `references/audit-queries.sql` via `mcp__supabase-mt__execute_sql`. SELECT-only. Expected 0 rows unless noted.

### Output template — MANDATORY Coverage Report

Every bookings audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Bookings Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 4/4 PASS | X/4 FAIL
- RLS policies found: X — list any gaps
- Triggers found: X/3
- RPCs found: X/2
- Migrations confirmed: X/9
- Overbooking constraint: PASS/FAIL
- Realtime publications: bookings PASS/FAIL

### Code-level findings
[PASS/FAIL per invariant with file:line anchors]

### Data-level findings
[PASS/FAIL per query with row counts]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (42 files from SURFACE_INVENTORY.md sections 1-6) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/bookings/route.ts | PASS/FAIL/NOT-RUN | e.g. "route.ts:287 — btree_gist race caught by try/catch and reported as 409" |
| ... | [all 42] | | |

Files audited with proof-of-read: N / 42 (target: 42/42). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (4 tables directly + 3 parent, from SURFACE_INVENTORY.md section 7)
| Table | Row count | Status dist | NULL/soft-delete violations | Verdict |
|---|---|---|---|---|
| bookings | | confirmed:X, pending:X, in_progress:X, completed:X, cancelled:X, no_show:X | deleted_at count | |
| external_calendar_events | | confirmed:X, cancelled:X, converted:X | | |
| booksy_sync_logs | | parse_status dist | | |
| barber_time_blocks | | block_type dist | | |

Tables audited: N / 4

### Pillar 3 — Queries (from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | no_overlap_violations | | |
| ... | [all queries] | | |

Queries run: N / N_total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (4 booking tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| bookings | | ≥3 (public insert, owner all, barber select own) | |
| external_calendar_events | | ≥2 (public select, barber own) | |
| booksy_sync_logs | | ≥1 (owner select) | |
| barber_time_blocks | | ≥2 (barber all own, owner select) | |

RLS tables audited: N / 4

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 9, 10, 13, 14, 15, 16)
| Integration | Verdict | Note |
|---|---|---|
| Trigger: create_service_transaction_from_booking | | |
| Trigger: trg_bookings_daily_summary | | |
| Constraint: bookings_no_time_overlap (btree_gist) | | |
| Constraint: confirmation_code unique index | | |
| Realtime: bookings | | |
| Cron: bookings/reminders (CRON_SECRET) | | |
| Cron: google-calendar-sync | | |
| Cron: feedback | | |
| Twilio SMS (confirm + reminders + feedback) | | |
| Resend email (confirm + reschedule + cancel) — locationState used | | |
| Booksy parser (EDT/EST offset + Spanish) | | |
| Google Calendar two-way sync | | |

Integrations audited: N / 12

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| Create → {availability recheck, overlap constraint, SMS confirm, email confirm w/ locationState, reminder flags, first-booking commission, Google Calendar create} | YES/NO | |
| Reschedule → {availability recheck NEW slot, overlap constraint, reminder flags reset, reminder re-schedule, Google Calendar update, external_events re-emit, SMS update, email update} | YES/NO | |
| Cancel → {soft-delete, reminder cancel, SMS suppress, cancellation SMS, Google delete, external_events delete, referral reversal, commission reversal, calendar `.is('deleted_at', null)` filter} | YES/NO | |
| Completion → {ST trigger, daily_summaries, cash_fee_ledger, first-booking, grace-period, feedback, loyalty, client upsert} | YES/NO | |
| quick-complete parity with bookings/[id] PATCH | YES/NO | |
| Availability → {Eastern TZ, overlap constraint, busy list inclusive, time_blocks, queue in_chair, Booksy confirmed-only, Google Calendar} | YES/NO | |
| quick-book → {availability recheck, overlap constraint, reminder flags correct} | YES/NO | |
| Reminders cron → {CRON_SECRET, ET window, atomic flag+SMS, soft-delete, opt-out} | YES/NO | |
| Public manage → {rate limits 30/5min + 5/5min, confirmation_code index, reuse /reschedule logic, reuse DELETE} | YES/NO | |
| from-external → {Booksy parser TZ, external_events INSERT, sync_logs, per-barber routing, duplicate detection, availability re-read} | YES/NO | |
| Resend inbound → {parser TZ, booksy_sync_email route, sync_logs, parse-fail notification} | YES/NO | |
| Google Calendar sync → {two-way, token refresh, expiry check} | YES/NO | |
| Queue call-to-chair → {booking-conflicts checked for this barber} | YES/NO | |
| Soft-delete filter present in ALL consumer queries | YES/NO | |
| Any INSERT/UPDATE → {realtime on bookings, cache no-store, calendar dedup} | YES/NO | |
| Email/SMS uses `locationState` (no hardcoded `, DE`) | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/bookings/send-reminder/route.ts] | Ad-hoc reminder path — duplicate send risk | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Resend dashboard, Google Calendar OAuth console, Twilio console, etc.): <list>.

If zero gaps: write "No gaps identified. All 80+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 80+ (XX%)
- FAILs: N
- NOT-RUNs: N  (if > 0, the audit is PARTIAL, not COMPLETE — state this in the header)
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL BOOKINGS AUDIT — N surfaces unaudited, M coupling violations" instead of "Bookings Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for symptom. Examples:
   - "Booking shows wrong time (4 hours off)"
   - "Two bookings at the same time for same barber"
   - "Reschedule says slot is free but it's actually taken"
   - "Reminder SMS sent to wrong number"
   - "Booking disappeared from calendar"
   - "Public manage link returns 'not found' even though code is valid"

2. Match against `references/incidents.md`.

3. Three-file rule. Two-strike rule. Stay in scope.

---

## Mode: scale-check

Produce "must-fix-before-location-#5" checklist.

1. **Hardcoded location names in templates:**
```bash
grep -rn "Wilmington\|Newark\|New Castle" src/lib/email/ src/lib/twilio/ src/app/api/bookings/
```
Expected: zero direct matches. Templates should use `{{location.name}}` variables.

2. **Hardcoded addresses in email/SMS:**
```bash
grep -rn "Kirkwood Hwy\|Marrows Rd\|Penn Mart" src/lib/email/ src/lib/twilio/
```

3. **`locations[0]` in booking flow:**
```bash
grep -rn "locations\[0\]" src/app/\(public\)/book/ src/app/api/bookings/
```
Booking flow should use schedule-aware location routing (per commit 7372ca5). If any appear, flag.

4. **Availability API location resolution** — must pull location via `barber_schedules` for the given date, not hardcoded.

5. **Booksy email sync** — `booksy_sync_email` is per-barber. New barbers at new locations need their email added to the Booksy account OR sync disabled per-barber.

6. **Reminder audience filters** — `src/app/api/bookings/reminders/route.ts` should not assume a specific location count. Grep for hardcoded location IDs in the reminder query.

## Mode: fix

The only mode that writes code. Closes the loop between "audit/diagnose found X" and "X is fixed + verified." Does NOT commit, does NOT push, does NOT touch the production DB. See `references/fix-patterns.md` for the canonical patterns.

### Activation is EXPLICIT

Fix mode fires ONLY when the user types one of:
- `apply pattern N` — N is a pattern number from `references/fix-patterns.md`
- `fix <symptom-phrase>` — natural-language form; the skill maps to a pattern and CONFIRMS before doing anything
- `enter fix mode` followed by a scope

Any other phrasing → audit/diagnose instead. An audit finding NEVER auto-triggers a fix.

### Workflow (strict — every step, no shortcuts)

1. **Scope declaration.** Restate in 1–2 sentences which pattern (number + name), which file(s) will change, any mirror-page impact.
2. **Preflight.** Read the target file. Confirm the "before" block from `fix-patterns.md → Pattern N` still matches current code — imports, function signatures, surrounding context, NOT line numbers (which drift). If drift → STOP and report what differs. Do NOT apply a stale pattern.
3. **Scope audit.** Confirm the fix touches ONLY files named in the pattern's Before/After blocks. If a fix would require touching an unrelated system → STOP and ask for approval before expanding.
4. **Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes` / `apply` / `proceed`. No implicit approval.
5. **Apply.** Single `Edit` call. ONE pattern per fix-mode invocation. Never bundled.
6. **Post-fix verification.** `npx tsc --noEmit` passes. Re-run the pattern's post-fix grep and/or SQL check — must pass. For UI patterns, explicitly tell the user "you must test this in the browser before shipping — I can't verify UI."
7. **Mirror check.** If the fix touches any page in the Cross-Dashboard Code Mirroring map (`.claude/rules/context-awareness.md`), invoke the `mirror-check` skill before handoff.
8. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/<domain>-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for any dashboard-touching fix. |
| `safe-query` | If a pattern requires DB writes (rare), route through safe-query. |

---

## Downstream Consumers & Propagation

When a booking is created, rescheduled, cancelled, or completed, every surface that shows bookings must reflect the change immediately.

### Consumers (every surface that reads booking data)

| Consumer | File / URL | What it reads |
|---|---|---|
| Barber calendar | `src/app/(dashboard)/barber/calendar/page.tsx` | this barber's bookings |
| Owner my-chair calendar | `src/app/(dashboard)/dashboard/my-chair/calendar/page.tsx` | mirror of barber calendar |
| Barber home upcoming | `src/app/(dashboard)/barber/page.tsx` | next 3 bookings |
| Owner all-bookings | `src/app/(dashboard)/dashboard/bookings/page.tsx` | all bookings all barbers |
| Calendar events hook | `src/lib/hooks/useCalendarEvents.ts` | unified feed of bookings + queue + Booksy + Google |
| Reminder cron | `/api/bookings/reminders` | bookings in 24h/1h window |
| Public manage | `src/app/(public)/book/manage/[code]/page.tsx` | single booking by confirmation code |
| Profile page | `src/app/(public)/profile/page.tsx` (if logged in) | customer's upcoming bookings |
| Commission pipeline | `service_transactions` trigger on completion |

### Propagation invariants

1. **Realtime publication includes `bookings`**
   ```sql
   SELECT tablename FROM pg_publication_tables
   WHERE pubname = 'supabase_realtime' AND tablename = 'bookings';
   -- Expected: 1 row
   ```
2. **All consumer queries filter `.is('deleted_at', null)`** — soft-deleted bookings must never appear on calendars.
3. **`useCalendarEvents` dedupes Booksy vs Google events and filters Booksy `status='confirmed'`** — missing filter means cancelled Booksy events leak onto the calendar.
4. **Overlap constraint `bookings_no_time_overlap` prevents race** — even if two requests arrive simultaneously, only one insert succeeds.
5. **Reminder flags updated atomically with SMS send** (else duplicate reminders).
6. **Cancellation cascade:** cancel → status='cancelled' → SMS sent → calendar event removed (if Google sync) → availability API re-opens slot → barber notification → commission reversal (if applicable).

### Diagnose: "I cancelled a booking but it still shows on the calendar"

1. DB state: `SELECT id, status, deleted_at FROM bookings WHERE id = '...'`. Is status='cancelled' or deleted_at set?
2. Consumer query: does `useCalendarEvents` filter cancelled + soft-deleted? Read the hook.
3. Cache: Supabase factories wrap `cache: 'no-store'`? Calendar route has `export const dynamic = 'force-dynamic'`?
4. Google Calendar: if sync enabled, was the Google event deleted? Check `/api/cron/google-calendar-sync` logs.
5. If all green but UI stale → hard refresh the page; if still stale, realtime subscription is dead. Re-check `useCalendarEvents` channel binding.

---

## HARD RULES

- NEVER write to production DB.
- NEVER modify the btree_gist constraint or soft-delete filter without explicit approval.
- NEVER bypass the overbooking constraint in app code — it's a DB-level guardrail for a reason.
- NEVER test on real barbers.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Cross-dashboard mirroring. Two-strike rule. Stay in scope.
