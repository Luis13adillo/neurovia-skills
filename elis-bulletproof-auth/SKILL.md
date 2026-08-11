---
name: elis-bulletproof-auth
description: Audit, diagnose, or scale-check the Eli's Dulce Tradicion auth & role system (src/contexts/AuthContext.tsx, src/components/auth/ProtectedRoute.tsx, src/components/auth/AuthenticatorAssuranceCheck.tsx, src/components/auth/SessionTimeoutModal.tsx, Supabase JWT auth, user_profiles table with role column, 3 roles owner/baker/customer, login/signup pages, role routing to /owner-dashboard vs /front-desk vs /, known auth loading race conditions, session persistence, MFA for owner role, backend/middleware/auth.js JWT verification, seed scripts at backend/scripts/seed-admin-users.js and backend/scripts/seed-frontdesk-user.js). Use when login bounces between pages, role-based redirects loop, baker/owner can't access their dashboard, session expires silently mid-work, MFA doesn't enforce, or before inviting a new staff member. Read-only SQL via mcp__supabase__execute_sql (project rnszrscxwkdwvvlsihqc). Never writes to production DB. Never modifies auth code without explicit user approval.
---

# Eli's Bulletproof Auth

Auth is where the whole product lives or dies. If the baker can't log into FrontDesk, the kitchen goes blind. If a customer is accidentally promoted to owner, you have an incident. MEMORY.md has explicit scar tissue from past auth bugs — this skill exists to keep those bugs from coming back.

This skill covers:
- `src/contexts/AuthContext.tsx` — provider, `signIn`/`signUp`/`signOut`, `loadUserProfile`, auth state
- `src/components/auth/ProtectedRoute.tsx` — route guard
- `src/components/auth/AuthenticatorAssuranceCheck.tsx` — MFA / AAL2 gate
- `src/components/auth/SessionTimeoutModal.tsx` — timeout warning
- `src/pages/Login.tsx` + `src/pages/Signup.tsx`
- `src/lib/supabase.ts` — client init with `persistSession: true`
- `src/types/auth.ts` — `UserRole = 'owner' | 'baker' | 'customer'`, `UserProfile`, `AuthUser`
- `backend/middleware/auth.js` — Express JWT verification (if backend is live)
- `backend/scripts/seed-admin-users.js` + `seed-frontdesk-user.js` — bootstrap scripts
- Tables: `user_profiles` (user_id → auth.users.id, role, created_at)
- Migration: `20260404_session_timeout.sql`

**Not covered here:**
- Order-tracking page (which is intentionally no-login) → `elis-bulletproof-orders`
- Owner dashboard role gate per-component → `elis-bulletproof-dashboard`
- Front desk role gate → `elis-bulletproof-frontdesk`

---

## The role → route map (the contract)

| Role | Lands on | Allowed | Blocked |
|---|---|---|---|
| `owner` | `/owner-dashboard` | `/owner-dashboard/*`, `/front-desk`, public | — |
| `baker` | `/front-desk` | `/front-desk`, public | `/owner-dashboard` |
| `customer` (authenticated) | `/` | public, `/order`, `/order-tracking`, their own order history | `/owner-dashboard`, `/front-desk` |
| unauthenticated | `/login` on any protected route | public, `/order` (guest checkout), `/order-tracking` | `/owner-dashboard`, `/front-desk` |

MEMORY.md: `'baker'` is the DB value; user-facing label is "Front Desk" / "Recepción".

---

## Known auth scars (from MEMORY.md — flag every audit)

