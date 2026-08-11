---
name: maguey-bulletproof-auth
description: Audit, diagnose, or scale-check the Maguey Nightclub auth + security system across two apps with different role systems — maguey-pass-lounge (attendee/organizer, customer-facing) and maguey-gate-scanner (owner/promoter/employee, staff-facing). Identity lives in auth.users + JWT metadata claims (no separate profiles extension table in production). Covers ProtectedRoute wrappers, role resolution from user_metadata, localStorage DEV-gating, idle session timeout (scanner only), RLS policies, CORS config, CSP/HSTS headers, invitation flow, security_alerts + security_event_logs audit trail. Use when logins misroute, wrong roles gain access, dev-mode bypass leaks to prod, RLS blocks legit requests, invitation tokens fail, security alerts pile up, or before adding a new role type. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB.
---

# Maguey Bulletproof Auth

Auth in Maguey is unusual: **two distinct role systems** across two apps, sharing one Supabase. Getting it wrong = customers can access staff pages (or vice versa), RLS blocks legit work, or localStorage dev shortcuts leak into production.

## Schema Reality Check (verified 2026-04-21 against live DB)

Many tables the original draft referenced **don't exist in production**. Before acting, re-verify with the query at the end of the Preflight section.

**Tables that DO NOT exist in the live DB:**
- `profiles` — customer extended profile (avatar, phone, DOB, 2FA fields)
- `user_loyalty`, `user_devices`, `referrals`, `magic_links`
- `login_activity` — there is NO server-side login audit table in production
- `organizer_profiles`

**Tables that DO exist and matter for auth:**
- `auth.users` — Supabase-managed. Source of truth for identity, roles (in `user_metadata`), and OAuth providers (in `app_metadata`).
- `security_alerts` — columns: `id, type, severity, source_ip, event_count, recent_events (jsonb), timestamp, acknowledged, acknowledged_by, acknowledged_at, notes, metadata`. Uses `acknowledged`/`acknowledged_at` NOT `resolved_at`.
- `security_event_logs` — columns: `id, event_type, source_ip, signature_prefix, request_timestamp, details (jsonb), created_at`. Captures webhook signature events etc.
- `invitations` — columns: `id, token, created_by, created_at, expires_at, used_at, used_by, metadata (jsonb)`. NO `email` or `role` columns — both live in `metadata`.

**Role storage (verified):**
- Pass-lounge: `user_metadata.account_type` ∈ {`attendee`, `organizer`}. Default `attendee`.
- Gate-scanner: `user_metadata.role` ∈ {`owner`, `promoter`, `employee`}, falls back to `app_metadata.role`. Default `employee`.

**Implication:** features the code references (idle timeout reading from `profiles`, activity log on `/account/settings`, referral codes, etc.) are UI that'll 500 in production until migrations deploy. See `maguey-bulletproof-client-profile` for the full list.

---

## Covered files

**Pass-lounge (customer-facing):**
- `src/contexts/AuthContext.tsx` (81-line shell, delegates to hooks)
- `src/hooks/useAuthSession.ts`, `useAuthMethods.ts`, `useAuthProfile.ts`
- `src/lib/auth.ts` — `getUserRole()` reads `user_metadata.account_type`
- `src/components/ProtectedRoute.tsx`
- `src/pages/Login.tsx`, `src/pages/auth/OwnerLogin.tsx` (organizer login)

**Gate-scanner (staff-facing):**
- `src/contexts/AuthContext.tsx` (214 lines)
- `src/lib/auth.ts` — `getCurrentUserRole()` reads `user_metadata.role` with `app_metadata.role` fallback
- `src/components/layout/ProtectedRoute.tsx` (wraps all 33+ routes)
- `src/pages/auth/OwnerLogin.tsx` (660 lines — login, reset-request, reset-confirm, signup+invitation)
- `src/pages/auth/EmployeeLogin.tsx` (181 lines)
- `src/pages/Auth.tsx` (45-line redirect stub)
- `src/hooks/useIdleTimeout.ts` (162 lines) — idle warning + auto-logout

