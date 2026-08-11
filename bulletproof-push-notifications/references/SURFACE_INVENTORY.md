# Push Notifications Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the PWA push notification system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — push-owning (1 route)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/push/subscribe/route.ts` | POST (DELETE?) | Upsert client subscription by endpoint; body = `{endpoint, keys:{p256dh,auth}, user_id?, queue_token?}` |

## 2. API Routes — push-sending (push fired as side-effect) (11 routes)

Every route here calls into `QueuePush` / `BookingPush` / `BarberPush` / `sendPushNotification` / `notifyBarberOfNewBooking`. All must:
(a) use admin client if cron/webhook-authed,
(b) handle 410/404 → DELETE dead subscriptions,
(c) race-guard before sending (re-read source row status).

| # | Route | Push write |
|---|---|---|
| 2 | `src/app/api/queue/route.ts` | Queue join / waitlist state changes |
| 3 | `src/app/api/queue/entry/[id]/route.ts` | Call Next → `QueuePush.sendCalledNotification` + `BarberPush.sendQueueAssigned` |
| 4 | `src/app/api/queue/entry/[id]/status/route.ts` | Status transitions (in_chair / completed / no_show) |
| 5 | `src/app/api/bookings/route.ts` | Booking creation → barber push via `notifyBarberOfNewBooking` |
| 6 | `src/app/api/bookings/quick/route.ts` | Walk-in booking |
| 7 | `src/app/api/bookings/[id]/route.ts` | Booking updates/cancellations |
| 8 | `src/app/api/bookings/[id]/reschedule/route.ts` | Reschedule → barber push |
| 9 | `src/app/api/bookings/manage/[code]/route.ts` | Client self-manage — barber push |
| 10 | `src/app/api/bookings/reminders/route.ts` | 24h/1h reminders via `BookingPush.sendReminder` |
| 11 | `src/app/api/bookings/from-external/route.ts` | Booksy convert → barber notification |
| 12 | `src/app/api/cron/service-reminder/route.ts` | Overdue-service barber push (L1/L2/L3) + owner "stuck 60min" push |
| 13 | `src/app/api/communications/send-blast/route.ts` | Mass broadcast push (to all subscribers matching audience) |
| 14 | `src/app/api/feedback/route.ts` | Low-rating → owner push |
| 15 | `src/app/api/webhooks/resend/inbound/route.ts` | Booksy parsed → new appt push to barber |

## 3. Library / helpers (5 files)

| # | File | Role |
|---|---|---|
| 16 | `src/lib/push/server.ts` | `sendPushNotification()` + `QueuePush` + `BookingPush` + `BarberPush` + 410/404 handling |
| 17 | `src/lib/push/client.ts` | Browser service-worker register, `subscribeUserToPush()`, VAPID public key handling |
| 18 | `src/lib/push/index.ts` | Public exports |
| 19 | `src/lib/db/notifications.ts` | `notifyBarberOfNewBooking`, `sendBarberPush` — writes `barber_notifications` + fires push |
| 20 | `src/lib/queue/auto-assign.ts` | Called from queue flow; triggers push when auto-assign completes |

## 4. Service Worker (1 file)

| # | File | Role |
|---|---|---|
| 21 | `public/sw.js` | `push` + `notificationclick` handlers; routes `call`/`skip`/`complete`/`reschedule`/`view` actions; `self.registration.showNotification` display |

## 5. UI surfaces (6 components + 2 hosting pages)

| # | Component / Page | Purpose |
|---|---|---|
| 22 | `src/components/profile/PushOptIn.tsx` | Client-facing enable-push toggle (must gate on iOS PWA install) |
| 23 | `src/components/queue/NotificationPrompt.tsx` | Queue customer opt-in prompt |
| 24 | `src/components/queue/QueueTrackerContent.tsx` | Queue tracker page — registers `queue_token` subscription |
| 25 | `src/components/barber/NotificationBell.tsx` | Barber bell UI (reads `barber_notifications`) |
| 26 | `src/components/dashboard/Sidebar.tsx` | Owner bell integration |
| 27 | `src/components/dashboard/BarberSidebar.tsx` | Barber bell integration |
| 28 | `src/app/(dashboard)/barber/setup/page.tsx` | Onboarding — enables push as part of setup (cross-referenced by bulletproof-onboarding) |
| 29 | `src/app/(public)/queue/[...slug]/page.tsx` (tracker) | Host for `NotificationPrompt` |

