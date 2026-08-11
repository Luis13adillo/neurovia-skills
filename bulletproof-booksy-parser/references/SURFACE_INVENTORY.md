# Booksy Parser Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the Booksy email parser pipeline touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — parser-owning (3 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/webhooks/resend/inbound/route.ts` | POST | Resend inbound webhook → Svix signature verify → `parseBooksyEmail()` → upsert `external_calendar_events` + log `booksy_sync_logs` |
| 2 | `src/app/api/bookings/from-external/route.ts` | POST | Convert external event → live booking (idempotent; reads `external_calendar_events`, writes `bookings`, marks source row converted) |
| 3 | `src/app/api/owner/booksy-logs/route.ts` | GET | Owner-facing paginated `booksy_sync_logs` viewer |

## 2. API Routes — parser-consumers / parser-related (8 routes)

These routes read or depend on `external_calendar_events`. They must honor the `status='confirmed'` filter + overlap rules.

| # | Route | Touch |
|---|---|---|
| 4 | `src/app/api/bookings/availability/route.ts` | Filters time slots vs `external_calendar_events` confirmed rows |
| 5 | `src/app/api/barber/booksy/settings/route.ts` | GET/PATCH per-barber `booksy_sync_email` + `booksy_sync_enabled` |
| 6 | `src/app/api/barber/sync-calendar/route.ts` | Manual resync trigger (may poll external source) |
| 7 | `src/app/api/barber/google/status/route.ts` | Cross-reference — Booksy dedup vs Google calendar events |
| 8 | `src/app/api/barber/migrate-appointments/route.ts` | One-time migration of Booksy appts into `bookings` |
| 9 | `src/app/api/bookings/route.ts` | Reads external events for overlap detection |
| 10 | `src/app/api/bookings/[id]/reschedule/route.ts` | Reads external events for overlap |
| 11 | `src/app/api/queue/route.ts` | Reads external events to avoid conflicting queue assigns |

## 3. Library / helpers (3 files)

| # | File | Role |
|---|---|---|
| 12 | `src/lib/booksy/parser.ts` | `parseBooksyEmail()` + `parseDateTime()` (EN) + `parseDateTimeSpanish()` (ES) + `extractClientInfoBox()` + `extractDateTimeRange()` + keyword switch |
| 13 | `src/lib/booksy/check-events.ts` | Event-matching helpers for reschedule/cancel fallback chain |
| 14 | `src/lib/queue/booking-conflicts.ts` | Overlap logic that consumes external events |

## 4. Hooks (2 hooks)

| # | File | Purpose |
|---|---|---|
| 15 | `src/lib/hooks/useCalendarEvents.ts` | Unified calendar feed — filters `external_calendar_events` to `status='confirmed'`, dedups vs Google within ±5 min |
| 16 | `src/lib/hooks/useExternalAppointments.ts` | Barber-scoped external event feed |

## 5. UI surfaces (6 pages + 4 components)

| # | Page | Displays |
|---|---|---|
| 17 | `src/app/(dashboard)/barber/calendar/page.tsx` | Barber's own Booksy events |
| 18 | `src/app/(dashboard)/dashboard/my-chair/calendar/page.tsx` | Owner-as-barber mirror |
| 19 | `src/app/(dashboard)/dashboard/calendar/page.tsx` | Owner all-barbers calendar |
| 20 | `src/app/(dashboard)/dashboard/bookings/page.tsx` | Booking list with Booksy rows |
| 21 | `src/app/(dashboard)/dashboard/page.tsx` | Dashboard home — may surface sync stats |
| 22 | `src/app/(dashboard)/barber/setup/page.tsx` | Onboarding — `booksy_sync_email` collect step |

| # | Component | Purpose |
|---|---|---|
| 23 | `src/components/dashboard/owner/SyncLogsView.tsx` | Paginated log browser |
| 24 | `src/components/dashboard/barber/BooksySyncTab.tsx` | Barber per-profile Booksy settings |
| 25 | `src/components/dashboard/calendar/MyCalendarGrid.tsx` | Renders external events on grid |
| 26 | `src/components/dashboard/calendar/CalendarEventDetailModal.tsx` | Event detail + convert-to-booking CTA |
| 27 | `src/components/dashboard/barber/UpcomingAppointmentsList.tsx` | Upcoming appts incl. Booksy |
| 28 | `src/components/dashboard/bookings/CalendarBottomBar.tsx` | Mobile calendar controls |
| 29 | `src/components/dashboard/clients/ClientListTable.tsx` | Client list — counts Booksy source visits |

