# Auth & Security Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the auth/session/lockout system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. Middleware (1 file)

| # | File | Role |
|---|---|---|
| 1 | `src/middleware.ts` | ALL request interception — role routing, 3-tier role resolve, client-session vs Supabase-session split, onboarding gate redirect, layout-data cookie cache, staff-login redirect-when-signed-in |

## 2. API Routes — Supabase-auth (staff) (13 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 2 | `src/app/api/auth/login/route.ts` | POST | Staff login; calls `checkLockout()` BEFORE password, `invalidateOldSessions()` AFTER success, `resetLockout()` on success, `logAuthEvent()` on both paths |
| 3 | `src/app/api/auth/check-lockout/route.ts` | POST | Pre-flight lockout check from login form |
| 4 | `src/app/api/auth/lockouts/route.ts` | GET/POST | Owner: list lockouts, manually unlock |
| 5 | `src/app/api/auth/set-password/route.ts` | POST | First-login password set (onboarding Step 1) |
| 6 | `src/app/api/auth/change-password/route.ts` | POST | Authenticated password change |
| 7 | `src/app/api/auth/admin-reset-password/route.ts` | POST | Owner: reset a barber's password |
| 8 | `src/app/api/auth/profile/route.ts` | GET/PUT | Read/update own `profiles` row |
| 9 | `src/app/api/auth/events/route.ts` | GET | Auth event history (owner-scope or self-scope) |
| 10 | `src/app/api/auth/sessions/route.ts` | GET | List all `active_sessions` for current user or (owner) all |
| 11 | `src/app/api/auth/session/check/route.ts` | GET | Is current `session_token` still valid? (for concurrent-login modal) |
| 12 | `src/app/api/auth/session/keepalive/route.ts` | POST | Bump `last_active` on current session |
| 13 | `src/app/api/auth/force-logout/route.ts` | POST | Kick another session off (one device) |
| 14 | `src/app/api/auth/force-logout-all/route.ts` | POST | Kick all sessions for a user (owner only) |
| 15 | `src/app/api/auth/logout-device/route.ts` | POST | Self-logout one device |

## 3. API Routes — client-session (HMAC) (3 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 16 | `src/app/api/auth/client-login/route.ts` | POST | Phone+code → mint HMAC token, set `mt-client-session` cookie |
| 17 | `src/app/api/auth/client-signup/route.ts` | POST | Create client profile (no Supabase auth user) |
| 18 | `src/app/api/auth/client-session/route.ts` | GET/DELETE | Verify or revoke HMAC token |

## 4. API Routes — barber invite (2 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 19 | `src/app/api/auth/create-barber/route.ts` | POST | Owner: creates `auth.users` + `profiles` + `barbers` + `barber_schedules` + `staff_status`, sends invite email + SMS. Cascade rollback on any failure |
| 20 | `src/app/api/auth/resend-invite/route.ts` | POST | Regenerate Supabase magic link + resend email/SMS |
| 21 | `src/app/api/auth/pending-barbers/route.ts` | GET | Owner: list barbers whose `first_login_completed = false` |

## 5. Library / helpers (6 files)

| # | File | Role |
|---|---|---|
| 22 | `src/lib/auth/context.tsx` | Client React context — `useAuth`, `isOwner`, `isBarber`, `isClient`; `useRef` for `initializedRef`/`fetchingUserRef` |
| 23 | `src/lib/auth/lockout.ts` | `checkLockout`, `recordFailedAttempt`, `resetLockout`, `lockAccount` (uses admin client — service-role writes) |
| 24 | `src/lib/auth/session-tracker.ts` | `createSession`, `invalidateOldSessions`, `updateLastActive`, `cleanupExpiredSessions` (admin client) |
| 25 | `src/lib/auth/logger.ts` | `logAuthEvent(event_type, profile_id, email, req)` — INSERT into `auth_events` |
| 26 | `src/lib/auth/device-detection.ts` | Parse UA → device_type, browser |
| 27 | `src/lib/auth/client-session.ts` | HMAC-SHA256 sign/verify of `mt-client-session` cookie (7-day expiry) |
| 28 | `src/lib/auth/index.ts` | Public re-exports |

## 6. Supabase client factories (4 files)

| # | File | Role |
|---|---|---|
| 29 | `src/lib/supabase/server.ts` | Server RSC/route client — anon key + cookies + `cache: 'no-store'` fetch wrapper |
| 30 | `src/lib/supabase/admin.ts` | Service-role client — `SUPABASE_SERVICE_ROLE_KEY` + `cache: 'no-store'`. NEVER for `getUser()` (2026-03-06 incident) |
| 31 | `src/lib/supabase/middleware.ts` | Edge middleware helper (if used by `src/middleware.ts`) |
| 32 | `src/lib/supabase/client.ts` | Browser singleton — anon key, used by `'use client'` components |

## 7. UI surfaces — public/auth (5 pages)

| # | Page | Purpose |
|---|---|---|
| 33 | `src/app/(auth)/mtbarberlogin/page.tsx` | Canonical staff login |
| 34 | `src/app/(auth)/login/page.tsx` | Alias — redirects to mtbarberlogin |
| 35 | `src/app/(auth)/staff/page.tsx` | Alias — redirects to mtbarberlogin |
| 36 | `src/app/(auth)/mtclientlogin/page.tsx` | Client login (HMAC session) |
| 37 | `src/app/(auth)/forgot-password/page.tsx` | Password-reset request |
| 38 | `src/app/auth/reset-password/page.tsx` | Password-reset completion (outside `(auth)` group) |

## 8. UI surfaces — dashboard (2 pages)

