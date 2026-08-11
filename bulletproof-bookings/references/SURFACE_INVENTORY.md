# Bookings Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the bookings system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — booking-owning (10 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/bookings/route.ts` | GET/POST | Create booking (public) + list (auth) |
| 2 | `src/app/api/bookings/availability/route.ts` | GET | Real-time open slots (Eastern TZ + overlap exclusion) |
| 3 | `src/app/api/bookings/[id]/route.ts` | GET/PATCH/DELETE | Single-booking read/update/soft-delete |
| 4 | `src/app/api/bookings/[id]/reschedule/route.ts` | POST | Move booking to new time |
| 5 | `src/app/api/bookings/quick/route.ts` | POST | Owner/barber manual quick-book (inside dashboard) |
| 6 | `src/app/api/bookings/quick-complete/route.ts` | POST | Quick-complete from calendar (commission pipeline fires) |
| 7 | `src/app/api/bookings/reminders/route.ts` | POST (cron) | 24h/1h SMS reminders — requires CRON_SECRET |
| 8 | `src/app/api/bookings/send-reminder/route.ts` | POST | Ad-hoc reminder trigger |
| 9 | `src/app/api/bookings/manage/[code]/route.ts` | GET/POST | Public self-service via confirmation_code (rate-limited) |
| 10 | `src/app/api/bookings/from-external/route.ts` | POST | Booksy/iCal import |

## 2. API Routes — booking-adjacent (4 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 11 | `src/app/api/barber/migrate-appointments/route.ts` | POST | Bulk Booksy migrations |
| 12 | `src/app/api/webhooks/resend/inbound/route.ts` | POST | Resend inbound → Booksy parser → booking create |
| 13 | `src/app/api/barber/sync-calendar/route.ts` | POST | Google Calendar ↔ bookings sync |
| 14 | `src/app/api/queue/entry/[id]/route.ts` | PATCH | Call-to-chair checks overlapping bookings (booking-conflicts) |

## 3. Library / helpers (4 files)

| # | File | Role |
|---|---|---|
| 15 | `src/lib/db/bookings.ts` | Core DB helpers (+ soft-delete filter) |
| 16 | `src/lib/queue/booking-conflicts.ts` | Overlap detection used by queue in-chair guard |
| 17 | `src/lib/booksy/parser.ts` | English + Spanish Booksy email parsing; Eastern TZ offset detection |
| 18 | `src/lib/google/calendar.ts` (or similar) | Google Calendar sync helpers |

## 4. React hooks (5 hooks)

| # | File | Subscribes / reads |
|---|---|---|
| 19 | `src/lib/hooks/useBookings.ts` | Bookings list (per barber / date range) |
| 20 | `src/lib/hooks/useCalendarEvents.ts` | Unified feed: bookings + queue + Booksy + Google; dedups; filters `confirmed` |
| 21 | `src/lib/hooks/useExternalAppointments.ts` | Booksy/Google externals |
| 22 | `src/lib/hooks/useClientHistory.ts` | Client's past bookings |
| 23 | `src/lib/hooks/useClients.ts` | Client CRM pulls booking history |

## 5. UI pages (10 pages)

| # | Page | Audience |
|---|---|---|
| 24 | `src/app/(public)/book/page.tsx` | 6-step booking wizard (public) |
| 25 | `src/app/(public)/book/confirmation/page.tsx` | Post-book confirmation |
| 26 | `src/app/(public)/book/manage/[code]/page.tsx` | Customer self-service (reschedule/cancel via code) |
| 27 | `src/app/(dashboard)/dashboard/bookings/page.tsx` | Owner all-bookings list |
| 28 | `src/app/(dashboard)/dashboard/calendar/page.tsx` | Owner calendar |
| 29 | `src/app/(dashboard)/dashboard/my-chair/calendar/page.tsx` | Owner-as-barber calendar |
| 30 | `src/app/(dashboard)/barber/calendar/page.tsx` | Barber calendar (mirror of owner my-chair) |
| 31 | `src/app/(dashboard)/barber/page.tsx` | Barber home — next 3 bookings |
| 32 | `src/app/(public)/profile/page.tsx` | Customer upcoming bookings (if logged in) |
| 33 | `src/app/(public)/mtbarbers/[slug]/page.tsx` | Public barber profile — inline booking widget |

## 6. Shared components (9 components)

| # | Component | Used by |
|---|---|---|
| 34 | `src/components/booking/BookingCalendar.tsx` | Wizard |
| 35 | `src/components/booking/DatePicker.tsx` | Wizard step 3 |
| 36 | `src/components/booking/TimeSlotPicker.tsx` | Wizard step 4 |
| 37 | `src/components/booking/ProfileBookingWidget.tsx` | Public profile inline widget |
| 38 | `src/components/dashboard/calendar/MyCalendarGrid.tsx` | Calendar grid UI |
| 39 | `src/components/dashboard/calendar/CalendarEventDetailModal.tsx` | Inline edit modal |
| 40 | `src/components/dashboard/calendar/RescheduleBookingModal.tsx` | Reschedule UI |
| 41 | `src/components/dashboard/calendar/ManualBookingSheet.tsx` | Quick-book from calendar |
| 42 | `src/components/dashboard/calendar/AddTimeBlockModal.tsx` | Block off time (barber_time_blocks) |

## 7. Database tables (3 tables directly + fee columns on bookings)

| # | Table | Role |
|---|---|---|
| 43 | `bookings` | Main table; status state machine; fee columns; soft-delete (`deleted_at`); `confirmation_code` UNIQUE partial index; `custom_service_id` FK |
| 44 | `external_calendar_events` | Booksy/Google events that appear on calendar |
| 45 | `booksy_sync_logs` | Parser audit trail |
| 46 | `barber_time_blocks` | Barber personal blocks (lunch/personal/unavailable) |

