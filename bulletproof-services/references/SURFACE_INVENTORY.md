# Services Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the three-way services system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — services-owning (5 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/barber/services/route.ts` | GET/POST | GET merges global + custom for a barber; POST writes `barber_services` (NOTE: POST returns 410 since 2026-04-22 lockdown) |
| 2 | `src/app/api/barber/custom-services/route.ts` | GET/POST/PATCH/DELETE | Full CRUD on `barber_custom_services` |
| 3 | `src/app/api/bookings/availability/route.ts` | GET | Reads service duration for slot sizing |
| 4 | `src/app/api/bookings/route.ts` | POST | Routes to `service_id` OR `custom_service_id` based on lookup |
| 5 | `src/app/api/queue/route.ts` | POST | Walk-in check-in — reads ONLY `services` (global) |

## 2. API Routes — services-adjacent (3 routes that read/touch service data)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 6 | `src/app/api/queue/entry/[id]/service/route.ts` | PATCH | Change service on active queue entry |
| 7 | `src/app/api/queue/complete/route.ts` | POST | Completion writes `service_amount` + `service_name` frozen snapshot |
| 8 | `src/app/api/payments/send-link/route.ts` | POST | Reads stored `service_amount`, not live service |

## 3. Library / helpers (2 files)

| # | File | Role |
|---|---|---|
| 9 | `src/lib/db/services.ts` | Service CRUD helpers |
| 10 | `src/lib/hooks/useServices.ts` | Client-side hook (`useServices(true)` = active only, SWR) |

## 4. UI pages (10 pages)

| # | Page | Audience | Writes to |
|---|---|---|---|
| 11 | `src/app/(dashboard)/dashboard/services/page.tsx` | Owner only | `services` (global) |
| 12 | `src/app/(dashboard)/dashboard/my-chair/services/page.tsx` | Owner-as-barber | `barber_services` + `barber_custom_services` (scoped to owner barber_id) |
| 13 | `src/app/(dashboard)/barber/settings/page.tsx` (Services tab) | Barber | `barber_services` + `barber_custom_services` (self) |
| 14 | `src/app/(public)/services/page.tsx` | Public | Reads `services` |
| 15 | `src/app/(public)/queue/page.tsx` | Public walk-in | Reads `services` via `useServices(true)` |
| 16 | `src/app/(public)/book/page.tsx` | Public booking wizard | Reads `/api/barber/services?barber_id=...` |
| 17 | `src/app/(public)/mtbarbers/[slug]/page.tsx` | Public profile | Reads both sources, applies `custom_price` |
| 18 | `src/app/(public)/team/page.tsx` | Public | Lists barbers (no direct service read) |
| 19 | `src/app/(dashboard)/barber/walk-ins/page.tsx` | Barber workspace | Reads frozen `duration_minutes` / `service_amount` from queue entry |
| 20 | `src/app/(dashboard)/dashboard/my-chair/page.tsx` | Owner workspace | Same as barber walk-ins |

## 5. Shared components (4 components)

| # | Component | Role |
|---|---|---|
| 21 | `src/components/dashboard/InServiceMode.tsx` | Uses stored duration — NOT live service |
| 22 | `src/components/dashboard/PostServiceFlow.tsx` | Uses stored `service_amount` |
| 23 | `src/components/queue/ServiceCard.tsx` | Walk-in check-in step 4 |
| 24 | `src/components/dashboard/PaymentCollectionModal.tsx` | Captures tip; reads stored service_amount |

## 6. Database tables (3 tables)

| # | Table | Role |
|---|---|---|
| 25 | `services` | Global walk-in services (owner-controlled); `name`, `description`, `price`, `duration_minutes`, `category`, `is_active` |
| 26 | `barber_services` | Junction (barber ↔ service) with optional `custom_price` override. **DEPRECATED 2026-04-22** — INSERT/UPDATE blocked by DB trigger |
| 27 | `barber_custom_services` | Barber-created custom services; own `name`, `description`, `price`, `duration_minutes`, `category` |