1. **NEVER add safety timeouts that fire before profile fetch completes.** Past incident: premature `isLoading=false` caused a redirect loop.
2. **NEVER duplicate ProtectedRoute checks inside dashboard components.** Past incident: race condition redirects.
3. **When profile role is undefined, redirect to `/login`, NOT to `/`.** Past incident: redirect loop at homepage.
4. **`useInactivityTimeout` was removed from OwnerDashboard** — caused session instability. Do not re-add.
5. **`isAuthenticated = !!user`** — true even while profile is null/loading. Must pair with loaded profile before making role decisions.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — Auth & Roles section.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-elis-dulce-tradicion/memory/MEMORY.md` — the five scars above.
3. Supabase project `rnszrscxwkdwvvlsihqc`. Auth dashboard → Settings → JWT / Sessions / MFA.
4. State: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** — monthly + after any AuthContext or ProtectedRoute edit
- **diagnose** — login / redirect / session / role bug reported
- **scale-check** — adding a new role or new staff member

---

## Mode: audit

### Code-level invariants

1. **`loadUserProfile` does not fire before the session resolves.**
   - Initial effect should wait for `getSession()` OR use `onAuthStateChange` + a guard.
   - No premature `setIsLoading(false)` before the profile fetch returns.
   - Grep: `grep -n "getSession\|onAuthStateChange\|loadUserProfile\|setIsLoading" src/contexts/AuthContext.tsx`

2. **`onAuthStateChange` listener is cleaned up on unmount.**
   - Must return `data.subscription.unsubscribe()`.
   - Grep: `grep -n "subscription\|unsubscribe\|useEffect" src/contexts/AuthContext.tsx`

3. **ProtectedRoute is the ONLY role gate.**
   - Grep: `grep -rn "profile?.role\|role ===\|role !==" src/pages/OwnerDashboard.tsx src/pages/FrontDesk.tsx`
   - A role-based `useEffect → navigate` inside a dashboard page = FAIL (MEMORY.md scar #2).

4. **Role value set is enforced.**
   - Query: `SELECT DISTINCT role FROM user_profiles;` — expect only `owner`, `baker`, `customer`. Any other value (`null`, `admin`, `staff`) is a red flag.
   - Code: `src/types/auth.ts` should type `UserRole` as a union of the three.

5. **Sign out clears both Supabase session and any local state.**
   - Grep: `grep -n "signOut\|setUser(null)\|setProfile" src/contexts/AuthContext.tsx`
   - A lingering `user` or `profile` post-signout = stale state on next login.

6. **Signup path creates a `user_profiles` row.**
   - If signup leaves auth.users with no matching user_profiles row, the user has no role → ProtectedRoute denies → they're stuck.
   - Grep: `grep -n "user_profiles\|insert\|from('user_profiles'" src/contexts/AuthContext.tsx src/pages/Signup.tsx supabase/migrations/`
   - Preferred: a trigger on `auth.users` INSERT that seeds `user_profiles` with `role='customer'`.
   - Query: `SELECT COUNT(*) FROM auth.users u LEFT JOIN public.user_profiles p ON p.user_id = u.id WHERE p.id IS NULL;` → should be 0.

7. **Role cannot be set from client.**
   - The signup form or any client call should NOT be able to set `role` on user_profiles. RLS on user_profiles must deny client-side UPDATE of `role`.
   - Query: `SELECT policyname, cmd, qual FROM pg_policies WHERE tablename='user_profiles';`
   - A missing RESTRICTIVE policy on UPDATE → any authenticated user can promote themselves.

8. **MFA check exists (even if not yet enforced).**
   - `AuthenticatorAssuranceCheck.tsx` should read `supabase.auth.mfa.getAuthenticatorAssuranceLevel()` and compare to required AAL.
   - Grep: `grep -n "mfa\|aal\|AAL\|getAuthenticatorAssuranceLevel" src/components/auth/`
   - If the component exists but is not wired into the owner's route, it's a stub. Flag.

9. **Session timeout uses migration `20260404_session_timeout.sql`.**
   - `business_settings.session_timeout_minutes` drives `SessionTimeoutModal`.
   - Grep: `grep -n "session_timeout\|SessionTimeoutModal" src/contexts/AuthContext.tsx src/pages/OwnerDashboard.tsx src/pages/FrontDesk.tsx`
   - **NOTE:** MEMORY.md says `useInactivityTimeout` was removed from OwnerDashboard — but a SessionTimeoutModal is different (user-facing warning + extend button). Confirm the modal is wired, the inactivity auto-logout is not (or is paired with a refresh path).

10. **Backend JWT verification uses the Supabase JWKS or the shared secret.**
    - `backend/middleware/auth.js` must verify the JWT signature before trusting claims.
    - Grep: `grep -n "jwt.verify\|verify\|JWKS\|jwks" backend/middleware/auth.js`
    - Failure to verify = any token can pass.

11. **Seed scripts do not run in prod without explicit flag.**
    - `backend/scripts/seed-admin-users.js` creates the hardcoded owner account. If accidentally run against prod, you risk resetting the password.
    - Grep: `grep -n "NODE_ENV\|production\|--force\|password" backend/scripts/seed-*.js`

12. **No `useInactivityTimeout` in OwnerDashboard or FrontDesk.**
    - Grep: `grep -rn "useInactivityTimeout" src/pages/OwnerDashboard.tsx src/pages/FrontDesk.tsx` → should return nothing.

### Data-level invariants

```sql
-- A1. Auth users without a profile row
SELECT COUNT(*) FROM auth.users u
LEFT JOIN public.user_profiles p ON p.user_id = u.id
WHERE p.id IS NULL;

