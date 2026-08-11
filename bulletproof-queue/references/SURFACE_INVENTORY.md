# Queue Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the walk-in queue system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — queue-owning (14 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/queue/route.ts` | GET/POST | Public check-in + owner list |
| 2 | `src/app/api/queue/[token]/route.ts` | GET | Customer tracker (by tracking_token) |
| 3 | `src/app/api/queue/capacity/route.ts` | GET | Per-location capacity + waitlist overflow decision |
| 4 | `src/app/api/queue/history/route.ts` | GET | Historical queue entries for reports |
| 5 | `src/app/api/queue/rotation-preview/route.ts` | GET | Shows which barber would win next assignment (fair rotation preview) |
| 6 | `src/app/api/queue/skip-turn/route.ts` | POST | Barber passes on their assigned client |
| 7 | `src/app/api/queue/override-assign/route.ts` | POST | Owner manually assigns queue entry to specific barber |
| 8 | `src/app/api/queue/complete/route.ts` | POST | Alternate completion path (calls `complete_queue_service` RPC) |
| 9 | `src/app/api/queue/entry/[id]/route.ts` | PATCH/DELETE | Main state machine transitions + in-chair guard (lines ~217-252) |
| 10 | `src/app/api/queue/entry/[id]/status/route.ts` | PATCH | Status-only transitions |
| 11 | `src/app/api/queue/entry/[id]/service/route.ts` | PATCH | Change service on an active entry |
| 12 | `src/app/api/queue/entry/[id]/delay/route.ts` | PATCH | Customer notified-position delay |
| 13 | `src/app/api/queue/entry/[id]/void/route.ts` | POST | Void a completed entry — reverses fee/ledger |
| 14 | `src/app/api/queue/entry/[id]/reassign-completed/route.ts` | POST | Owner reassigns a completed cut to a different barber |

## 2. API Routes — queue-adjacent (6 routes that read/write queue state)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 15 | `src/app/api/barber/clock/route.ts` | POST | Clock in/out → staff_status changes; gates auto-assign eligibility |
| 16 | `src/app/api/barber/break/route.ts` | POST | On-break transition via `transition_staff_status` RPC |
| 17 | `src/app/api/barber/[id]/force-status/route.ts` | POST | Owner forces a barber's `staff_status` (override) |
| 18 | `src/app/api/barber/[id]/queue-control/route.ts` | PATCH | Set barber's `queue_control_mode` (auto/manual/paused) |
| 19 | `src/app/api/locations/[id]/pause/route.ts` | POST | Pause/resume walk-in accepting for a location |
| 20 | `src/app/api/push/subscribe/route.ts` | POST | PWA push registration; queue assignments trigger push |

## 3. Library / helpers (5 files)

| # | File | Role |
|---|---|---|
| 21 | `src/lib/queue/auto-assign.ts` | Fair rotation logic — picks winner from eligible barbers |
| 22 | `src/lib/queue/booking-conflicts.ts` | Checks overlapping bookings before call-to-chair |
| 23 | `src/lib/queue/capacity.ts` | Max queue size per location; waitlist overflow decision |
| 24 | `src/lib/queue/position-notifier.ts` | SMS notifications for position changes |
| 25 | `src/lib/db/queue.ts` | Generic queue DB helpers |

## 4. React hooks (7 hooks)

| # | File | Subscribes / reads |
|---|---|---|
| 26 | `src/lib/hooks/useQueue.ts` | Queue entries for a location (consumer-facing) |
| 27 | `src/lib/hooks/useQueueRealtime.ts` | Realtime subscription on `queue_entries` |
| 28 | `src/lib/hooks/useQueueBadge.ts` | Barber header badge count |
| 29 | `src/lib/hooks/useQueueAnalytics.ts` | Aggregate stats for owner analytics |
| 30 | `src/lib/hooks/useBarberClock.ts` | Clock in/out + break state machine |
| 31 | `src/lib/hooks/useNoShowTimer.ts` | 3-min no-show countdown |
| 32 | `src/lib/hooks/useBarberRotationPosition.ts` | Barber's current rotation rank |

## 5. UI pages (8 pages)