Tables that CARRY FK to services (must audit SET NULL behavior):
| 28 | `bookings` | `service_id` FK (SET NULL), `custom_service_id` FK (SET NULL), `duration_minutes` frozen, `service_amount` frozen |
| 29 | `queue_entries` | `service_id` FK (SET NULL), `duration_minutes` frozen, `service_amount` frozen |
| 30 | `service_transactions` | `service_id` FK (SET NULL), `service_name` copy stored |
| 31 | `upsell_rules` | `trigger_service_id`, `suggested_service_id` — both reference `services` |

## 7. DB triggers (2 triggers — both LOCKDOWN triggers)

| # | Trigger | Table | Timing | Purpose |
|---|---|---|---|---|
| 32 | `barber_services_block_insert` | `barber_services` | BEFORE INSERT | Rejects writes (migration 20260422 deprecation) |
| 33 | `barber_services_block_update` | `barber_services` | BEFORE UPDATE | Rejects writes |

(The `create_service_transaction_from_*` triggers reference service-related data but are audited by bulletproof-commission.)

## 8. RLS policies (expected per table)

| # | Table | Expected policies |
|---|---|---|
| 34 | `services` | Public SELECT (all — public services page); owner all (`is_owner()`); barber SELECT |
| 35 | `barber_services` | Public SELECT; owner all; barber SELECT own. WRITE blocked by trigger regardless |
| 36 | `barber_custom_services` | Public SELECT (for `is_active=true`); owner all; barber all-own |

## 9. Migrations (4 migrations)

| # | Migration | What it did |
|---|---|---|
| 37 | `001_initial_schema.sql` | Base `services`, `barber_services` |
| 38 | `20260306223406_create_barber_custom_services.sql` | `barber_custom_services` table (NOT in generated types — needs `(supabase as any)` cast) |
| 39 | `20260422000000_deprecate_barber_services_lockdown.sql` | Block-write triggers on `barber_services` |
| 40 | FK cascade fix commit `fb35208` (2026-04-21) | Bookings/queue/service_transactions FKs → SET NULL; `barber_services.service_id` stays CASCADE |

## 10. Propagation freeze points (audit these — not a table but an invariant)

| # | Point | Where |
|---|---|---|
| 41 | `bookings.duration_minutes` set at POST | `/api/bookings/route.ts` |
| 42 | `bookings.service_amount` set at POST | Same |
| 43 | `queue_entries.duration_minutes` set at check-in | `/api/queue/route.ts` |
| 44 | `queue_entries.service_amount` set at check-in | Same |
| 45 | `service_transactions.service_name` copy at INSERT | Trigger `create_service_transaction_from_*` |

Any script/route that retroactively mutates these is CRITICAL drift.

## 11. External consumers (downstream surfaces that read service data) — 7+

| # | Consumer | Reads |
|---|---|---|
| 46 | SMS templates `src/lib/twilio/*` | Stored booking/queue `service_name`, not live |
| 47 | Email templates `src/lib/email/templates.ts` | Stored booking `service_name` |
| 48 | Stripe checkout `src/app/api/payments/checkout/route.ts` | Stored `service_amount` |
| 49 | Stripe payment links `src/app/api/payments/send-link/route.ts` | Stored `service_amount` |
| 50 | `daily_summaries` aggregation | Aggregates stored service_amount — no FK |
| 51 | Upsell triggers in `/api/queue/complete/route.ts` | Live lookup of `upsell_rules` → services |
| 52 | `useCalendarEvents.ts` | Stored `duration_minutes` for calendar block size |

## 12. Environment variables / flags

| # | Var | Purpose |
|---|---|---|
| 53 | `NEXT_PUBLIC_SUPABASE_URL` / anon key | Client reads |
| 54 | `SUPABASE_SERVICE_ROLE_KEY` | Admin writes (owner UI) |

---

## Surface Totals

- **API routes:** 8 (5 services-owning + 3 services-adjacent)
- **Library files:** 2
- **UI pages:** 10
- **Shared components:** 4
- **Database tables:** 3 services-owned + 4 services-consumer = 7 total
- **DB triggers:** 2 (lockdown triggers)
- **RLS policies:** 3 tables
- **Migrations:** 4
- **Frozen-snapshot points:** 5
- **Downstream consumers:** 7+
- **Environment variables:** 2

**Grand total surfaces to audit:** 55+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