-- A2. Profiles with invalid role
SELECT id, user_id, role FROM user_profiles
WHERE role NOT IN ('owner', 'baker', 'customer');

-- A3. Multiple owner accounts (should normally be 1)
SELECT user_id, role FROM user_profiles WHERE role = 'owner';

-- A4. Recent profile role changes (audit trail if captured)
SELECT * FROM audit_logs
WHERE action ILIKE '%role%' OR entity_type = 'user_profiles'
ORDER BY created_at DESC LIMIT 20;

-- A5. RLS policies on user_profiles
SELECT policyname, cmd, qual, with_check FROM pg_policies
WHERE tablename = 'user_profiles';

-- A6. MFA factors enrolled
SELECT user_id, COUNT(*) FROM auth.mfa_factors WHERE status='verified' GROUP BY user_id;
-- Owner should appear here if MFA is actually configured.

-- A7. Session TTL / refresh interval
-- Check Supabase Dashboard → Authentication → Settings — document current values.
```

### Audit output template

```
## Auth Audit — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] loadUserProfile waits for session
- [PASS/FAIL] onAuthStateChange subscription cleanup
- [PASS/FAIL] ProtectedRoute is sole role gate
- [PASS/FAIL] UserRole type enforced
- [PASS/FAIL] signOut clears local state
- [PASS/FAIL] Signup seeds user_profiles (trigger or code)
- [PASS/FAIL] RLS prevents client role elevation
- [PASS / NOTE / GAP] MFA check wired for owner
- [PASS/FAIL] SessionTimeoutModal wired (but no raw useInactivityTimeout)
- [PASS/FAIL] Backend verifies JWT signature
- [PASS/FAIL] Seed scripts guarded against prod
- [PASS] No useInactivityTimeout regressions

### Data-level
- A1 auth users missing profile: X (target: 0)
- A2 invalid roles: X (target: 0)
- A3 owner accounts: X (expected: 1)
- A4 recent role changes: [list]
- A5 RLS on user_profiles: [policies enforce expected pattern? Y/N]
- A6 MFA enrolled users: X
- A7 Supabase Auth session TTL: [document]