## 6. Database tables (2 parser-owned)

| # | Table | Role |
|---|---|---|
| 30 | `external_calendar_events` | One row per parsed Booksy appointment; status in (`confirmed`,`cancelled`,`converted`); `message_id` UNIQUE |
| 31 | `booksy_sync_logs` | One row per inbound email; `parse_status` in (`success`,`failed`,`skipped`); raw email subject + error_message |

Parent tables the parser touches (NOT parser-owned but MUST be audited):
| 32 | `barbers` | `booksy_sync_email`, `booksy_sync_enabled` columns |
| 33 | `bookings` | convert-to-booking writes here |
| 34 | `barber_custom_services` | service matching for convert-to-booking |
| 35 | `barber_schedules` | `resolveBarberLocation()` reads day_of_week → location_id |
| 36 | `clients` | CRM upsert via `upsert_client_from_service` RPC on new appts only |
| 37 | `locations` | `location_id` FK on external events |

## 7. RPC functions (1 referenced)

| # | Function | Purpose |
|---|---|---|
| 38 | `upsert_client_from_service` | Called by `from-external/route.ts` on new appt convert (NOT on reschedule/cancel) |

## 8. DB triggers (0 parser-owned)

No triggers write to `external_calendar_events` or `booksy_sync_logs`. Inserts happen from the webhook via service-role client.

## 9. RLS policies (expected coverage)

Expected policies per table. An audit MUST enumerate actual vs expected.

| # | Table | Expected policies |
|---|---|---|
| 39 | `external_calendar_events` | barber-select-own (`barber_id = auth.uid barber record`), owner-all, service-role-write, public-read for specific cases (see migration `20260228`) |
| 40 | `booksy_sync_logs` | barber-select-own, owner-all, service-role-write |

## 10. Migrations (5 migrations)

| # | Migration | What it did |
|---|---|---|
| 41 | `007_add_barber_integrations.sql` | Original Booksy integration columns (later refactored) |
| 42 | `009_add_google_calendar.sql` | Google Calendar parallel path (dedup partner) |
| 43 | `026_remove_ical_booksy_columns.sql` | Cleanup of legacy iCal columns |
| 44 | `042_booksy_sync.sql` | CORE: `external_calendar_events` + `booksy_sync_logs` tables, `booksy_sync_email` + `booksy_sync_enabled` on barbers, indexes, RLS |
| 45 | `20260228000000_external_events_public_read.sql` | Adjust RLS for specific public-read cases |

## 11. External integrations (2 integrations)

| # | System | Touch points |
|---|---|---|
| 46 | Resend inbound | Gmail → Resend forward → `/api/webhooks/resend/inbound` with Svix signature |
| 47 | Booksy email templates | Upstream — English + Spanish subjects, `#f4f4f4` info-box color, EDT/EST offsets |

## 12. Cron / background jobs (0 parser-owned)

No cron fires the parser directly — Resend pushes inbound emails as they arrive. Related:
| 48 | `src/app/api/cron/google-calendar-sync/route.ts` | Pulls Google events — deduped against Booksy in `useCalendarEvents` |

## 13. Environment variables

| # | Var | Purpose |
|---|---|---|
| 49 | `RESEND_WEBHOOK_SECRET` | Svix signature verification on inbound webhook |
| 50 | `RESEND_API_KEY` | Outbound email (redundancy channel, not parser) |
| 51 | `SUPABASE_SERVICE_ROLE_KEY` | Admin client for service-role writes on inbound |
| 52 | `NEXT_PUBLIC_SUPABASE_URL` | — |

## 14. Realtime publications

| # | Publication | Why |
|---|---|---|
| 53 | `external_calendar_events` in `supabase_realtime` | Calendar UIs subscribe for live updates when inbound email parses |

---

## Surface Totals

- **API routes:** 3 owning + 8 consumers = 11 total
- **Library files:** 3
- **Hooks:** 2
- **UI pages:** 6 + 7 components = 13
- **Database tables:** 2 parser-owned + 6 parser-touched = 8 total
- **RPC functions:** 1
- **DB triggers:** 0
- **RLS policies:** 2+ (across 2 tables)
- **Migrations:** 5
- **External integrations:** 2
- **Cron jobs:** 0 parser-owned (1 related)
- **Environment variables:** 4
- **Realtime publications:** 1

**Grand total surfaces to audit:** ~53 discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
