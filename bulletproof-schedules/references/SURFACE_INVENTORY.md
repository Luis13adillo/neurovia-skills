# Schedules Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the barber schedules system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — schedules-owning (4 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/barber/schedule/route.ts` | GET/PATCH | Barber self-service schedule edit; per-day location preservation (d03b8ef fix) |
| 2 | `src/app/api/barbers/[id]/schedule/route.ts` | GET/PUT | Owner-managed schedule edit; recomputes `preferred_location_id` |
| 3 | `src/app/api/barber/location/route.ts` | PUT | Barber manual primary-location switch (writes `preferred_location_id`) |
| 4 | `src/app/api/barber/location-request/route.ts` | GET/POST/PATCH | Location change requests (per-day move); dual-update on approval |

## 2. API Routes — schedules-adjacent (5 routes that consume schedule)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 5 | `src/app/api/bookings/availability/route.ts` | GET | Reads schedule to compute bookable slots + Eastern TZ |
| 6 | `src/app/api/barber/clock/route.ts` | POST | Clock-in resolves today's scheduled location via `resolveBarberLocation('current')` |
| 7 | `src/app/api/queue/rotation-preview/route.ts` | GET | Fair rotation filters by today's schedule |
| 8 | `src/app/api/auth/create-barber/route.ts` | POST | New barber insert MUST set `preferred_location_id` |
| 9 | `src/app/api/barbers/list/route.ts` | GET | Barber list filtering by location per day |

## 3. Library / helpers (2 files)

| # | File | Role |
|---|---|---|
| 10 | `src/lib/db/location.ts` | `resolveBarberLocation()` — current and appointment mode; priority chain |
| 11 | `src/lib/db/barbers.ts` | `barbers` table helpers incl. preferred_location_id writes |

## 4. React hooks (3 hooks)

| # | File | Role |
|---|---|---|
| 12 | `src/lib/hooks/useCalendarEvents.ts` | Reads barber hours for calendar bounds |
| 13 | `src/lib/hooks/useLocationRequests.ts` | Location change request list (barber + owner) |
| 14 | `src/lib/hooks/useBarbers.ts` | Barber list, filters by schedule per day |

## 5. UI pages (6 pages)

| # | Page | Audience |
|---|---|---|
| 15 | `src/app/(dashboard)/barber/schedule/page.tsx` | Barber self-service schedule |
| 16 | `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx` | Owner-as-barber schedule (mirror) |
| 17 | `src/app/(dashboard)/dashboard/barbers/page.tsx` | Owner staff management with schedule editor |
| 18 | `src/app/(dashboard)/dashboard/location-requests/page.tsx` | Owner approval UI for location change requests |
| 19 | `src/app/(public)/mtbarbers/[slug]/page.tsx` | Profile — "Works Mon, Wed, Fri" display |
| 20 | `src/app/(public)/team/page.tsx` | Team list filtered by location per day |

## 6. Shared components (2 components)

| # | Component | Role |
|---|---|---|
| 21 | `src/components/dashboard/BarberScheduleModal.tsx` | Owner schedule editor modal |
| 22 | `src/components/dashboard/academy/SessionScheduler.tsx` | Academy session scheduler (references `locations[0]`) |

## 7. Database tables (3 tables)

| # | Table | Role |
|---|---|---|
| 23 | `barber_schedules` | Per-barber per-day-of-week schedule; `location_id`, `start_time`, `end_time`, `break_start`, `break_end`, `is_active`, `updated_by` |
| 24 | `location_change_requests` | Per-barber per-day move requests; `status` (pending/approved/rejected); `reviewed_by`, `reviewed_at` |
| 25 | `barbers` (schedule-related columns) | `preferred_location_id`, `is_active` |

Parent tables:
| 26 | `locations` | FK target |
| 27 | `staff_status` | `location_id` read by `resolveBarberLocation` when barber is active |

## 8. RPC functions (1 function)

| # | Function | Purpose |
|---|---|---|
| 28 | `set_schedule_updated_by()` | Trigger function that stamps `updated_by` on barber_schedules writes |

