---
name: bulletproof-booksy-parser
description: Audit, diagnose, or scale-check the MT Barbershop Booksy email parser pipeline (src/lib/booksy/parser.ts English + Spanish parsing, Resend inbound webhook, external_calendar_events + booksy_sync_logs tables, per-barber booksy_sync_email routing, EDT/EST timezone detection, multi-appointment service blocks, calendar propagation via useCalendarEvents, convert-to-booking flow, father+son duplication). Use when a Booksy email produces the wrong time/date/service/client, when a barber's appointments stop syncing, when a reschedule or cancel doesn't match the existing event, when the calendar shows stale/ghost/duplicate Booksy entries, when adding Booksy sync to a new barber, or when preparing for a new locale. Complement to bulletproof-bookings (which covers the `bookings` table) and bulletproof-schedules (which covers barber_schedules-driven location resolution) — this skill owns the EMAIL → external_calendar_events → calendar pipeline end-to-end. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to the production DB. Never modifies application code without explicit user approval. Invoke this skill whenever the user mentions Booksy, email parsing, external calendar events, booksy_sync_email, booksy_sync_logs, Resend inbound, or any symptom where a Booksy appointment looks wrong on the calendar — even if they don't say the word "parser".
---

# Bulletproof Booksy Parser

## HARD RULE — Booksy Events Feed Walk-In Eligibility (locked 2026-04-25)

`external_calendar_events` rows where `source='booksy'` AND `status='confirmed'` are consumed by the unified walk-in eligibility helper `isBarberAvailableForWalkIn` in `src/lib/queue/booking-conflicts.ts`. This is what stops a walk-in from being assigned to a barber mid-Booksy.

**Critical filter contract — DO NOT BREAK:**
- The helper queries `eq('status', 'confirmed')`. **Booksy events that have been converted into native bookings get their status changed to `'converted'`** — they MUST NOT be returned by this query, otherwise the same appointment fires twice (once as Booksy, once as native booking) and walk-in assignment is blocked spuriously.
- The convert-to-booking flow MUST keep flipping `external_calendar_events.status` from `'confirmed'` to `'converted'` after a successful native booking insert. Any path that creates a native booking from a Booksy event without flipping the status = silent overbooking blocker.
- Cancelled Booksy events are stored as `status='cancelled'` and also excluded by the filter — same contract, different state.

**Why this matters:** Gustavo had 8 confirmed Booksy events on 2026-04-25 and the unified helper now uses them to block reassignment. If the convert-to-booking path stops setting `'converted'`, the helper double-counts and blocks a barber even when the event has already been converted. Symmetric to the inverse — see `bulletproof-bookings` HARD RULE.

**Audit checkpoint:** when auditing this skill, grep for any path that INSERTs into `external_calendar_events` with `status='confirmed'` to make sure no duplicate path bypasses the parser's idempotency.

---

The Booksy email parser is the ONLY bridge between Booksy (external appointment book that many MT barbers still use) and MT's internal calendar. If it misparses an email, a real client appointment either ghosts (no row) or lands at the wrong time (4-hour UTC drift), and the barber double-books. The system handles BOTH English and Spanish Booksy emails in a single code path, per-barber via a unique `booksy_sync_email` address, with EDT/EST auto-detection.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

**Complements — does not overlap with:**
- `bulletproof-bookings` — owns the `bookings` table, overlap constraint, manage flow.
- `bulletproof-schedules` — owns `barber_schedules` and per-day location routing.
- `bulletproof-communications` — owns SMS/email outbound.

This skill is the only one that owns: `src/lib/booksy/*`, the Resend inbound webhook, `external_calendar_events`, `booksy_sync_logs`, and the English + Spanish parser.

---

## Mandatory Preflight — BEFORE any action

Read these first. Do not skim — the Booksy parser touches most of the same invariants:

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — database schema (migration 042, external_calendar_events, booksy_sync_logs, barber columns booksy_sync_email + booksy_sync_enabled), multi-location routing.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — "Booksy Timezone Rule" (Vercel UTC vs Eastern), "Next.js 14 Data Cache" rule, "User Reports Override Queries" rule.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 7 (zero tolerance), 8 (existing systems locked), 9 (zero production data contamination).
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Mirroring, User Reports Override Queries rule.
5. This skill's `references/invariants.md`, `references/parser-languages.md`, `references/incidents.md`.

Confirm: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check** — READ-ONLY. No edits, no DB writes.
- **fix** — edits code, gated by explicit activation phrase. Never commits, never pushes, never writes to production DB.

