# Onboarding Critical Operational Flows

Multi-step flows where a break at ANY step causes the symptom. Trace each step in order during diagnose mode. Load this file when the user reports a symptom that doesn't map to a single wizard step and you need to walk end-to-end.

All file paths are relative to the MT Barbershop repo root.

---

## FLOW A: Owner creates barber → invite delivered → wizard completes → barber active

**Trigger:** Owner clicks "Add Barber" in `/dashboard/barbers`. Endpoint: `POST /api/auth/create-barber`.

| Step | What happens | Verify |
|---|---|---|
| 1 | Owner authenticated + role check | [src/app/api/auth/create-barber/route.ts:20-42](src/app/api/auth/create-barber/route.ts) |
| 2 | Body validation (email format, station_number > 0) | lines 49-71 |
| 3 | Location exists + email not duplicate | lines 74-100 |
| 4 | `auth.users` created via `createUser({ email_confirm: true })` | lines 107-117. Orphan auto-cleanup at lines 122-167 |
| 5 | `profiles` row inserted (`first_login_completed: false`, `email_verified: true`) | lines 177-192 |
| 6 | `barbers` row inserted with auto-generated slug | lines 198-226. **Note: `barbers.id` ≠ `auth.users.id`. `barbers.profile_id` is the FK.** |
| 7 | Default `barber_schedules` rows inserted (Mon-Sat 9-6) using `barberRecordId` | lines 232-248. **Drift with wizard default — see invariants.md code invariant C6 and scale-anti-patterns.md #5.** |
| 8 | `staff_status` row inserted (`status='clocked_out'`) | lines 250-263. Non-fatal if fails. |
| 9 | Magic-link generated via `generateLink({ type: 'magiclink' })` | lines 273-280. **NOT `'invite'` type — the comment at line 270-272 explains why.** |
| 10 | Email sent via Resend with `barberInviteEmail()` template | lines 292-311 |
| 11 | SMS sent (async, non-blocking) via `BarberSMS.sendInviteNotification` | lines 314-326 |
| 12 | Cascade rollback if any earlier step throws | lines 347-411 |

**Diagnose breakpoints:**

| Symptom | Likely broken step | First check |
|---|---|---|
| "Owner clicks Add Barber, gets 500" | Step 4 (auth user creation) | Check Supabase admin logs for createUser error; check for orphan auth user |
| "Barber says they never got an email" | Step 10 (Resend) | Check Resend dashboard for delivery; check spam folder; verify `RESEND_API_KEY` env |
| "Barber clicks email link → 'token not found'" | Step 9 (magic-link type drift) | The `'invite'` vs `'magiclink'` distinction at line 270-272 is critical. If someone changed it to `'invite'`, links break for users created via `createUser`. |
| "Barber gets to wizard but no schedule shows" | Step 7 (schedule insert) — possibly used `authUserId` instead of `barberRecordId` | Read line 234 — must be `barberRecordId`, not `authUserId` |
| "Multiple barbers with same slug" | Step 6 (slug collision) | Verify the count-suffix logic at lines 200-208 |
| "Created a barber, then tried again with same email, got weird error" | Step 4 orphan-cleanup path | Read lines 122-167. Manual orphan? Query `auth.users WHERE email = '...' AND id NOT IN (SELECT id FROM profiles)` |

---

## FLOW B: Barber clicks invite → sets password → resumes wizard

| Step | What happens | Verify |
|---|---|---|
| 1 | Barber clicks magic-link in email/SMS | URL format: `{appUrl}/auth/confirm?token_hash={hashed}&type=magiclink&next=/barber/setup` |
| 2 | `/auth/confirm` route verifies OTP + redirects | Should land on `/auth/reset-password?invite=true` (per email template comment line 282-284) |
| 3 | Barber sets password → redirected to `/barber/setup` | New session with `auth.users.last_sign_in_at` populated |
| 4 | Wizard `initOnboarding` fires (lines 99-164) | Check role redirect (owner→`/dashboard`), fetch saved step |
| 5 | Wizard renders at saved step (or Step 1 if first time) | line 138-139: validates `step >= 1 && step <= 7` |
| 6 | On every step transition, `saveStep()` PATCHes onboarding-step | line 87-97 |
| 7 | Step 7 POST → `acknowledge-commission` → flips `first_login_completed=true`, `onboarding_step=NULL` | [src/app/api/barber/acknowledge-commission/route.ts](src/app/api/barber/acknowledge-commission/route.ts) |
| 8 | Wizard redirects to `/barber` on next mount | guard at line 140-142 |

**Diagnose breakpoints:**

| Symptom | Likely broken step | First check |
|---|---|---|
| "Magic link says 'token not found'" | Step 2 — token TTL expired (1hr default) | Resend invite from owner staff page |
| "Barber set password but lands on wrong page" | Step 3 — password reset flow routing | Check the redirect from `/auth/reset-password?invite=true` |
| "Wizard shows Step 1 even though I made it to Step 5 yesterday" | Step 4 — onboarding-step fetch failed (5s timeout) | Query their `barbers.onboarding_step` directly; check API logs |
| "Wizard hangs on init" | Step 4 — the `setLoading(false)` only fires inside try blocks | Check setup page for unhandled error path |

---

## FLOW C: Legacy backfill — barber active without commission ack

**Trigger:** Barber created before Step 7 shipped (~2026-03-20). They have `is_active=true`, `first_login_completed=true`, but `commission_acknowledged_at IS NULL`.

| Step | What happens | Verify |
|---|---|---|
| 1 | Barber loads `/barber` home | Page mounts, fetches setup status |
| 2 | `LegacyCommissionAckModal` checks: `is_active=true AND commission_acknowledged_at IS NULL AND onboarding_step IS NULL` | Modal component (Phase 4 of `feature/onboarding-gap-1-pwa-install-schema`) |
| 3 | Modal shows commission terms | One-time, dismissible |
| 4 | Barber clicks Accept → POST `/api/barber/acknowledge-commission` | Idempotent — sets `commission_acknowledged_at = NOW()`, `grace_period_ends_at = NOW() + 30 days` |
| 5 | Modal does not reappear on next login | Check via `commission_acknowledged_at IS NOT NULL` |

---

## How to use this file

Load this reference when `SKILL.md` mode = diagnose AND the symptom is one of:
- A create-barber failure (use FLOW A)
- A wizard-resume or invite-link failure (use FLOW B)
- A legacy commission gap symptom (use FLOW C)

Otherwise, lean on `invariants.md` for single-point checks and `audit-queries.sql` for cross-roster scans.