| # | Page | Purpose |
|---|---|---|
| 39 | `src/app/(dashboard)/dashboard/auth-log/page.tsx` | Owner: auth events + active sessions viewer |
| 40 | `src/app/(dashboard)/dashboard/settings/page.tsx` | Profile + security settings (password, session list) |

## 9. Components (2 files)

| # | File | Role |
|---|---|---|
| 41 | `src/components/auth/ConcurrentLoginModal.tsx` | Polls `/api/auth/session/check`; shows "kicked off another device" modal |
| 42 | `src/components/auth/SessionExpiredModal.tsx` | Displays when session refresh fails |

## 10. Database tables (3 tables + 2 touched)

Auth-owned:
| # | Table | Role |
|---|---|---|
| 43 | `auth_events` | Audit log — login_success, login_failed, password_reset_requested, password_changed, email_verified, lockout, unlock, force_logout, session_expired |
| 44 | `auth_lockouts` | Per-profile failed attempts + locked_until. `updated_at` auto-trigger |
| 45 | `active_sessions` | One row per signed-in device; `session_token` UNIQUE; `expires_at` + `last_active` |

Auth-touched (invite/role/first-login columns):
| # | Table | Columns read/written by auth system |
|---|---|---|
| 46 | `profiles` | `role`, `first_login_completed`, `last_login_at`, `email_verified`, `avatar_url`, `phone` |
| 47 | `barbers` | `profile_id`, `onboarding_step` (for invite-flow cascade) |

## 11. RPC functions / DB triggers (2)

| # | Name | Purpose |
|---|---|---|
| 48 | `cleanup_old_auth_events()` | Deletes `auth_events` older than 90 days — called by cron or manually. SECURITY DEFINER |
| 49 | `update_auth_lockouts_updated_at` TRIGGER | BEFORE UPDATE on `auth_lockouts` — bumps `updated_at` |

## 12. RLS policies (expected)

Every table must enumerate actual vs expected.

| # | Table | Expected policies |
|---|---|---|
| 50 | `auth_events` | "Owners can read all auth events" (select, owner), "Barbers can read own auth events" (select, self via profile_id), "Service role can insert auth events" (insert, service_role) |
| 51 | `auth_lockouts` | "Owners can read all lockouts" (select, owner), "Owners can update all lockouts" (update, owner), "Service role has full access to lockouts" (all, service_role) |
| 52 | `active_sessions` | "Owners can read all sessions" (select, owner), "Barbers can read own sessions" (select, self), "Owners can delete all sessions" (delete, owner), "Barbers can delete own sessions" (delete, self), "Service role has full access to sessions" (all, service_role) |
| 53 | `profiles` | Self-read/update, owner-all, client-public-no-pii (migration 037 PII restriction) |

## 13. Migrations (3)

| # | Migration | What it did |
|---|---|---|
| 54 | `015_security_audit.sql` | RLS enablement audit — turned on RLS for communications + payment tables (tangentially adjacent; confirms RLS-enabled baseline) |
| 55 | `021_auth_security.sql` | Created `auth_events`, `auth_lockouts`, `active_sessions`; added `profiles.first_login_completed`, `profiles.last_login_at`, `profiles.email_verified`; `cleanup_old_auth_events()` fn; `update_auth_lockouts_updated_at` trigger |
| 56 | `025_fix_profiles_rls_recursion.sql` | Fixed RLS recursion on `profiles` that was causing role-lookup infinite loops |
| 57 | `027_add_performance_indexes.sql` | Added indexes on auth tables (check for `auth_events`, `active_sessions`) |
| 58 | `031_fix_owner_role.sql` | Backfill/repair for profiles.role owner value |
| 59 | `037_restrict_pii_select_policies.sql` | Tightened PII-read policies on `profiles` / `clients` (affects what middleware/contexts can read) |

## 14. External integrations (2)

| # | System | Touch points |
|---|---|---|
| 60 | Supabase Auth (GoTrue) | `auth.users` table — magic-link invite, password reset, session refresh, JWT issuance with `app_metadata.role`/`user_metadata.role` |
| 61 | Resend + Twilio | Barber invite email (Resend) and SMS (Twilio via `BarberSMS.sendInviteNotification`) — not auth-core, but gates onboarding |

## 15. Cron / background jobs (0 direct)

The `auth_events` table has a `cleanup_old_auth_events()` SQL function, but there is NO Vercel cron currently invoking it (verify). Sessions are cleaned via `cleanupExpiredSessions()` helper called from `session/check` route. Flag as auth-adjacent if an audit finds stale rows piling up.

## 16. Environment variables (5)

| # | Var | Purpose |
|---|---|---|
| 62 | `NEXT_PUBLIC_SUPABASE_URL` | Client + server factory |
| 63 | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Anon-key factories (server.ts, client.ts, middleware.ts) |
| 64 | `SUPABASE_SERVICE_ROLE_KEY` | `admin.ts`, `lockout.ts`, `session-tracker.ts` — server-only, MUST NOT be `NEXT_PUBLIC_*` |
| 65 | `MT_CLIENT_SESSION_SECRET` (or similar) | HMAC sign key for `mt-client-session` cookie |
| 66 | `OWNER_EMAIL` / `OWNER_PASSWORD` | Test/cron accounts (not for production logins) |

---

## Surface Totals

- **Middleware:** 1
- **API routes:** 20 (staff: 14, client-session: 3, invite: 3)
- **Library files:** 7
- **Supabase factories:** 4
- **UI pages:** 8 (auth-group: 5 + reset-password + auth-log + settings)
- **Components:** 2
- **Database tables:** 5 (3 auth-owned + 2 auth-touched)
- **RPC / trigger:** 2
- **RLS policies:** 10+ (across 4 tables)
- **Migrations:** 6
- **Integrations:** 2
- **Env vars:** 5

**Grand total surfaces to audit:** 65+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
