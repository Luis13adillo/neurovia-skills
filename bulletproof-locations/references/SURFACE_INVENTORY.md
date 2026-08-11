# Locations Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the locations system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — location-owning (3 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/locations/route.ts` | GET | List locations (public + hook source) |
| 2 | `src/app/api/locations/stats/route.ts` | GET | Per-location stats aggregation |
| 3 | `src/app/api/locations/[id]/pause/route.ts` | POST | Pause/resume `accepts_walk_ins` flag |

## 2. API Routes — location-consuming (many; list the critical ones)

| # | Route | Role |
|---|---|---|
| 4 | `src/app/api/bookings/route.ts` | Reads location for availability, writes `location_id` on booking |
| 5 | `src/app/api/bookings/availability/route.ts` | Location hours, Eastern TZ |
| 6 | `src/app/api/queue/route.ts` | Check-in needs location_id |
| 7 | `src/app/api/queue/capacity/route.ts` | Reads `hours_json.max_queue_size` |
| 8 | `src/app/api/barber/clock/route.ts` | Resolves today's location |
| 9 | `src/app/api/barber/schedule/route.ts` | Per-day location storage |
| 10 | `src/app/api/barber/location/route.ts` | Barber manual switch writes `preferred_location_id` |
| 11 | `src/app/api/barber/location-request/route.ts` | Location change requests |
| 12 | `src/app/api/auth/create-barber/route.ts` | Writes initial `preferred_location_id` |
| 13 | `src/app/api/barbers/[id]/schedule/route.ts` | Owner schedule edit recomputes `preferred_location_id` |

## 3. Library / helpers (3 files)

| # | File | Role |
|---|---|---|
| 14 | `src/lib/utils/locations.ts` | `FALLBACK_LOCATIONS`, `LOCATION_SLUGS`, `LOCATION_INFO` — safety-net constants |
| 15 | `src/lib/db/location.ts` | `resolveBarberLocation()` — priority chain for mode `current` vs `appointment` |
| 16 | `src/lib/db/locations.ts` | Locations DB helpers (CRUD + SWR-backed fetch) |

## 4. React hooks (2 hooks)

| # | File | Role |
|---|---|---|
| 17 | `src/lib/hooks/useLocations.ts` | SWR-backed location list (30s dedup + revalidateOnFocus) |
| 18 | `src/lib/hooks/useLocationDashboard.ts` | Per-location dashboard aggregation |

## 5. UI pages (13 pages that render location data)

| # | Page | Reads |
|---|---|---|
| 19 | `src/app/page.tsx` | Homepage — location cards + fallback to `locations[0]` |
| 20 | `src/app/(public)/locations/page.tsx` | Full list + `locationExtras` map (plaza, parking, mapUrl, barberCount) |
| 21 | `src/app/(public)/queue/wilmington/page.tsx` | Static kiosk check-in |
| 22 | `src/app/(public)/queue/newark/page.tsx` | Static kiosk check-in |
| 23 | `src/app/(public)/queue/new-castle/page.tsx` | Static kiosk check-in |
| 24 | `src/app/(public)/queue/edwardsville/page.tsx` | Static kiosk check-in (added 2026-04) |
| 25 | `src/app/(public)/queue/[...slug]/page.tsx` | Catch-all slug handler |
| 26 | `src/app/(public)/tv/[location]/page.tsx` | Per-location TV display |
| 27 | `src/app/(public)/team/page.tsx` | Filters barbers by location per day |
| 28 | `src/app/(public)/mtbarbers/[slug]/page.tsx` | Public profile — shows working location per day |
| 29 | `src/app/(public)/book/page.tsx` | Booking wizard step 1 — location selector |
| 30 | `src/app/(dashboard)/dashboard/locations/page.tsx` | Owner CRUD for locations |
| 31 | `src/components/site/MobileHomePage.tsx` | Mobile homepage location cards |

## 6. Shared components (3 components with location coupling)

| # | Component | Role |
|---|---|---|
| 32 | `src/components/queue/LocationQueuePage.tsx` | Shared by all static + catch-all queue pages |
| 33 | `src/components/queue/LocationCard.tsx` | Check-in wizard step 1 |
| 34 | `src/components/dashboard/WalkInForm.tsx` | Owner/barber quick walk-in — references `locations[0]` |
| 35 | `src/components/dashboard/academy/SessionScheduler.tsx` | Academy — references `locations[0]` |
| 36 | `src/components/dashboard/BarberScheduleModal.tsx` | References `locations[0]` lines 74, 89, 110 |

## 7. Database tables (1 owned + many referenced)

| # | Table | Role |
|---|---|---|
| 37 | `locations` | Primary table: `id`, `slug`, `name`, `address`, `city`, `state`, `zip`, `phone`, `hours_json`, `accepts_walk_ins`, `is_active` |

Tables that carry `location_id` FK (must preserve ON DELETE CASCADE behavior from migration 001):
| 38 | `barber_schedules` | FK |
| 39 | `queue_entries` | FK |
| 40 | `bookings` | FK |
| 41 | `staff_status` | FK |
| 42 | `academy_sessions` | FK |
| 43 | `daily_summaries` | FK |
| 44 | `cash_fee_ledger` | FK (optional column) |
| 45 | `location_change_requests` | FK (requested_location_id) |