| # | Page | Audience |
|---|---|---|
| 33 | `src/app/(public)/queue/page.tsx` | Walk-in check-in wizard (public) |
| 34 | `src/app/(public)/queue/[token]/page.tsx` | Customer live tracker |
| 35 | `src/app/(public)/queue/[...slug]/page.tsx` | Catch-all for location slugs |
| 36 | `src/app/(public)/queue/live/page.tsx` | Public live queue board |
| 37 | `src/app/(public)/tv/[location]/page.tsx` | In-shop TV display |
| 38 | `src/app/(dashboard)/dashboard/queue/page.tsx` | Owner all-locations queue control |
| 39 | `src/app/(dashboard)/dashboard/my-chair/page.tsx` | Owner-as-barber workspace |
| 40 | `src/app/(dashboard)/barber/walk-ins/page.tsx` | Barber queue + In-Service Mode |

Static per-location queue pages (see locations surface inventory too):
| 41 | `src/app/(public)/queue/wilmington/page.tsx` |
| 42 | `src/app/(public)/queue/newark/page.tsx` |
| 43 | `src/app/(public)/queue/new-castle/page.tsx` |
| 44 | `src/app/(public)/queue/edwardsville/page.tsx` |

## 6. Shared components (6 components)

| # | Component | Used by |
|---|---|---|
| 45 | `src/components/queue/BarberCard.tsx` | Check-in wizard step 2 |
| 46 | `src/components/queue/BarberCarousel.tsx` | Check-in wizard |
| 47 | `src/components/queue/ServiceCard.tsx` | Check-in wizard step 4 |
| 48 | `src/components/queue/LocationCard.tsx` | Check-in wizard step 1 |
| 49 | `src/components/queue/NoShowTimer.tsx` | Barber walk-ins page |
| 50 | `src/components/queue/QueueTrackerContent.tsx` | Customer tracker page |
| 51 | `src/components/queue/VirtualCheckInToggle.tsx` | Check-in wizard |
| 52 | `src/components/queue/ArrivalButton.tsx` | Virtual queue arrival |
| 53 | `src/components/queue/LocationQueuePage.tsx` | Catch-all + static per-location pages |
| 54 | `src/components/queue/NotificationPrompt.tsx` | Push prompt during check-in |
| 55 | `src/components/dashboard/barber/WalkInAlertModal.tsx` | Realtime queue-assigned modal |
| 56 | `src/components/dashboard/WalkInForm.tsx` | Owner/barber manual check-in entry |
| 57 | `src/components/dashboard/InServiceMode.tsx` | Full-screen service takeover (shared) |
| 58 | `src/components/dashboard/PaymentCollectionModal.tsx` | Post-completion payment + tip capture |

## 7. Database tables (5 tables)

| # | Table | Role |
|---|---|---|
| 59 | `queue_entries` | Every check-in; state machine (waiting|called|in_chair|completed|no_show|cancelled); payment + fee columns; tracking_token |
| 60 | `staff_status` | Per-barber current state (clocked_in|on_break|clocked_out|with_client); cuts_today counter |
| 61 | `barber_notifications` | In-app queue-assigned + realtime notifications |
| 62 | `waitlist` | Overflow when `max_queue_size` exceeded |
| 63 | `locations` | `accepts_walk_ins`, `hours_json.max_queue_size` |

## 8. RPC functions (5 functions)

| # | Function | Migration | Purpose |
|---|---|---|---|
| 64 | `assign_queue_position(p_location_id)` | 035 | Atomic position assignment with row locking |
| 65 | `complete_queue_service(p_entry_id, ...)` | 035 + 20260331 | Atomic completion: status + staff_status + cuts_today + client upsert |
| 66 | `upsert_client_from_service(...)` | 035 + 20260331 | Create/update client on completion |
| 67 | `transition_staff_status(p_barber_id, p_expected_status, p_new_status, ...)` | 035 + 20260331 | Atomic status change (clock in/out/break) |
| 68 | `increment_barber_cuts(p_barber_id)` | 20260310 + 20260331 | Fair rotation cuts_today increment |
| 69 | `decrement_barber_cuts(p_barber_id)` | 047 | Reverses cuts_today on void |

## 9. DB triggers (2 triggers directly on queue tables)

| # | Trigger | Table | Timing | Purpose |
|---|---|---|---|---|
| 70 | `create_service_transaction_from_queue` (AFTER UPDATE) | `queue_entries` | completion → insert `service_transactions` + propagate waiver |
| 71 | `trg_queue_entries_daily_summary` | `queue_entries` | After completion — upsert `daily_summaries` |
| 72 | `tr_referral_conversion` | `service_transactions` | AFTER INSERT/UPDATE — referral credit on completed walk-in |

## 10. RLS policies (expected per table)