## 6. Database tables (2 tables)

| # | Table | Role |
|---|---|---|
| 30 | `push_subscriptions` | Endpoint + p256dh + auth keys; either `user_id` (authenticated) or `queue_token` (anon tracker) |
| 31 | `barber_notifications` | In-app bell feed — written by same paths that fire push |

Not push-owned but referenced:
| 32 | `profiles` | `user_id` FK target |
| 33 | `clients` | `profile_id` bridge for booking-reminder eligibility |
| 34 | `queue_entries` | `tracking_token` ↔ `push_subscriptions.queue_token` |
| 35 | `barbers` | `profile_id` bridge for barber subscriptions |

## 7. RPC functions (0)

No RPC functions own push logic. All push delivery happens in Node runtime via `web-push`.

## 8. DB triggers (0 push-owned)

No triggers write to `push_subscriptions`. No triggers fire push directly (push is Node-layer only).

## 9. RLS policies (expected coverage)

Expected policies per table. Per SKILL.md invariant #9 — cron/webhook contexts MUST use admin client because RLS hides rows from anon.

| # | Table | Expected policies |
|---|---|---|
| 36 | `push_subscriptions` | `auth.uid() = user_id` for authenticated, `user_id IS NULL AND queue_token IS NOT NULL` for anon queue tracker, owner-all, service-role-write |
| 37 | `barber_notifications` | barber-select-own, service-role-write |

## 10. Migrations (0 — manual table)

`push_subscriptions` is NOT in `supabase/migrations/`. It was created manually in production. An audit MUST verify:

| # | Check | Why |
|---|---|---|
| 38 | Table exists with expected columns | Sanity check |
| 39 | Columns: `id, endpoint, p256dh, auth, user_id, queue_token, created_at, updated_at` | Drift would break senders |
| 40 | UNIQUE index on `endpoint` | Duplicate subscriptions cause duplicate pushes |
| 41 | RLS policies (see row 36) | Policy drift = silent anon reads returning 0 rows |

Related migration that DID ship:
| 42 | `030_barber_notifications.sql` | `barber_notifications` table + indexes |

## 11. External integrations (3 integrations)

| # | System | Touch points |
|---|---|---|
| 43 | `web-push` npm package | Signs + delivers push payloads using VAPID keys |
| 44 | FCM (Chrome/Android) | `https://fcm.googleapis.com/*` endpoints |
| 45 | APNs (Safari/iOS PWA) | `https://*.push.apple.com/*` endpoints; REQUIRES PWA installed on iOS 16.4+ |

## 12. Cron / background jobs (3 jobs that fire push)

| # | Route | Schedule | Purpose |
|---|---|---|---|
| 46 | `src/app/api/bookings/reminders/route.ts` | hourly | 24h + 1h booking reminders → customer push |
| 47 | `src/app/api/cron/service-reminder/route.ts` | every N min | Overdue-service barber push + owner "stuck 60min" |
| 48 | Any other cron that calls `sendPushNotification` | — | Per-route audit |

## 13. Environment variables

| # | Var | Purpose |
|---|---|---|
| 49 | `NEXT_PUBLIC_VAPID_PUBLIC_KEY` | Browser-side subscription keying |
| 50 | `VAPID_PRIVATE_KEY` | Server-side signing — **must never be `NEXT_PUBLIC_*`** |
| 51 | `VAPID_SUBJECT` | Optional mailto: for VAPID claim |
| 52 | `CRON_SECRET` | Gates push-firing cron routes |

---

## Surface Totals

- **API routes:** 1 owning + 14 sending = 15 total
- **Library files:** 5
- **Service worker:** 1
- **UI pages / components:** 8
- **Database tables:** 2 push-owned + 4 push-touched = 6 total
- **RPC functions:** 0
- **DB triggers:** 0
- **RLS policies:** 2+ (across 2 tables)
- **Migrations:** 0 push-owned (manual table) + 1 related (`030`)
- **External integrations:** 3
- **Cron jobs:** 3
- **Environment variables:** 4

**Grand total surfaces to audit:** ~52 discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
