# Onboarding Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the barber-onboarding funnel touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. Wizard page + guard (1 file)

| # | File | Role |
|---|---|---|
| 1 | `src/app/(dashboard)/barber/setup/page.tsx` | 7-step wizard UI; init guard (lines 99-164); `saveStep()` PATCH of `/api/barber/onboarding-step` on every transition; 5-second fetch timeout |

## 2. API Routes — invite + onboarding (6 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 2 | `src/app/api/auth/create-barber/route.ts` | POST | Owner invite: creates `auth.users` + `profiles` + `barbers` + default `barber_schedules` (Mon-Sat 9-6, line 232 — drift vs wizard Mon-Fri 9-7) + `staff_status`; sends email + SMS; cascade rollback on failure |
| 3 | `src/app/api/auth/resend-invite/route.ts` | POST | Regenerate magic link + resend email/SMS |
| 4 | `src/app/api/auth/set-password/route.ts` | POST | Wizard Step 1 — first-login password set |
| 5 | `src/app/api/auth/pending-barbers/route.ts` | GET | Owner: list barbers where `first_login_completed=false` |
| 6 | `src/app/api/barber/onboarding-step/route.ts` | PATCH/GET | Persist `barbers.onboarding_step` on each transition |
| 7 | `src/app/api/barber/setup-status/route.ts` | GET | Aggregate: services count, schedule exists, photo set (post-Phase-1: push + install dismissal) — feeds `SetupStatusBanner` |
| 8 | `src/app/api/barber/acknowledge-commission/route.ts` | POST | Wizard Step 7 — sets `commission_acknowledged_at = NOW()`, `grace_period_ends_at = NOW() + 30 days`, `onboarding_step = NULL`, `profiles.first_login_completed = true`. Idempotent for legacy backfill |

## 3. API Routes — step-specific (6 routes)

Each wizard step posts to its own route. Any of these breaking = a step can't complete.

| # | Step | Route | Persists |
|---|---|---|---|
| 9 | Step 2 (Profile) | Direct Supabase upload to `avatars` bucket + UPDATE `profiles.avatar_url` / `barbers.image_url`, `barbers.bio` | photo + bio |
| 10 | Step 3 (Services) | `src/app/api/barber/custom-services/route.ts` POST | `barber_custom_services` rows |
| 11 | Step 4 (Schedule) | `src/app/api/barber/schedule/route.ts` PUT | `barber_schedules` rows |
| 12 | Step 5 (Booksy) | `src/app/api/barber/booksy/settings/route.ts` PATCH | `barbers.booksy_sync_email`, `barbers.booksy_sync_enabled` |
| 13 | Step 6 (Stripe Connect) | `src/app/api/barber/stripe/connect/route.ts` POST → OAuth redirect; `src/app/api/barber/stripe/callback/route.ts` GET | `barbers.stripe_account_id`, later `stripe_charges_enabled` via status poll |
| 14 | Step 6 (status poll) | `src/app/api/barber/stripe/status/route.ts` GET | Reads Connect account — confirms `charges_enabled` |

## 4. Components (3 files)

| # | File | Role |
|---|---|---|
| 15 | `src/components/barber/SetupStatusBanner.tsx` | Banner rendered on `/barber` + (mirror) `/dashboard/my-chair` — consumes `/api/barber/setup-status` |
| 16 | `src/components/ui/PwaInstallPrompt.tsx` | Install prompt; currently mounted on public pages (`/queue/live`, `/profile`, `/mtclientlogin`, `/book/confirmation`) — NOT on `/barber/**` as of 2026-04-20 |
| 17 | `src/components/queue/NotificationPrompt.tsx` | Push enrollment prompt; currently mounted on public queue pages — NOT on `/barber/**` |

## 5. UI surfaces — barber + mirror pages (5 pages)

