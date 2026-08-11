# Auth Incident Registry

---

## Admin Client Session Pollution (2026-03-06)

**Symptom:**
- Barber onboarding E2E test failed intermittently
- Service role admin client was being used to fetch the current user
- Under concurrency, the admin client's session state leaked across requests

**Root cause:**
Admin client (service role key) was being reused for `auth.getUser()` calls. Because the admin client doesn't tie to a specific user, it returned stale or wrong user data under certain cookie patterns.

**Correct pattern:**
- `createClient()` (user client) for `auth.getUser()` and user-scoped queries
- `createAdminClient()` (service role) ONLY for operations that must bypass RLS (e.g., owner creating a barber, cron jobs, cleanup)
- NEVER mix — if you need "authenticated user" data, use the user client.

**Files:**
- `src/lib/supabase/admin.ts` — admin client factory
- `src/lib/supabase/server.ts` — user client factory

**Diagnose checklist:**
1. `grep -rn "createAdminClient" src/app/api/` — every hit must have a justification (bypass RLS for a specific reason).
2. Any admin client call that fetches the "current user" is suspect.
3. Prefer user client, fall back to admin only for explicit admin ops.

---

## Dev Mock / Bypass Removal (2026-03-05)

**Status:** ALL dev mock / fallback / bypass code in auth was removed for production readiness.

**What used to exist (now gone):**
- "Dev Owner" button on `/mtbarberlogin` that bypassed password
- Fake barber login in E2E harness
- Dev mode that skipped role checks
- Mock responses in auth API routes

**Rule (ongoing):**
No dev bypass code in production auth paths. If a dev needs a "quick login," they use the dev owner account (`dev@mtbarbershop.com` / `MTBarbershop2026`) with real Supabase auth.

**Diagnose if suspicious:**
- `grep -rEn "NODE_ENV.*development.*(bypass|mock|skip.*auth)" src/app/api/auth/ src/middleware.ts`
- Any match is a regression. Report to user.

---

## Cookie Cache Cross-User Pollution (historical)

**Symptom:**
- User A logs in as owner
- User A logs out, User B (on same device) logs in as barber
- User B is briefly routed to `/dashboard` (owner page) before middleware corrects

**Root cause:**
Middleware cached `mt-user-role` cookie without a user-ID prefix. When a different user loaded the page, the cached role was still there and middleware used it.

**Fix applied:**
`src/middleware.ts` lines 28-29 — cookie value is now `${user.id}:${role}`. The cache check validates `cachedUserId === user.id` before trusting the cached role.

**Diagnose:**
1. Read `src/middleware.ts` `getUserRole()`.
2. Confirm cookie value includes user ID prefix.
3. Confirm the check `if (cachedUserId === user.id)` exists before trusting the cache.

---

## Lockout Misfires

**Symptom:**
- User enters correct password, gets "account locked" error
- Lockout counter shows 10+ attempts but user swears they only tried twice

**Possible root causes:**
1. Someone else tried their email (brute-force attempt) — the lockout is correct, report to user they may be a target.
2. Failed attempts were logged but password was correct (bug in login route — attempt counter incremented BEFORE password validation).
3. Lockout record doesn't get reset on successful login (another bug).

**Correct flow in `src/app/api/auth/login/route.ts`:**
1. Check lockout. If locked, return 429 WITHOUT attempting password.
2. Try `signInWithPassword`. If fails, `incrementFailedAttempts`.
3. If succeeds, `resetLockout(profileId)`.
4. Log to `auth_events` with success or failure.

**Diagnose:**
1. Query `auth_lockouts` for the email's profile_id.
2. Query `auth_events` for recent login attempts (success + fail).
3. If pattern shows attempts from different IPs → likely brute force. If same IP as user → possible bug.
4. Read the login route to verify order of operations.

---

## Barber Invite Email Never Arrived