### MEMORY.md scar regression check
- [PASS] No safety timeout before profile fetch
- [PASS] No duplicate role checks in OwnerDashboard / FrontDesk
- [PASS] No redirect-to-/ on undefined role (redirects to /login)
- [PASS] No useInactivityTimeout
- [PASS] isAuthenticated gated by profile before role-based UI
```

---

## Mode: diagnose

### Step 1 — Ask
- Who (email)? What role do they have in `user_profiles`?
- What did they try to do?
- What page were they on when the bug fired? What did they see?

### Step 2 — Symptom matrix

| Symptom | Likely cause | Check |
|---|---|---|
| "Login redirects me back to login" | onAuthStateChange fires before profile loads; OR profile undefined + MEMORY scar #3 not fixed | Invariant #1, #3; A1 |
| "Owner got logged into front desk" | Role mismatch in user_profiles; OR ProtectedRoute logic inverted | A2 / A3; re-read ProtectedRoute |
| "Baker can see owner dashboard" | ProtectedRoute not checking role for /owner-dashboard; OR user_profiles.role wrong | A2; ProtectedRoute config |
| "Tab auto-logs-out every N minutes" | useInactivityTimeout re-added; OR session TTL too short | Invariant #12; A7 |
| "Signup completes but user can't log in" | No user_profiles row → ProtectedRoute denies | A1; check signup trigger |
| "Random user can see all orders" | RLS on orders allows authenticated reads; OR role elevation | Check orders RLS policies; A5 |
| "Owner account got promoted to another user" | user_profiles UPDATE from client; missing RLS | A5 — look for UPDATE policy that allows row self-modification of role |

### Step 3 — Test a login path end-to-end
- Open incognito → `/login` → enter owner creds → should land on `/owner-dashboard`.
- Repeat for baker account.
- If either fails, look at the 3 files most likely: AuthContext.tsx, ProtectedRoute.tsx, App.tsx route declarations.

### Step 4 — Report, do not fix
Root cause + proposed patch + MEMORY.md scar reference if applicable.

---

## Mode: scale-check

Adding a new staff member OR a new role:

1. **New baker:** seed via `backend/scripts/seed-frontdesk-user.js` (against prod Supabase) or do it manually in Supabase dashboard:
   - Create auth.users row (Invitation flow)
   - Insert user_profiles row with `role='baker'`
   - Test login in staging before giving creds to the baker
2. **New role type:** updating `UserRole` union + ProtectedRoute + every page's role check + user_profiles CHECK constraint + RLS policies. High blast radius — plan in `.planning/` first.
3. **MFA rollout:** if enforcing MFA for owner, stage it:
   - Step 1: owner enrolls factor without enforcement
   - Step 2: verify backup codes / recovery plan
   - Step 3: flip enforcement flag in Supabase Auth dashboard
   - Never flip enforcement before the owner is enrolled — they'll lock themselves out.
4. **Session TTL tuning:** shorter TTL = more frequent silent refreshes = more chance something breaks. Keep default unless a specific threat model demands change.

### Output
```
## Auth Scale Readiness — Change: [new baker / new role / MFA rollout]

- Action plan: [list]
- Rollback plan: [how to back out]
- Staging test done: Y/N
- MEMORY.md scars preserved: Y/N

Verdict: [READY / NOT READY]
```

---

## HARD RULES

- **NEVER write to production auth.users or user_profiles** from this skill. Use Supabase Dashboard for manual changes, and always via a peer-reviewed runbook.
- **NEVER re-add `useInactivityTimeout`** — MEMORY.md scar #4.
- **NEVER add a role check inside** OwnerDashboard / FrontDesk components — MEMORY.md scar #2.
- **NEVER redirect to `/`** when profile role is undefined — use `/login` — MEMORY.md scar #3.
- **NEVER run `seed-admin-users.js` against prod** — it will stomp the owner account.
- **NEVER expose `SUPABASE_SERVICE_ROLE_KEY`** to the frontend. If grep finds it in `src/`, treat as P0.
- **NEVER disable RLS** "to debug" — if it blocks a query, the query is wrong OR the policy is wrong, never both.
- **Scope:** if a fix touches order data, dashboard UI, or edge functions, hand off.