| # | Page | Role |
|---|---|---|
| 18 | `src/app/(dashboard)/barber/page.tsx` | Barber home — consumes SetupStatusBanner, commission balance, pending-setup nudges |
| 19 | `src/app/(dashboard)/barber/help/page.tsx` | Barber FAQ — must (post-Phase-3) include "Install the App" + "Push Notifications" sections |
| 20 | `src/app/(dashboard)/dashboard/my-chair/page.tsx` | Owner-as-barber mirror of `/barber` — same banner + prompts |
| 21 | `src/app/(dashboard)/dashboard/barbers/page.tsx` | Owner staff management — list/invite/resend/deactivate; shows onboarding state per barber |
| 22 | `src/app/(public)/team/page.tsx` | Public team — filters `is_active = true` + implicit `first_login_completed=true` + `onboarding_step IS NULL` |

`/barber/install` page (Phase 2 target) does NOT exist yet — absence is itself an audit finding.

## 6. Email + SMS templates (2 files)

| # | File | Role |
|---|---|---|
| 23 | `src/lib/email/templates.ts` → `barberInviteEmail()` (~lines 294-359) | Onboarding invite email; currently advertises "4 setup steps" — drift vs 7-step wizard |
| 24 | `src/lib/twilio/sms.ts` → `BarberSMS.sendInviteNotification` | SMS sent alongside invite email; called from create-barber ~line 315 |

## 7. Supporting libraries (3 files)

| # | File | Role |
|---|---|---|
| 25 | `src/lib/supabase/admin.ts` | Service-role client — used by create-barber/resend-invite/set-password (RLS-bypassed inserts) |
| 26 | `src/lib/email/client.ts` | `sendEmail()` — Resend wrapper used by create-barber, resend-invite |
| 27 | `src/lib/auth/logger.ts` | `logAuthEvent()` — writes onboarding-relevant events (login_success, password_changed, email_verified) |

## 8. Database tables (4 tables)

Onboarding-owned columns (no new tables; onboarding state lives on `barbers` + `profiles`):

| # | Table | Onboarding columns |
|---|---|---|
| 28 | `barbers` | `onboarding_step` (int, nullable), `onboarding_step_updated_at`, `commission_acknowledged_at`, `grace_period_ends_at`, `image_url`, `stripe_account_id`, `stripe_charges_enabled`, `employment_type`, `preferred_location_id`, `booksy_sync_email`, `booksy_sync_enabled`, `slug`, `bio` |
| 29 | `profiles` | `first_login_completed`, `email_verified`, `avatar_url`, `role`, `last_login_at`, `pwa_install_dismissed_at` (post-migration `20260420*` — verify exists) |
| 30 | `barber_schedules` | Default Mon-Sat 9-6 rows inserted by create-barber (line 232); wizard Step 4 overwrites with Mon-Fri 9-7 if user clicks "Save & Continue" without editing (silent Saturday loss) |
| 31 | `staff_status` | One row per (barber, location) — inserted by create-barber |
| 32 | `barber_custom_services` | Step 3 inserts — the only required data row for completion |
| 33 | `push_subscriptions` | Onboarding reads count (≥1 = push-enabled) — writes happen in `bulletproof-push-notifications` domain |
| 34 | `auth.users` | Supabase-managed; onboarding reads `last_sign_in_at`, `confirmation_sent_at` to diagnose invite issues |

## 9. RPC functions / DB triggers (0 onboarding-specific)

No triggers on the onboarding tables. Everything happens through application code. **If an audit finds a trigger on `barbers.onboarding_step`, flag as surface drift.**

## 10. RLS policies (expected)

| # | Table | Expected policies touched by onboarding |
|---|---|---|
| 35 | `barbers` | Owner full access; barber self-read/update own row; public select of limited columns (for team page) |
| 36 | `profiles` | Self read/update; owner full; PII restriction (migration 037) |
| 37 | `barber_schedules` | Barber self-write own; owner full (migration `20260409023540_harden_barber_schedules_rls_and_audit.sql`) |
| 38 | `barber_custom_services` | Barber self-CRUD own; public select for profile pages |
| 39 | `staff_status` | Barber self-read/update own; owner full |
| 40 | `push_subscriptions` | Self-CRUD own; owner read-all |