Default to audit if the user says "check the parser" or "is Booksy working." Default to diagnose if the user reports a specific symptom.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (~53 surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY parser invariant (both EN + ES), and EVERY integration (Resend inbound Svix, convert-to-booking, useCalendarEvents, realtime publication). Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one surface's behavior depends on another that looks unrelated. A PASS on the left without evidence of auditing the right = COUPLING VIOLATION.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `webhooks/resend/inbound/route.ts` (inbound email received) | (a) Svix signature verify using `RESEND_WEBHOOK_SECRET`, (b) barber lookup by `booksy_sync_email` (no sender/phone fallback), (c) `parseBooksyEmail()` call on `src/lib/booksy/parser.ts`, (d) `booksy_sync_logs` INSERT with `parse_status` in both success AND skip paths, (e) admin/service-role Supabase client (RLS blocks anon writes) | Missing signature = spoofable webhook. Missing log on skip = silent drops invisible. Wrong client = RLS rejects writes. |
| `parseBooksyEmail()` in `src/lib/booksy/parser.ts` (English path) | (a) `parseDateTime()` helper with EDT-first/EST-second round-trip via `Intl.DateTimeFormat('America/New_York')`, (b) keyword switch recognizes EN subjects (new appointment, changed booking, cancelled, rescheduled, new booking), (c) `extractClientInfoBox()` with `#f4f4f4` marker, (d) `extractDateTimeRange()`, (e) multi-block `#N` message_id suffix | BANNED anywhere: naked `new Date(str)`, `toISOString().split('T')[0]`, `toTimeString().slice()`, `getHours()`/`getDay()` without TZ. Missing keyword = whole email class silently drops. |
| `parseBooksyEmail()` (Spanish path) | (a) `parseDateTimeSpanish()` helper with same EDT/EST round-trip, (b) keyword switch recognizes ES subjects (nueva reserva/cita, cambió/cambiada, canceló/cancelada, ha cancelado/cambiado, modificó, reprogramada — see `references/parser-languages.md`), (c) every EN keyword has an ES counterpart, (d) matching unit-test coverage per locale | EN-only regression drops all ES emails. Half-finished locale = silent drops. |
| New appointment INSERT into `external_calendar_events` | (a) `message_id` UNIQUE (with `#N` suffix for multi-block), (b) `status='confirmed'` default, (c) `barber_id` resolved via `booksy_sync_email`, (d) `location_id` resolved via `resolveBarberLocation(mode='appointment', date)` from `barber_schedules`, (e) `upsert_client_from_service` RPC call (CRM upsert — NEW appts ONLY, not reschedule/cancel), (f) push notification to barber (coupled to bulletproof-push-notifications) | Missing UNIQUE suffix = duplicate rows on multi-block. Missing location = event orphan. CRM upsert on reschedule = client churn. |
| Reschedule parse path | (a) 3-strategy match in `check-events.ts`: external_id → previousStartTime+clientName ±5min → clientName-only ±30min, (b) strategies MUST execute in order (fewest false-matches first), (c) on match → UPDATE existing row (not INSERT duplicate), (d) `booksy_sync_logs` records which strategy matched, (e) NO `upsert_client_from_service` call on reschedule | Reorder = false matches. INSERT instead of UPDATE = ghost duplicate on calendar. |
| Cancel parse path | (a) 4-strategy match: external_id → clientName+startTime ±5min → clientPhone+startTime ±5min → startTime-alone (only when 1 event matches), (b) match → UPDATE `status='cancelled'` (never DELETE), (c) referral event revoke if `referral_events` has a conversion row pointing at this appt, (d) availability API stops blocking this slot (status='confirmed' filter in consumers) | DELETE loses audit trail. Missing referral revoke = leaked commission. |
| `useCalendarEvents.ts` hook | (a) `.in('status', ['confirmed'])` filter excludes cancelled AND converted, (b) ±5min dedup vs Google Calendar events, (c) realtime channel subscription to `external_calendar_events`, (d) cache: `export const dynamic = 'force-dynamic'` + Supabase factory `cache: 'no-store'` | Missing filter = cancelled events re-appear. Missing dedup = duplicate render (Booksy + Google). Cache drift = stale UI. |
| `bookings/from-external/route.ts` (convert-to-booking) | (a) idempotency: read row, reject if `status='converted'`, (b) atomic UPDATE to `converted` + INSERT bookings row, (c) service match prefers `barber_custom_services` (case-insensitive, curly-quote-normalized), (d) father+son split when `duration >= 75 minutes` (two equal-half bookings), (e) `upsert_client_from_service` RPC call, (f) 400 when barber has zero `barber_custom_services` | Repeated POSTs without idempotency = duplicate bookings. Missing custom services = blanket reject. Wrong threshold = incorrect split. |
| Availability API (`bookings/availability/route.ts`) | (a) reads `external_calendar_events` WHERE `status='confirmed'`, (b) timezone `America/New_York` on slot generation, (c) Supabase factory `cache: 'no-store'`, (d) overlap logic in `src/lib/queue/booking-conflicts.ts` consumes same filter | Stale read = overbooking. Wrong TZ = Ron Whitaker 4-hour drift (2026-03-28 incident). |
| Realtime propagation (`external_calendar_events` in `supabase_realtime`) | (a) publication includes `external_calendar_events`, (b) `useCalendarEvents` subscribes on every consumer (3 calendar pages), (c) INSERT/UPDATE via service-role triggers realtime broadcast, (d) RLS still applies to subscribers (barber sees own; owner sees all) | Missing publication = calendar needs hard refresh to see new Booksy appt. RLS gap = info leak across barbers. |
| `barber_schedules` lookup (via `resolveBarberLocation`) | (a) day_of_week resolution uses `America/New_York` TZ (NOT UTC), (b) barber has schedule coverage for appt day, (c) fallback behavior when no schedule row exists, (d) single location per day per barber (no ambiguity) | UTC vs ET = wrong day-of-week = wrong location. Ron Whitaker / morales Luis incident. |
| Per-barber `booksy_sync_email` unique routing | (a) `booksy_sync_email` UNIQUE constraint on `barbers`, (b) `booksy_sync_enabled = true` gates inbound processing, (c) enabled barbers have a schedule AND at least one `barber_custom_services` row, (d) no-match event → `parse_status='skipped'` + 200 response (so Resend stops retrying) | Collision = wrong-barber appt. Enabled-but-no-services = every convert-to-booking fails. 5xx response = Resend retries indefinitely. |
| `owner/booksy-logs/route.ts` (log viewer) | (a) owner RLS only (`role='owner'`), (b) pagination on `booksy_sync_logs` by `received_at DESC`, (c) `SyncLogsView.tsx` renders `parse_status` + `error_message` + email_subject, (d) no PII leak (raw email body shown only to owner) | RLS gap = barber sees other barbers' parse logs. |
| Timezone handling anywhere in the pipeline | Any date/time operation MUST use `timeZone: 'America/New_York'` per MEMORY.md Booksy Timezone Rule. Verify at: `parser.ts`, `from-external/route.ts`, `resend/inbound/route.ts` (notifications + resolveBarberLocation), `availability/route.ts`, `migrate-appointments/route.ts`, `useCalendarEvents.ts` | Vercel UTC-vs-ET = 4-hour drift on every appt. Historic incident: Ron Whitaker 8 AM EDT stored as 12:00 PM (UTC). |
| `public/SUPABASE factory` for webhook chain | `createAdminClient()` on inbound path — RLS on `external_calendar_events` / `booksy_sync_logs` blocks anon writes. Cache no-store on the admin client per Next.js 14 data-cache rule | Wrong client = RLS rejects INSERT silently. Stale cache = replay of old email body. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the Booksy parser domain values:

```sql
-- 1. Enumerate Booksy parser domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'external_calendar_events','booksy_sync_logs',
    'barbers','bookings','barber_custom_services','barber_schedules','clients','locations'
  )
ORDER BY table_name;
-- Expected: 8 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on parser-owned tables
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('external_calendar_events','booksy_sync_logs')
ORDER BY tablename, policyname;
-- Expected: barber-select-own, owner-all, service-role-write on each.
-- Missing policies = RLS gap; FLAG in coverage report.

-- 3. Triggers on parser tables (expected: 0 parser-owned)
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('external_calendar_events','booksy_sync_logs')
ORDER BY event_object_table, trigger_name;
-- Expected: 0 domain-owned triggers; inserts flow through service-role client.

-- 4. RPC functions referenced
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('upsert_client_from_service');
-- Expected: 1 row, has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%booksy%' OR name ILIKE '%external_event%' OR name ILIKE '%external_calendar%'
   OR name ILIKE '%007%integrations%' OR name ILIKE '%009%calendar%' OR name ILIKE '%026%ical%'
ORDER BY executed_at;
-- Expected: at least 5 rows (see SURFACE_INVENTORY.md section 10).

-- 6. Realtime publication — external_calendar_events must be in supabase_realtime
SELECT tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND tablename IN ('external_calendar_events','booksy_sync_logs');
-- Expected: external_calendar_events row present (calendar UIs depend on it).
```

Attach all 6 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants (read, don't run)

1. **Parser handles BOTH English and Spanish subjects**
   - File: `src/lib/booksy/parser.ts`
   - `parseBooksyEmail()` switch on subject recognizes the English keywords (new appointment / changed booking / cancelled / rescheduled / new booking) AND Spanish keywords (nueva reserva / nueva cita / cambió / cambiada / canceló / cancelada / ha cancelado / ha cambiado / modificó / reprogramada).
   - Full keyword list in `references/parser-languages.md`. If any keyword is missing from the switch, a whole class of emails silently maps to `type: 'unknown'` and is dropped by the webhook.

2. **Timezone detection uses `America/New_York` round-trip verification**
   - File: `src/lib/booksy/parser.ts` → `parseDateTime()` and `parseDateTimeSpanish()`.
   - Both functions must try EDT (UTC-4) first, then EST (UTC-5), and verify via `Intl.DateTimeFormat('America/New_York')` round-trip.
   - BANNED patterns anywhere in `src/lib/booksy/`: naked `new Date(str)`, `toISOString().split('T')[0]` for local date, `toTimeString().slice(...)` for local time, `getHours()`/`getDay()` without TZ adjustment.

3. **Resend inbound webhook verifies Svix signature**
   - File: `src/app/api/webhooks/resend/inbound/route.ts`
   - Uses `svix` library to verify `svix-id`, `svix-timestamp`, `svix-signature` headers against `RESEND_WEBHOOK_SECRET` env var.
   - Returns 401 on verification failure. No fallback.

4. **Barber resolution is by `booksy_sync_email` only**
   - Webhook looks up `barbers` where `booksy_sync_email = recipientEmail` (the `to` address of the inbound email).
   - No fallback to matching by sender email, name, or phone. If no barber matches, event is logged to `booksy_sync_logs` with `parse_status='skipped'` and the webhook returns 200 (so Resend doesn't retry forever).

5. **Dedup key is `message_id`**
   - `external_calendar_events.message_id` is UNIQUE. Duplicate Resend deliveries must upsert/ignore, not insert twice.
   - For multi-appointment emails, message_id is suffixed with `#0`, `#1`, ... per service block to keep UNIQUE intact.

6. **Reschedule matching has three fallback strategies, in this order**
   1. `external_id` match (Booksy booking ID if present).
   2. `previousStartTime + clientName` within ±5 min.
   3. `clientName` only, within ±30 min of new start time (catches confirmed-proposal emails that lack old time).
   - Missing any strategy causes either a lost reschedule or a ghost duplicate event.

7. **Cancel matching has four fallback strategies, in this order**
   1. `external_id`.
   2. `clientName + startTime` within ±5 min.
   3. `clientPhone + startTime` within ±5 min.
   4. `startTime` alone (use only when 1 event matches that window).
   - On match, row is UPDATEd to `status='cancelled'` — not deleted.

8. **`useCalendarEvents` filters Booksy to `status='confirmed'` only**
   - File: `src/lib/hooks/useCalendarEvents.ts`
   - Query includes `.in('status', ['confirmed'])`. Cancelled AND converted Booksy events must never appear on calendars.
   - Dedup window of ±5 min between Booksy-via-DB events and the same barber's Google Calendar events prevents double rendering.

9. **Convert-to-booking is idempotent**
   - File: `src/app/api/bookings/from-external/route.ts`
   - POST first reads `external_calendar_events` row; rejects if `status='converted'`. On success, updates row to `converted` atomically with booking insert.
   - Service matching prefers `barber_custom_services` (case-insensitive, curly-quote-normalized); falls back to the barber's first active custom service; rejects with 400 if the barber has zero custom services.
   - Father+son duplication triggers only when duration ≥ 75 minutes; splits into two bookings of equal half-duration.

10. **RLS is enabled on both tables**
    - `external_calendar_events` — barbers see own; owners see all.
    - `booksy_sync_logs` — barbers see own; owners see all.
    - Service role client is the only writer.

11. **All Supabase factories include `cache: 'no-store'`** (per MEMORY.md "Next.js 14 Data Cache" rule). Webhook must not read stale availability data.

### Data-level invariants

Run queries in `references/audit-queries.sql` via `mcp__supabase-mt__execute_sql`. SELECT-only. Expected 0 rows unless a query notes otherwise.

Key queries:
- Duplicate `message_id` rows (should be blocked by UNIQUE, so 0).
- `external_calendar_events` with status NOT in ('confirmed','cancelled','converted').
- Rows where `end_time <= start_time` (parse bug).
- Rows where `start_time` is within the last 48h but `parse_status` of its log is not `success`.
- Barbers with `booksy_sync_enabled = true` but no `booksy_sync_email` set.
- Barbers with `booksy_sync_email` set but no matching logs in last 30 days (likely dead forwarding).
- Orphaned events where `barber_id` points to a deleted/inactive barber.
- Cancelled Booksy events that still block availability (should be impossible if code invariant 8 holds — cross-check).

### Output template — MANDATORY Coverage Report

Every Booksy parser audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Booksy Parser Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: X/8 PASS | FAIL (list missing)
- RLS policies found: X (expected ≥2 per table across 2 tables)
- Triggers found: X (expected 0 parser-owned)
- RPCs found: upsert_client_from_service present Y/N
- Migrations confirmed: X/5
- Realtime publication includes external_calendar_events: Y/N

### Findings
[Ranked critical/high/medium/low with file:line anchors]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (29 files from SURFACE_INVENTORY.md sections 1-5) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/webhooks/resend/inbound/route.ts | PASS/FAIL/NOT-RUN | e.g. "inbound/route.ts:64 — svix Webhook.verify called before processing" |
| 2 | src/app/api/bookings/from-external/route.ts | | |
| 3 | src/app/api/owner/booksy-logs/route.ts | | |
| 12 | src/lib/booksy/parser.ts (EN+ES) | | e.g. "parser.ts:198 — parseDateTime round-trip via Intl DateTimeFormat" |
| 13 | src/lib/booksy/check-events.ts | | |
| 14 | src/lib/queue/booking-conflicts.ts | | |
| 15 | src/lib/hooks/useCalendarEvents.ts | | e.g. "useCalendarEvents.ts:112 — .in('status', ['confirmed']) filter" |
| 16 | src/lib/hooks/useExternalAppointments.ts | | |
| ... | [all 29 from §§1-5] | | |

Files audited with proof-of-read: N / 29 (target: 29/29). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (8 tables from SURFACE_INVENTORY.md section 6)
| Table | Row count | Status dist | NULL violations | Verdict |
|---|---|---|---|---|
| external_calendar_events | | confirmed/cancelled/converted | end_time<=start_time | |
| booksy_sync_logs | | success/failed/skipped | — | |
| barbers (booksy_sync_*) | — | sync_enabled split | unique booksy_sync_email | |
| bookings | — | — | — | |
| barber_custom_services | — | — | — | |
| barber_schedules | — | — | — | |
| clients | — | — | — | |
| locations | — | — | — | |

Tables audited: N / 8

### Pillar 3 — Queries (all queries from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| I1 | message_id UNIQUE constraint | | |
| I14 | RLS enabled on both tables | | |
| I15 | realtime publication membership | | |
| I2 | duplicate message_id | | |
| I3 | status enum | | |
| I4 | end_time <= start_time | | |
| I5 | source distribution | | |
| I7 | orphan barber_id | | |
| I8 | orphan location_id | | |
| I13 | converted w/o live booking | | |
| I9a | sync enabled but no email | | |
| I9b | booksy_sync_email not unique | | |
| I10 | last-seen inbound per barber | | |
| I11 | opted-in barbers missing custom services | | |
| — | barbers missing schedules coverage | | |
| I12 | parse_status 7-day distribution | | |
| — | recent failed parses sample | | |
| — | parse success w/o event | | |
| — | events per barber 30d | | |
| — | events by location | | |
| — | timezone spot-check | | |
| — | midnight-4am Eastern TZ drift | | |
| — | cancelled volume per day | | |
| — | stale 'confirmed' events >30d past | | |

Queries run: N / Total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (2 parser tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| external_calendar_events | | barber-own, owner-all, service-role-write (+ public-read per 20260228) | |
| booksy_sync_logs | | barber-own, owner-all, service-role-write | |

RLS tables audited: N / 2

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 8, 11, 14)
| Integration | Verdict | Note |
|---|---|---|
| Resend inbound Svix signature verification | | |
| Resend inbound barber resolution (booksy_sync_email only) | | |
| message_id UNIQUE + #N suffix for multi-block | | |
| Reschedule 3-strategy fallback order | | |
| Cancel 4-strategy fallback order | | |
| useCalendarEvents `.in('status',['confirmed'])` filter | | |
| useCalendarEvents ±5min dedup vs Google | | |
| convert-to-booking idempotency (`status='converted'` check) | | |
| Father+son 75-min split | | |
| upsert_client_from_service RPC — new appts only | | |
| Supabase factories `cache: 'no-store'` | | |
| external_calendar_events in supabase_realtime | | |
| Timezone America/New_York on parse paths | | |

Integrations audited: N / 13

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| resend/inbound → {Svix verify, booksy_sync_email lookup, parseBooksyEmail call, log on skip + success, admin client} | YES/NO | |
| parseBooksyEmail (EN) → {parseDateTime EDT/EST, EN keyword switch, extractClientInfoBox #f4f4f4, multi-block #N suffix, banned TZ patterns} | YES/NO | |
| parseBooksyEmail (ES) → {parseDateTimeSpanish, ES keyword switch, EN↔ES parity, per-locale unit tests} | YES/NO | |
| New appt INSERT → {message_id UNIQUE +#N, status=confirmed, barber/location resolve, upsert_client RPC new-only, push to barber} | YES/NO | |
| Reschedule → {3-strategy match in order, UPDATE not INSERT, no upsert_client, log strategy matched} | YES/NO | |
| Cancel → {4-strategy match in order, UPDATE status=cancelled (not DELETE), referral revoke, availability unblock} | YES/NO | |
| useCalendarEvents → {.in('status',['confirmed']), ±5min Google dedup, realtime subscribe, force-dynamic + cache: no-store} | YES/NO | |
| convert-to-booking → {idempotency read-before, atomic convert+insert, custom_services service match, 75-min father+son, upsert_client, 400 on no services} | YES/NO | |
| Availability API → {status=confirmed filter, America/New_York TZ, cache: no-store, booking-conflicts consumes same filter} | YES/NO | |
| Realtime publication → {external_calendar_events in supabase_realtime, 3 consumers subscribe, RLS respected per role} | YES/NO | |
| resolveBarberLocation → {America/New_York day_of_week, schedule coverage, fallback, single-location-per-day} | YES/NO | |
| booksy_sync_email routing → {UNIQUE constraint, sync_enabled gate, enabled barber has schedule + custom_services, no-match → skipped + 200} | YES/NO | |
| owner/booksy-logs → {owner RLS only, paginated DESC, error_message + subject rendering, no PII leak to barbers} | YES/NO | |
| Timezone America/New_York in ALL paths → {parser, from-external, resend/inbound, availability, migrate-appointments, useCalendarEvents} | YES/NO | |
| Admin client + cache no-store on inbound chain → {createAdminClient use, cache wrapper present, no stale fetch replay} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/lib/booksy/check-events.ts] | Reschedule + cancel fallback chain lives here — wrong order = ghost rows | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Resend inbound dashboard, Gmail forwarding config per barber, Booksy template change log): <list>.

If zero gaps: write "No gaps identified. All 53 surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 53 (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL BOOKSY PARSER AUDIT — N surfaces unaudited, M coupling violations" instead of "Booksy Parser Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for the symptom and one concrete example (client name OR message_id OR date+barber). The "User Reports Override Queries" rule applies — if the user says "I see X on the calendar," X is ground truth. Find the code path that produced it, don't argue with it.

2. Common symptoms — map to incidents.md:
   - "Booksy appointment is 4 hours late / at midnight" → timezone regression. Pattern #1 in `incidents.md`.
   - "Spanish email didn't create an event" → keyword missing OR Spanish date path broken. Pattern #2.
   - "Reschedule created a duplicate row instead of updating" → match strategy failed. Pattern #3.
   - "Cancelled appointment still shows on calendar" → useCalendarEvents filter regression OR cancel match never ran. Pattern #4.
   - "Two identical Booksy rows for the same client" → message_id collision OR multi-block suffix missing. Pattern #5.
   - "Barber X stopped syncing 3 days ago" → Gmail forwarding broken, or booksy_sync_enabled flipped, or RESEND_WEBHOOK_SECRET rotated. Pattern #6.
   - "Kids + parent booked as one appointment" → service block extraction missed multi-block, OR father+son split didn't fire. Pattern #7.
   - "Convert-to-booking fails with no matching service" → barber has no `barber_custom_services`. Pattern #8.

3. Trace order: parser.ts (extract) → route.ts (persist) → DB row → useCalendarEvents (render). Pick a SINGLE concrete example and walk it through each layer. Do NOT open files outside this chain without user approval.

4. Three-file rule and two-strike rule apply. If the second debugging approach fails, STOP and report findings.

---

## Mode: scale-check

Goal: can this pipeline handle every barber, every location, every locale without breaking? Produce a "must-fix-before-rolling-out-to-barber-N" checklist.

### Per-barber readiness

1. **Every barber opting in has `booksy_sync_email` AND `booksy_sync_enabled = true`.** SQL in `audit-queries.sql`.
2. **Every barber's `booksy_sync_email` is unique.** Collisions would route wrong appointments.
3. **Every opted-in barber has at least one active row in `barber_custom_services`.** Without one, convert-to-booking will always fail with "service not matched."
4. **Every opted-in barber has `barber_schedules` coverage for their working days.** `from-external/route.ts` uses `resolveBarberLocation(mode='appointment', date)` which reads schedules by day_of_week.

### Locale readiness

The parser today supports English + Spanish. If Booksy adds a new language template per barber preference, the switch in `parseBooksyEmail()` and the date-parse helper must extend. See `references/parser-languages.md` for the extension pattern — add a new date-parse helper per language and a keyword group in the type-detection switch.

### Template drift

Booksy occasionally rolls template changes. Signals:
- `booksy_sync_logs.parse_status='failed'` rate climbs >5% over 7 days.
- `extractClientInfoBox()` returns null for emails whose raw_email_body still contains the expected `#f4f4f4` marker (regex mismatch).
- `extractDateTimeRange()` returns null where raw body clearly contains a date.

### Hardcoded assumptions to audit before scaling

1. **`#f4f4f4` gray-box color** in `parser.ts` — Booksy's info box background. If Booksy changes the shade, `extractClientInfoBox()` silently returns null and client info falls back to noisier heuristics. Grep for the literal, confirm still one location.
2. **EDT-first default on ambiguous dates** — during DST transitions, a 1 AM EDT/EST overlap may guess wrong. Acceptable today; would break if a new location sits in a different time zone.
3. **Father+son duration threshold = 75 minutes** — lives in `from-external/route.ts`. If services in the future exceed 75 minutes as a single appointment (deep treatments, tattoos), this will incorrectly split them.
4. **Client dedup window ±2 min on multi-block emails** — only safe while back-to-back appointments are ≥ 5 min apart.

Grep for:
```bash
grep -rn "f4f4f4\|75 \* 60\|duration.*75\|'America/New_York'" src/lib/booksy/ src/app/api/bookings/from-external/ src/app/api/webhooks/resend/
```

Expected: scoped to the parser + inbound route. Any stray appearance elsewhere is a leak.

---

## Mode: fix

The only mode that writes code. Closes the loop between "audit/diagnose found X" and "X is fixed + verified." Does NOT commit, does NOT push, does NOT touch the production DB. See `references/fix-patterns.md`.

### Activation is EXPLICIT

Fix mode fires ONLY when the user types one of:
- `apply pattern N` — where N is a pattern number from `references/fix-patterns.md`.
- `fix <symptom-phrase>` — natural-language form; the skill maps to a pattern and CONFIRMS before doing anything.
- `enter fix mode` followed by a scope statement.

Any other phrasing → audit or diagnose. An audit finding NEVER auto-triggers a fix. Because this pipeline is load-bearing for real client appointments, the user must explicitly opt into changes.

### Workflow (strict — every step, no shortcuts)

1. **Scope declaration.** Restate in 1–2 sentences which pattern (number + name), which file(s) will change, any downstream impact (especially on useCalendarEvents or convert-to-booking).
2. **Preflight.** Read the target file. Confirm the "before" block from `fix-patterns.md → Pattern N` still matches current code — imports, function signatures, surrounding context, NOT line numbers (which drift). If drift → STOP and report what differs. Do NOT apply a stale pattern.
3. **Scope audit.** Confirm the fix touches ONLY files named in the pattern's Before/After blocks. If a fix would require touching an unrelated system → STOP and ask for approval before expanding.
4. **Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes` / `apply` / `proceed`. No implicit approval.
5. **Apply.** Single `Edit` call. ONE pattern per fix-mode invocation. Never bundled.
6. **Post-fix verification.**
   - `npx tsc --noEmit` passes.
   - Re-run the pattern's post-fix grep and/or SQL check.
   - If the pattern touches parser logic, run the unit test: `npx tsx tests/unit/booksy-parser.test.ts`.
   - If it touches calendar rendering, tell the user "test in the browser — I can't verify UI."
7. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/booksy-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | If a fix changes anything the calendar UIs render, check the owner mirror. |
| `safe-query` | Any DB write (very rare — backfill only) must route through safe-query. |
| `bulletproof-bookings` | Any fix that touches `bookings` (via convert-to-booking) must also pass bookings invariants. |

---

## Downstream Consumers & Propagation

When a Booksy email hits the webhook, every surface that reads appointments must reflect the change within one realtime tick.

### Consumers (every surface that reads external_calendar_events)

| Consumer | File / URL | What it reads |
|---|---|---|
| Barber calendar | `src/app/(dashboard)/barber/calendar/page.tsx` | this barber's Booksy events |
| Owner my-chair calendar | `src/app/(dashboard)/dashboard/my-chair/calendar/page.tsx` | mirror of barber calendar |
| Owner all-calendar | `src/app/(dashboard)/dashboard/calendar/page.tsx` | Booksy events for all barbers |
| Calendar events hook | `src/lib/hooks/useCalendarEvents.ts` | unified feed — Booksy + Google + bookings + queue |
| Availability API | `src/app/api/bookings/availability/route.ts` | blocks slots overlapping confirmed Booksy events |
| Convert-to-booking | `src/app/api/bookings/from-external/route.ts` | reads single event, writes booking, marks converted |
| Owner Booksy logs viewer | `src/app/api/owner/booksy-logs/route.ts` | paginated `booksy_sync_logs` view |

### Propagation invariants

1. **Webhook uses admin (service-role) Supabase client** — RLS policies block anon/writes; only service role can insert.
2. **`external_calendar_events` is in the Supabase realtime publication** so calendar UIs update without refresh. Verify:
   ```sql
   SELECT tablename FROM pg_publication_tables
   WHERE pubname = 'supabase_realtime' AND tablename = 'external_calendar_events';
   -- Expected: 1 row
   ```
3. **`useCalendarEvents` dedupes Booksy-vs-Google within ±5 min** so the same appointment synced to both doesn't render twice.
4. **Availability API reads Booksy events with `status='confirmed'` ONLY** — cancelled events must not block slots.
5. **`from-external` idempotency** — repeated POSTs of the same external event return 409, not a second booking.
6. **Father+son split** preserves total duration and inserts two rows at start+0 and start+halfDuration with the same barber_id/location_id/service_id.
7. **CRM upsert on new appointments only** (`upsert_client_from_service` RPC) — rescheduled or cancelled emails DO NOT touch `clients` table to avoid churn.

### Diagnose: "I cancelled a Booksy appointment but it still shows on the calendar"

1. DB state: `SELECT id, status, updated_at FROM external_calendar_events WHERE id = '...'`. Is status='cancelled'?
2. Webhook log: `SELECT parse_status, error_message FROM booksy_sync_logs WHERE barber_id = '...' ORDER BY received_at DESC LIMIT 5`. Did the cancel email arrive and parse?
3. If status is still 'confirmed' in DB → cancel-match code path failed. Check parser's cancel keywords; check `findMatchingExternalEventForCancellation` fallback chain.
4. If status IS 'cancelled' but UI still shows it → `useCalendarEvents.ts` filter regression. Grep for `.in('status', ['confirmed']`.
5. Cache layer: calendar route has `export const dynamic = 'force-dynamic'`? Supabase factory includes `cache: 'no-store'`?
6. If all green but UI stale → hard refresh; if still stale, realtime channel binding is dead. Re-check `useCalendarEvents` channel subscription.

---

## HARD RULES

- NEVER write to production DB. Parser audits are READ-ONLY.
- NEVER modify `src/lib/booksy/parser.ts` without user approval — the EDT/EST detection is load-bearing and the unit tests exist for a reason.
- NEVER add a new language switch without a matching date-parse helper AND a unit test case covering it. Half-finished locale = silent drops.
- NEVER change the `external_calendar_events.message_id` UNIQUE constraint — duplicate delivery is a real scenario.
- NEVER swap the order of reschedule or cancel match strategies — the order exists because earlier strategies produce fewer false matches.
- NEVER merge Booksy events into `bookings` automatically — conversion is a deliberate user action via `/api/bookings/from-external`.
- NEVER test on real barbers. Real barbers (Gustavo, Brayan, Eddie, Fran, Juan, Junii, Lili, Pedro, Stanley) have live Booksy integrations. Use test barbers only.
- ALWAYS use `mcp__supabase-mt__` — never `mcp__supabase__` (that's the nightclub project).
- ALWAYS honor branch workflow, cross-dashboard mirroring, two-strike rule, and stay in scope.
- If the user overrides any hard rule explicitly, proceed but flag the override.