## 9. DB triggers (1 trigger)

| # | Trigger | Table | Timing | Purpose |
|---|---|---|---|---|
| 29 | `trg_barber_schedule_audit` | `barber_schedules` | BEFORE INSERT/UPDATE | Sets `updated_by` from `auth.uid()` |

## 10. RLS policies (expected per table)

| # | Table | Expected policies |
|---|---|---|
| 30 | `barber_schedules` | Public SELECT (profile + team + booking availability); barber INSERT/UPDATE own (`barber_id IN ...`); owner all — per migration `20260409023540_harden_barber_schedules_rls_and_audit.sql` |
| 31 | `location_change_requests` | Barber SELECT/INSERT own; owner all |
| 32 | `barbers.preferred_location_id` | Covered by barbers table RLS (owner all, barber select own) |

## 11. Migrations (6 migrations)

| # | Migration | What it did |
|---|---|---|
| 33 | `001_initial_schema.sql` | Base `barber_schedules` |
| 34 | `033_add_schedule_break_times.sql` | `break_start`, `break_end` columns |
| 35 | `044_location_change_requests.sql` | `location_change_requests` table |
| 36 | `20260409023540_harden_barber_schedules_rls_and_audit.sql` | RLS tightening + `set_schedule_updated_by` trigger |
| 37 | `20260409023749_cleanup_barber_schedules_rls_open_read.sql` | Followup RLS cleanup |
| 38 | `20260421020000_schedules_realtime_publication.sql` | Realtime publication on `barber_schedules` |
| 39 | Commit `d03b8ef` (schedule route per-day preservation fix) — code-only, no migration |

## 12. Realtime publications (required)

| # | Table | Required? |
|---|---|---|
| 40 | `barber_schedules` | YES — profile/booking updates when barber toggles a day |

## 13. Code-level invariants to audit

| # | Invariant | Where |
|---|---|---|
| 41 | d03b8ef per-day preservation | `src/app/api/barber/schedule/route.ts` lines ~129-193 |
| 42 | Owner PUT recomputes `preferred_location_id` | `src/app/api/barbers/[id]/schedule/route.ts` |
| 43 | create-barber writes `preferred_location_id` | `src/app/api/auth/create-barber/route.ts` |
| 44 | `resolveBarberLocation` priority chain | `src/lib/db/location.ts` |
| 45 | `location-request` PATCH dual-updates `barber_schedules` + `staff_status.location_id` | `src/app/api/barber/location-request/route.ts` |
| 46 | Inline Supabase clients wrap `cache: 'no-store'` | `src/app/api/barber/schedule/route.ts`, `src/app/api/barber/location-request/route.ts` |
| 47 | Availability API uses `timeZone: 'America/New_York'` | `src/app/api/bookings/availability/route.ts` |
| 48 | Mirror parity barber vs my-chair schedule page | `barber/schedule/page.tsx` vs `dashboard/my-chair/schedule/page.tsx` |

## 14. External integrations (1 integration)

| # | Integration | Touch points |
|---|---|---|
| 49 | None directly — schedule feeds availability and queue routing internally. Google Calendar sync is booking-side, not schedule-side. |

## 15. Environment variables

| # | Var | Purpose |
|---|---|---|
| 50 | `NEXT_PUBLIC_APP_URL` | Used in emails when location change approved (notification flows) |

---

## Surface Totals

- **API routes:** 9 (4 schedule-owning + 5 adjacent)
- **Library files:** 2
- **Hooks:** 3
- **UI pages:** 6
- **Shared components:** 2
- **Database tables:** 3 schedule-owned + 2 parent-referenced = 5 total
- **RPC functions:** 1
- **DB triggers:** 1
- **RLS policies:** 3 tables
- **Migrations:** 6
- **Realtime tables:** 1
- **Code-level invariants:** 8
- **External integrations:** 0 (internal propagation only)
- **Environment variables:** 1

**Grand total surfaces to audit:** 45+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