| # | Table | Expected policies |
|---|---|---|
| 73 | `queue_entries` | Public insert (check-in); owner all; barber select own-location rows; customer select own (by tracking_token) |
| 74 | `staff_status` | Public select (TV board needs it — migration 040_public_staff_status + 041_public_staff_status_grant); owner all; barber update own |
| 75 | `barber_notifications` | Owner all; barber select own (by barber_id) |
| 76 | `waitlist` | Owner all; public insert (overflow during check-in) |

## 11. Migrations (11 migrations)

| # | Migration | What it did |
|---|---|---|
| 77 | `001_initial_schema.sql` | Initial `queue_entries`, `staff_status` |
| 78 | `005_link_queue_to_profile.sql` | `queue_entries.profile_id` FK |
| 79 | `016_virtual_queue.sql` | `is_virtual`, `estimated_arrival_time`, `notification_position` |
| 80 | `017_add_queue_client_email.sql` | `client_email` |
| 81 | `022_queue_pause_column.sql` | `locations.accepts_walk_ins` |
| 82 | `027_add_performance_indexes.sql` | Indexes on queue tables |
| 83 | `030_barber_notifications.sql` | `barber_notifications` table |
| 84 | `035_queue_concurrency_fixes.sql` | 4 atomic RPCs (assign_queue_position, complete_queue_service, upsert_client_from_service, transition_staff_status) |
| 85 | `040_public_staff_status.sql` | Public RLS for TV board |
| 86 | `041_public_staff_status_grant.sql` | Grant follow-up |
| 87 | `047_void_service.sql` | `decrement_barber_cuts` RPC + void flow |
| 88 | `20260310000000_increment_barber_cuts_rpc.sql` | `increment_barber_cuts` RPC |
| 89 | `20260331000000_security_hardening.sql` | SECURITY DEFINER hardening on all RPCs |
| 90 | `20260417000000_barber_queue_control_mode.sql` | `barbers.queue_control_mode` column |
| 91 | `20260421010000_barbers_realtime_publication.sql` | Realtime publication on barbers (used for queue eligibility updates) |

## 12. Realtime publications (required)

| # | Table | Required? |
|---|---|---|
| 92 | `queue_entries` | YES — all consumer hooks subscribe |
| 93 | `staff_status` | YES — clock-in/out visibility |
| 94 | `barber_notifications` | YES — queue-assigned modal |
| 95 | `waitlist` | Recommended — overflow visibility |

## 13. Cron / background jobs (4 jobs)

| # | Route | Schedule | Purpose |
|---|---|---|---|
| 96 | `src/app/api/cron/queue-cleanup/route.ts` | Daily | Prunes stale `waiting` entries |
| 97 | `src/app/api/cron/queue-eta/route.ts` | Frequent | Recomputes ETA + sends SMS |
| 98 | `src/app/api/cron/service-reminder/route.ts` | Frequent | Reminds customers approaching their turn |
| 99 | `src/app/api/cron/auto-clockout/route.ts` | Nightly | Auto-clocks out barbers still `clocked_in` |

## 14. External integrations (3 integrations)

| # | Integration | Touch points |
|---|---|---|
| 100 | Twilio (via Antigravity) | Queue SMS: join, your-next, ETA, reminder, feedback |
| 101 | Web Push (VAPID) | `push_subscriptions` table, `/api/push/subscribe`, service worker `/public/sw.js` |
| 102 | Stripe (commission side) | Cash/card/link completion triggers `service_transactions` row; audited by bulletproof-commission |

## 15. Environment variables

| # | Var | Purpose |
|---|---|---|
| 103 | `CRON_SECRET` | All queue crons |
| 104 | `NEXT_PUBLIC_VAPID_PUBLIC_KEY` | Push subscription client |
| 105 | `VAPID_PRIVATE_KEY` | Push send server-side |

---

## Surface Totals

- **API routes:** 20 (14 queue-owning + 6 queue-adjacent)
- **Library files:** 5
- **Hooks:** 7
- **UI pages:** 12 (8 dashboards/public + 4 static location check-in)
- **Shared components:** 14
- **Database tables:** 5
- **RPC functions:** 6
- **DB triggers:** 3
- **RLS policies:** 4 tables' worth
- **Migrations:** 15
- **Realtime tables:** 4
- **Cron jobs:** 4
- **External integrations:** 3
- **Environment variables:** 3

**Grand total surfaces to audit:** 100+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