## 11. Migrations (4)

| # | Migration | What it did |
|---|---|---|
| 41 | `021_auth_security.sql` | Added `profiles.first_login_completed`, `profiles.last_login_at`, `profiles.email_verified` — the core onboarding-state flags |
| 42 | `20260306224431_add_onboarding_step_to_barbers.sql` | Added `barbers.onboarding_step` (INT, nullable) + `barbers.onboarding_step_updated_at` |
| 43 | `20260306223406_create_barber_custom_services.sql` | Created `barber_custom_services` — the table Step 3 writes to |
| 44 | `20260320000000_payment_schema_catchup.sql` | Added `barbers.commission_acknowledged_at`, `barbers.grace_period_ends_at`, `barbers.employment_type`, and `barber_payouts` table; Step 7 depends on these columns existing |
| 45 | `20260420*_add_pwa_install_dismissed_to_profiles.sql` | **Not yet in repo as of 2026-04-24 — Phase 1 of onboarding-gap-1-pwa-install-schema.** Must exist before `pwa_install_dismissed_at` is referenced by code |

## 12. External integrations (3)

| # | System | Touch points |
|---|---|---|
| 46 | Supabase Auth (GoTrue) | Magic-link invite (1-hour default TTL), password set, JWT metadata.role sync |
| 47 | Resend | Onboarding invite email via `barberInviteEmail()` |
| 48 | Twilio | Onboarding invite SMS via `BarberSMS.sendInviteNotification` (called from create-barber) |
| 49 | Stripe Connect | OAuth redirect (Step 6) — sets `stripe_account_id`; bank verification webhook sets `stripe_charges_enabled` |
| 50 | web-push / VAPID | Push subscription (`/api/push/subscribe`); `push_subscriptions` row = onboarding-optional-gap artifact |

## 13. Environment variables (7)

| # | Var | Purpose |
|---|---|---|
| 51 | `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Wizard client reads |
| 52 | `SUPABASE_SERVICE_ROLE_KEY` | create-barber, resend-invite, acknowledge-commission |
| 53 | `RESEND_API_KEY` + `RESEND_FROM_EMAIL` | Invite email delivery |
| 54 | `TWILIO_ACCOUNT_SID` + `TWILIO_AUTH_TOKEN` + `TWILIO_PHONE_NUMBER` | Invite SMS delivery |
| 55 | `STRIPE_SECRET_KEY` + OAuth client ID/secret | Connect redirect |
| 56 | `NEXT_PUBLIC_VAPID_PUBLIC_KEY` + `VAPID_PRIVATE_KEY` | Push enrollment |
| 57 | `NEXT_PUBLIC_APP_URL` | Magic-link redirect URL + Stripe OAuth redirect |

## 14. Cron / background jobs (1)

| # | Route | Schedule | Purpose |
|---|---|---|---|
| 58 | `src/app/api/cron/grace-period-notifications/route.ts` | Daily | Nudges barbers whose `grace_period_ends_at` is within N days — the follow-through on Step 7 |

---

## Surface Totals

- **Wizard page:** 1
- **API routes:** 12 (invite+onboarding: 6 + step-specific: 6)
- **Components:** 3
- **UI pages:** 5 (barber + mirror)
- **Templates:** 2 (email + SMS)
- **Supporting libs:** 3
- **Database tables:** 7 (4 onboarding-owned + 3 read)
- **RLS policies:** 6+ (across 6 tables)
- **Migrations:** 5
- **Integrations:** 5
- **Env vars:** 7
- **Cron jobs:** 1

**Grand total surfaces to audit:** 58+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