## 8. Canonical values (per CLAUDE.md + MEMORY.md 2026-04-20)

| # | Location | Slug | UUID | State |
|---|---|---|---|---|
| 46 | Wilmington | `wilmington` | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` | DE |
| 47 | Newark | `newark` | `b2c3d4e5-f6a7-8901-bcde-f12345678901` | DE |
| 48 | New Castle | `new-castle` | `c3d4e5f6-a7b8-9012-bcde-f12345678902` | DE |
| 49 | Edwardsville | `edwardsville` | `d4e5f6a7-b8c9-0123-cdef-f12345678903` | **PA** |

Canonical phones/addresses are in the skill's main SKILL.md. Banned values: `(302) 998-0900`, `(302) 369-0900`, `(302) 555-xxxx`, "Houston, TX", hardcoded `, DE` in email footers.

## 9. RLS policies (expected per table)

| # | Table | Expected policies |
|---|---|---|
| 50 | `locations` | Public SELECT (all consumers); owner all |

## 10. Migrations (3 location-relevant migrations)

| # | Migration | What it did |
|---|---|---|
| 51 | `001_initial_schema.sql` | Base `locations` table |
| 52 | `006_add_new_castle_location.sql` | Added New Castle |
| 53 | `022_queue_pause_column.sql` | `accepts_walk_ins` column |
| 54 | `032_add_location_slug.sql` | `slug` column |
| 55 | `044_location_change_requests.sql` | Per-day location change request table |
| 56 | (no migration) Edwardsville added via DB seed 2026-04 — verify row exists |

## 11. Email / SMS templates (must use locationState, not hardcoded state)

| # | File | Purpose |
|---|---|---|
| 57 | `src/lib/email/templates.ts` | Booking confirmation / reschedule / cancellation / reminder |
| 58 | `src/lib/email/academy-templates.ts` | Academy emails |
| 59 | SMS templates (location-specific opt-in footer — if present) | Must not hardcode state |

## 12. Kiosk manifests + PWA assets (per-location)

| # | File | Purpose |
|---|---|---|
| 60 | `public/manifest-kiosk-wilmington.json` | Kiosk PWA manifest |
| 61 | `public/manifest-kiosk-newark.json` | — |
| 62 | `public/manifest-kiosk-new-castle.json` | — |
| 63 | `public/manifest-kiosk-edwardsville.json` | — |

## 13. Environment variables (per-location)

| # | Var | Purpose |
|---|---|---|
| 64 | `NEXT_PUBLIC_GOOGLE_REVIEW_URL_WILMINGTON` | Google review link |
| 65 | `NEXT_PUBLIC_GOOGLE_REVIEW_URL_NEWARK` | — |
| 66 | `NEXT_PUBLIC_GOOGLE_REVIEW_URL_NEW_CASTLE` | — |
| 67 | `NEXT_PUBLIC_GOOGLE_REVIEW_URL_EDWARDSVILLE` | — |

## 14. Middleware (slug resolution)

| # | File | Role |
|---|---|---|
| 68 | `src/middleware.ts` | Resolves slug → id for routing; must use DB or LOCATION_SLUGS constant |

## 15. `locations[0]` / `FALLBACK_LOCATIONS` usage points (known list — verify still present)

| # | File | Line(s) |
|---|---|---|
| 69 | `src/app/page.tsx` | 214 |
| 70 | `src/app/(dashboard)/dashboard/my-chair/page.tsx` | 199 |
| 71 | `src/components/site/MobileHomePage.tsx` | 92 |
| 72 | `src/app/(dashboard)/dashboard/my-chair/queue/page.tsx` | 100 |
| 73 | `src/app/(dashboard)/dashboard/my-chair/schedule/page.tsx` | 427, 600 |
| 74 | `src/components/dashboard/WalkInForm.tsx` | 35 |
| 75 | `src/components/dashboard/academy/SessionScheduler.tsx` | 74 |
| 76 | `src/components/dashboard/BarberScheduleModal.tsx` | 74, 89, 110 |
| 77 | `src/app/(dashboard)/barber/schedule/page.tsx` | 372, 397 |
| 78 | `src/app/(dashboard)/barber/walk-ins/page.tsx` | 255 |
| 79 | `src/app/(dashboard)/dashboard/queue/page.tsx` | 89, 599, 629 |

---

## Surface Totals

- **API routes:** 13 (3 location-owning + 10 location-consuming)
- **Library files:** 3
- **Hooks:** 2
- **UI pages:** 13
- **Shared components:** 5
- **Database tables:** 1 owned + 8 FK-referenced = 9 total
- **RLS policies:** 1 table
- **Migrations:** 5 (plus seed-only Edwardsville)
- **Email/SMS template files:** 2+
- **Kiosk manifests:** 4
- **Environment variables:** 4 (Google Review URLs)
- **Middleware:** 1
- **`locations[0]` hardcode sites:** 11 (fallback pattern — verify intent)

**Grand total surfaces to audit:** 70+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