Parent tables that bookings reference:
| 47 | `barbers` | FK + availability source |
| 48 | `locations` | FK + hours_json |
| 49 | `services` / `barber_custom_services` | FK + duration source (frozen at creation) |

## 8. RPC functions (2 directly touched)

| # | Function | Purpose |
|---|---|---|
| 50 | `create_service_transaction_from_booking()` | AFTER UPDATE trigger on bookings → service_transactions insert + waiver propagation |
| 51 | `update_daily_summary(p_date, p_barber_id, p_location_id)` | Triggered when booking completes |

## 9. DB triggers (3 triggers directly)

| # | Trigger | Table | Timing |
|---|---|---|---|
| 52 | `create_service_transaction_from_booking` | `bookings` | AFTER UPDATE |
| 53 | `trg_bookings_daily_summary` | `bookings` | AFTER UPDATE (completion) |
| 54 | `update_external_calendar_events_updated_at` | `external_calendar_events` | BEFORE UPDATE |

## 10. DB constraints & indexes (4 must-exist)

| # | Object | Purpose |
|---|---|---|
| 55 | `bookings_no_time_overlap` (btree_gist exclusion) | Prevents overbooking for same barber in `confirmed`/`pending`/`in_progress` where `deleted_at IS NULL` |
| 56 | Unique partial index on `bookings(confirmation_code) WHERE confirmation_code IS NOT NULL` | Self-service lookup integrity |
| 57 | `bookings.deleted_at` index | Soft-delete filter efficiency |
| 58 | `in_progress` status in `status` enum (migration 025) | Calendar display + availability blocking |

## 11. RLS policies (expected per table)

| # | Table | Expected policies |
|---|---|---|
| 59 | `bookings` | Public INSERT (wizard); owner all; barber select own (by barber_id); customer select own (auth or by confirmation_code); soft-delete filter encoded in policies or queries |
| 60 | `external_calendar_events` | Public SELECT (profile/team show schedule) per migration `20260228000000`; owner all; barber own |
| 61 | `booksy_sync_logs` | Owner select; barber select own |
| 62 | `barber_time_blocks` | Barber all-own; owner read-all |

## 12. Migrations (9 migrations)

| # | Migration | What it did |
|---|---|---|
| 63 | `001_initial_schema.sql` | Base `bookings` schema |
| 64 | `025_add_in_progress_status_to_bookings.sql` | Added `in_progress` to status enum |
| 65 | `038_add_soft_delete.sql` | `deleted_at` column |
| 66 | `042_booksy_sync.sql` | `external_calendar_events` + `booksy_sync_logs` tables |
| 67 | `043_public_bookings_insert.sql` | Public INSERT RLS for wizard |
| 68 | `040_barber_time_blocks.sql` | `barber_time_blocks` |
| 69 | `20260326000000_unique_confirmation_code.sql` | Unique partial index |
| 70 | `20260401000000_booking_overbooking_constraint.sql` | `bookings_no_time_overlap` btree_gist exclusion |
| 71 | `20260228000000_external_events_public_read.sql` | Public read of external events |

## 13. Realtime publications (required)

| # | Table | Required? |
|---|---|---|
| 72 | `bookings` | YES — calendar + dashboard live updates |
| 73 | `external_calendar_events` | Recommended — calendar refresh on new Booksy import |

## 14. Cron / background jobs (3 jobs)

| # | Route | Schedule | Purpose |
|---|---|---|---|
| 74 | `src/app/api/bookings/reminders/route.ts` | 24h + 1h windows | Reminder SMS (CRON_SECRET-gated) |
| 75 | `src/app/api/cron/google-calendar-sync/route.ts` | Frequent | Google Calendar → bookings sync |
| 76 | `src/app/api/cron/feedback/route.ts` | Post-visit | Post-booking feedback SMS |

## 15. External integrations (3 integrations)

| # | Integration | Touch points |
|---|---|---|
| 77 | Twilio (via Antigravity) | Confirmation SMS, 24h/1h reminders, feedback |
| 78 | Resend (email) | Confirmation email with location address (Edwardsville must use `locationState`) |
| 79 | Booksy (via Resend inbound + parser) | `external_calendar_events` + `booksy_sync_logs`; EDT/EST offset parsing |
| 80 | Google Calendar | OAuth + calendar.events API; two-way sync |

## 16. Email / SMS templates

| # | File | Purpose |
|---|---|---|
| 81 | `src/lib/email/templates.ts` | Booking confirm / reschedule / cancel / reminder emails — must use `locationState` |
| 82 | `src/lib/twilio/templates.ts` (or wherever) | SMS reminder + confirm templates |

## 17. Environment variables

| # | Var | Purpose |
|---|---|---|
| 83 | `CRON_SECRET` | Reminder cron auth |
| 84 | `RESEND_API_KEY` | Transactional email |
| 85 | `RESEND_FROM_EMAIL` | Sender address |
| 86 | `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | Google Calendar sync |
| 87 | `TWILIO_*` | Via Antigravity |
| 88 | `NEXT_PUBLIC_APP_URL` | Manage link in emails |

---

## Surface Totals

- **API routes:** 14 (10 booking-owning + 4 adjacent)
- **Library files:** 4
- **Hooks:** 5
- **UI pages:** 10
- **Shared components:** 9
- **Database tables:** 4 directly + 3 parent-referenced
- **RPC functions:** 2
- **DB triggers:** 3
- **DB constraints/indexes:** 4
- **RLS policies:** 4 tables
- **Migrations:** 9
- **Realtime tables:** 2
- **Cron jobs:** 3
- **External integrations:** 4
- **Email/SMS template files:** 2
- **Environment variables:** 6

**Grand total surfaces to audit:** 80+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