**Cross-cutting:**
- Edge Function `_shared/cors.ts` (`ALLOWED_ORIGINS`)
- `maguey-nights/src/lib/security-headers.ts` — CSP/HSTS/COOP/CORP
- RLS on orders, tickets, events, vip_reservations, email_queue, security_alerts, invitations

**Not covered here:**
- Stripe webhook signature → `maguey-bulletproof-payments`
- QR HMAC verification → `maguey-bulletproof-scanner`

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — "Auth & Access Control", role system table.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md`.
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

**Re-verify schema first (drift check):**
```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema IN ('public','auth')
  AND table_name IN ('profiles','login_activity','magic_links','user_devices',
                     'organizer_profiles','security_alerts','security_event_logs',
                     'invitations','users');
```
Expected from live DB as of 2026-04-21: only `security_alerts`, `security_event_logs`, `invitations`, `auth.users` return rows. If any of the other names now appear, the migration has deployed — update this file's Schema Reality Check.

Confirm "Preflight complete. Running [mode]." Supabase: `mcp__supabase__execute_sql` project `djbzjasdrwvbsoifxqzd`. Read-only.

---

## Choose a Mode

- **audit** → weekly; before adding roles or deploying to prod
- **diagnose** → auth symptom reported
- **scale-check** → adding a new role type, new login flow, or expanding staff team

---

## Mode: audit

### Code-level invariants

1. **Two separate role systems enforced**
   - Pass-lounge `src/lib/auth.ts`: reads `user.user_metadata.account_type`, default `'attendee'`
   - Scanner `src/lib/auth.ts`: reads `user.user_metadata.role` then `user.app_metadata.role`, default `'employee'`
   - Grep: `grep -rn "account_type\|user_metadata.role\|app_metadata.role" maguey-pass-lounge/src/lib/auth.ts maguey-gate-scanner/src/lib/auth.ts`
   - FAIL if either app reads the other's field.

2. **localStorage auth gated behind DEV**
   - Scanner `src/contexts/AuthContext.tsx` — any `localStorageService.*` or `localStorage.getItem('maguey_user')` call must be wrapped in `if (import.meta.env.DEV)`.
   - Grep: `grep -n "localStorage" maguey-gate-scanner/src/contexts/AuthContext.tsx`
   - Every hit must have a DEV guard in the surrounding block.

3. **ProtectedRoute wraps all dashboard routes**
   - Scanner: `src/components/layout/ProtectedRoute.tsx` — 33+ routes
   - Pass-lounge: `src/components/ProtectedRoute.tsx`
   - Grep: `grep -n "ProtectedRoute" maguey-gate-scanner/src/App.tsx maguey-pass-lounge/src/App.tsx`

4. **Separate login pages**
   - Scanner: `/auth` redirects to `/auth/employee` (default) or `/auth/owner`
   - Pass-lounge: `/login` for customers, `/auth/owner` for organizers
   - Visual differentiation so customers don't confuse organizer login with staff login.

5. **Idle session timeout (scanner only — known gap on pass-lounge)**
   - Scanner: `src/hooks/useIdleTimeout.ts` — activity listeners + 15-sec check + cross-tab localStorage timestamp sync
   - Pass-lounge: NO idle timeout. Flag in every audit.

6. **CORS allowlist on Edge Functions**
   - Pass-lounge `_shared/cors.ts` has explicit allowlist + `ALLOWED_ORIGINS` env override.
   - Grep: `grep -n "ALLOWED_ORIGINS\|PRODUCTION_ORIGINS" maguey-pass-lounge/supabase/functions/_shared/cors.ts`
   - Gate-scanner Edge Functions should either import that shared module or replicate the pattern. Grep each function.

7. **No VITE_-prefixed secrets**
   - Grep all 3 apps: `grep -rn "VITE_.*SECRET\|VITE_.*KEY" --include="*.ts" --include="*.tsx" maguey-*/src`
   - Only `VITE_STRIPE_PUBLISHABLE_KEY` is public-by-design. Any other VITE_SECRET = P0.

8. **Security headers on marketing**
   - `maguey-nights/src/lib/security-headers.ts` — CSP, HSTS (1yr preload), X-Frame-Options DENY, COOP, CORP, Referrer-Policy.
   - Pass-lounge + gate-scanner do NOT have equivalent — known gap, flag.

9. **Invitation flow enforced**
   - Scanner OwnerLogin with `?invite=<token>` query: calls `validateInvitation(token)` before signup; `consumeInvitation(token, userId)` on submit.
   - Role assignment comes from `invitations.metadata->>'role'` — verify `metadata` contains `role`.
   - Grep: `grep -n "validateInvitation\|consumeInvitation" maguey-gate-scanner/src/pages/auth/OwnerLogin.tsx`

10. **Session status + auto-refresh**
    - `useAuthSession.ts` monitors `expiresAt`, surfaces warning when `minutesRemaining <= 5`.
    - Supabase `onAuthStateChange` listener handles refresh transparently.

11. **security_alerts acknowledged**
    - `security_alerts` uses `acknowledged`/`acknowledged_at` fields (NOT `resolved_at`). Any older skill draft that queried `resolved_at` was wrong. Audit query #4 uses the real column.

### Data-level invariants

Run `references/audit-queries.sql`.

### Audit output template

```
## Auth Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Role systems use separate metadata fields
- [PASS/FAIL] localStorage auth gated behind import.meta.env.DEV
- [PASS/FAIL] ProtectedRoute wraps all dashboard routes
- [PASS/FAIL] Separate login pages (staff vs customer)
- [PASS/FAIL] Idle timeout on scanner
- [KNOWN-GAP] No idle timeout on pass-lounge
- [PASS/FAIL] CORS allowlist on pass-lounge Edge Functions
- [FLAG] Verify CORS per-function on gate-scanner Edge Functions
- [PASS/FAIL] No VITE_SECRETS leaked
- [PASS/FAIL] Security headers on maguey-nights
- [KNOWN-GAP] Security headers absent on pass-lounge + scanner
- [PASS/FAIL] Invitation flow wired (validate + consume + role from metadata)
- [PASS/FAIL] Session refresh active