**Symptom:**
- Owner clicks "Add Barber" at `/dashboard/barbers`
- Returns success
- Barber never receives the invite email

**Possible root causes:**
1. Resend API key missing or rate-limited
2. Email sent but routed to spam
3. Wrong email in DB (typo)
4. Magic link expired before clicked

**Correct flow in `src/app/api/auth/create-barber/route.ts`:**
1. `adminClient.auth.admin.createUser({ email, email_confirm: true })`
2. Create profile + barber + schedules + staff_status rows
3. Generate magic link via `adminClient.auth.admin.generateLink({ type: 'magiclink', email, options: { redirectTo } })`
4. Send email via Resend
5. Return `{ success, email_sent, invite_url }` — `invite_url` is the fallback if email fails.

**Diagnose:**
1. Check response body from `/api/auth/create-barber` — did `email_sent` come back false? If so, copy the `invite_url` and send it to the barber manually.
2. Verify email in DB: `SELECT email FROM auth.users WHERE email = '...'`.
3. Check Resend dashboard for delivery status.

---

## Concurrent Login Modal Keeps Popping

**Symptom:**
- Barber sees "You've been logged in elsewhere" modal repeatedly
- Each login kicks the previous one out

**Possible root causes:**
1. Two tabs / two devices legitimately — working as intended
2. `active_sessions` has stale rows that aren't being cleaned up — `expires_at` past but row remains
3. `invalidateOldSessions` uses wrong column comparison

**Correct flow in `src/lib/auth/session-tracker.ts`:**
1. On login, write new row to `active_sessions` with new `session_token`.
2. `invalidateOldSessions(profileId, currentSessionToken)` — delete or mark expired all other rows for this profile.
3. Old devices' keepalive pings fail → they trigger the "concurrent login" modal.

**Diagnose:**
1. Query `active_sessions` for the user: `SELECT id, device_type, created_at, expires_at, last_active FROM active_sessions WHERE profile_id = '...' ORDER BY created_at DESC`.
2. More than 1 active row → invalidation isn't firing.
3. Confirm `invalidateOldSessions` is called after every successful login.

---

## Staff/Client Session Crossover (not a bug, but confusing)

**User confusion:**
- Same browser, user logged into `/profile` as client with HMAC cookie
- User opens `/mtbarberlogin` and logs in as barber
- Why doesn't one replace the other?

**Correct behavior:**
Client session (`mt-client-session` cookie, HMAC-signed) is SEPARATE from Supabase auth cookies. The two systems coexist. A barber can also be a client of their own shop (profile account for personal rewards/bookings) and login to both simultaneously.

**Diagnose:**
If this is confusing a user, explain it's by design. No bug.

---

## Test Barber Leaks Into Production Views

**Symptom:**
- Test barber (`b0020000…`) appears on `/team` or booking flow
- Should be hidden

**Root cause:**
Test barbers are `is_active = false`. Every public query filters by `is_active = true`. If a test barber appears, one of those filters is missing.

**Diagnose:**
1. Query: `SELECT id, is_active FROM barbers WHERE id LIKE 'b00%'`.
2. Confirm `is_active = false`.
3. Find the code path that's showing the barber. Grep for the query, verify `.eq('is_active', true)` is present.

---

## Quick Match Table

| Symptom | Likely incident | First file to read |
|---|---|---|
| Brief wrong-role routing after login | cookie cache pollution | `src/middleware.ts:getUserRole` |
| Admin operations return stale user | admin client misuse | `src/lib/supabase/admin.ts` |
| Dev bypass found in auth | 2026-03-05 regression | login route + middleware |
| Lockout on correct password | order of ops in login route | `src/app/api/auth/login/route.ts` |
| Barber invite not received | Resend failure or wrong email | `/api/auth/create-barber` response |
| Concurrent login modal loop | session invalidation not firing | `src/lib/auth/session-tracker.ts` |
| Test barber showing publicly | missing `is_active = true` filter | the page's query |