### Data-level
- [PASS/FAIL] No users with unexpected role values (query #1)
- [PASS/FAIL] Stale invitations cleanup (query #2)
- [PASS/FAIL] Unacknowledged security_alerts >24h (query #4)
- [PASS/FAIL] RLS policy inventory matches expected (query #5)
- [PASS/FAIL] Unconfirmed emails not logging in (query #6)
- [PASS/FAIL] Role distribution plausible (query #7)

### Failures + Known Gaps
[List]
```

---

## Mode: diagnose

### Step 1: Ask
- Which app? pass-lounge (customer) or gate-scanner (staff)?
- Expected role vs what they see?
- Error? (redirect loop, 403, session expired, "invalid invitation")
- New signup or existing login?

### Step 2: Simple checks
```sql
-- Find the user (use raw_* column names when querying auth.users directly —
-- the JS client exposes these as user_metadata/app_metadata, but Postgres
-- stores them as raw_user_meta_data/raw_app_meta_data):
SELECT id, email, email_confirmed_at, last_sign_in_at,
       raw_user_meta_data->>'role' AS scanner_role,
       raw_user_meta_data->>'account_type' AS pass_role,
       raw_app_meta_data->>'role' AS legacy_role
FROM auth.users WHERE email = '<email>';

-- Active invitation for that email (if signup flow):
SELECT i.id, i.token, i.expires_at, i.used_at, i.metadata
FROM invitations i
WHERE i.metadata->>'email' = '<email>'
ORDER BY i.created_at DESC;

-- Any security_alerts tied to their IP:
SELECT id, type, severity, source_ip, timestamp, acknowledged
FROM security_alerts
WHERE timestamp > now() - interval '24 hours'
ORDER BY timestamp DESC LIMIT 20;
```

### Step 3: Match against incidents (see `references/incidents.md`)
- Redirect loop → ProtectedRoute + AuthContext race condition
- Customer hit `/auth/owner` on pass-lounge → wrong URL, organizer-only login
- "Unauthorized" on page they should see → role mismatch or stale JWT
- Magic link expired → not supported in live DB (magic_links table missing)
- Invitation "invalid" → token expired, already consumed, or `metadata.role` missing

### Step 4-6: 3-file rule, Two-strike, stay in scope.

---

## Mode: scale-check

### 1. Role matrix extension
- Adding a role (e.g. `door_host`): update `src/lib/auth.ts` permission matrix on scanner. Grep every `'owner'`, `'promoter'`, `'employee'` literal for pages to update.
- Grep: `grep -rn "'owner'\|'promoter'\|'employee'" maguey-gate-scanner/src`

### 2. RLS policy review
- Every RLS policy with role-specific `current_setting('request.jwt.claims')::json->>'role' IN (...)` must include the new role.
- Audit query #5 surfaces all policies.

### 3. Invitation metadata schema
- New role must be supplied via `invitations.metadata->>'role'`. Verify invitation creation UI sets it.

### 4. Session cap
- Supabase auth concurrent sessions — effectively unlimited but check if project has custom quotas. Not usually a concern.

### Output

```
## Auth Scale Readiness

### Roles added: [list]
### Permission matrix updates: [file list]
### RLS policies to update: [list from query #5]
### Invitation flow covers new role: [YES/NO]

### Verdict: [READY / NOT READY]
```

---

## Critical Flow: Scanner staff login

1. Staff opens `staff.magueynightclub.com` → no session → redirect `/auth` → redirect `/auth/employee` (or `/auth/owner`)
2. Submit email + password → `supabase.auth.signInWithPassword` → session + JWT
3. `useAuthSession` detects change → `user_metadata.role` read
4. `ProtectedRoute` evaluates role against route permission
5. Allowed: render dashboard. Not: `/unauthorized`
6. `useIdleTimeout` ticks
7. N min inactive: warning → M min more: auto-logout

## Critical Flow: Pass-lounge customer login

1. `/login` on tickets.magueynightclub.com
2. Email/password, OAuth (Google/Facebook/Apple/GitHub), or magic link
3. Signup default: `account_type = 'attendee'`
4. `ProtectedRoute` gates `/account`, `/orders`
5. `tickets` / `orders` RLS keyed to JWT email for the customer's own view
6. **No idle timeout** (gap)

## Critical Flow: Staff invitation signup

1. Owner generates invitation → INSERT `invitations` with `token`, `expires_at`, `metadata = {email, role}`
2. Share `/auth/owner?invite=<token>`
3. Staff opens → `validateInvitation(token)` (SELECT with `expires_at > now()` and `used_at IS NULL`)
4. Signup form shown with email pre-filled from `metadata.email`, role assigned from `metadata.role`
5. On submit → `supabase.auth.signUp` → `consumeInvitation(token, newUserId)` marks `used_at` + `used_by`
6. User auto-logged in

---

## HARD RULES

- **NEVER write to prod DB.** Read-only via MCP.
- **NEVER mix role systems.** Pass-lounge reads `account_type`; scanner reads `role`. Crossing them = subtle auth bugs.
- **NEVER add a localStorage auth path without `import.meta.env.DEV` guard.**
- **NEVER weaken RLS without equivalent replacement** — RLS is defense-in-depth even if app-layer checks also exist.
- **NEVER push auth changes without redeploying all affected apps** — session shape changes break live users.
- **Branch workflow:** fix/... or feature/... branches.
- **User reports override queries.** "I can access the admin page" → trust them, find the gap.
