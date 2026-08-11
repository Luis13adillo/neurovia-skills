---
name: bulletproof-auth
description: Audit, diagnose, or scale-check the MT Barbershop auth & security system (middleware role routing, 3-tier role resolution, Supabase auth vs HMAC client session, auth_events, auth_lockouts, active_sessions, barber invite flow). Use when login breaks, wrong role routes, lockouts misfire, sessions drift, or before adding new role types. Read-only SQL via mcp__supabase-mt__execute_sql only. Never writes to the production DB.
---

# Bulletproof Auth

Auth is the trust boundary. A bug here routes owner to barber dashboard (data exposure), locks out a real user (lost trust), or lets a test account impersonate a real barber (revenue confusion). This domain has two parallel auth systems: Supabase Auth for staff, HMAC-signed tokens for clients. They do NOT cross.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "Authentication" section and test accounts.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — test accounts HARD RULE, admin client session pollution bug (2026-03-06), dev mock removal (2026-03-05).
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — middleware patterns.

Confirm "Preflight complete. Running [mode]."

---

## Test Accounts — CANONICAL

| Email | Role | Barber ID | Active | Notes |
|---|---|---|---|---|
| `info@mtbarbershop.com` | owner | `b0010000-0000-0000-0000-000000000001` | true | REAL owner (Gustavo). OFF LIMITS for testing. |
| `dev@mtbarbershop.com` | owner | `a274e1cf-955a-46f1-bc4c-dcd06a0510af` | false (barber row) | Dev owner, full-clone of prod owner. Use this for testing. |
| `luismbadillo13@gmail.com` | barber | `b0020000-0000-0000-0000-000000000002` | false | Luis test barber. |
| `test-barber-3@mtbarbershop.com` | barber | `b0030000-0000-0000-0000-000000000003` | false | Test barber 3 (no password). |
| `test-barber-4@mtbarbershop.com` | barber | `b0040000-0000-0000-0000-000000000004` | false | Test barber 4 (no password). |

**HARD RULE:** NEVER test on real barbers. Real barbers OFF LIMITS: Gustavo (`b0010000…`), Brayan, Eddie, Fran, Juan, Junii, Lili, Pedro, Stanley.

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**. `audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that edits code, and only under the explicit gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (65+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration. Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one file's behavior depends on another that looks unrelated.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `api/auth/login/route.ts` (successful login path) | `checkLockout()` call site + `supabase.auth.signInWithPassword` + `resetLockout()` + `invalidateOldSessions()` + `createSession()` + `logAuthEvent('login_success')` + `active_sessions` INSERT + middleware role-cookie rewrite | Login has 7 downstream writes. A silent catch on any one = missing session, stale lockout, or ghost auth_events row. Dropping `invalidateOldSessions` = concurrent-login modal spiral. |
| `api/auth/login/route.ts` (failure path) | `recordFailedAttempt()` + `auth_lockouts` row + `logAuthEvent('login_failed')` + owner_alerts spike detection (if N failed-attempts per min) | A failure that bypasses `recordFailedAttempt` lets attackers grind passwords. A failure that skips `logAuthEvent` erases forensics. |
| `lib/auth/lockout.ts` (`lockAccount`) | `auth_lockouts.locked_until` set + `logAuthEvent('lockout')` + owner_alerts write + `recordFailedAttempt` exponential-backoff logic | Lockouts have operational consequences (real user can't log in). Missing owner alert = owner unaware. |
| `api/auth/create-barber/route.ts` (invite) | Supabase `auth.admin.createUser` + `profiles` INSERT + `barbers` INSERT (onboarding_step=null, first_login_completed=false on profiles) + default `barber_schedules` INSERT + `staff_status` INSERT + Resend `barberInviteEmail` + Twilio `BarberSMS.sendInviteNotification` + cascade-rollback catch block (staff_status → schedules → barbers → profiles → auth.users) | Create-barber is a 7-write atomic. Any partial failure orphans rows. The rollback order is FK-respecting — reversing it deadlocks on FK constraint. |
| `api/auth/resend-invite/route.ts` | Supabase magic-link regeneration (new token invalidates old) + `logAuthEvent('password_reset_requested')` + Resend email + Twilio SMS + `profiles.email_verified` state unchanged | Resend must NOT flip `email_verified` — only successful login does. Old magic link must be invalidated by Supabase. |
| `api/auth/set-password/route.ts` (Step 1 wizard) | `supabase.auth.updateUser({password})` + `profiles.email_verified = true` + `logAuthEvent('password_changed')` + `barbers.onboarding_step = 1` initialization + session creation for the just-signed-in user | Set-password is the bridge from "invited" to "in-progress". If `email_verified` doesn't flip, the barber is stuck. If `onboarding_step` isn't set, the wizard init guard loops. |
| `middleware.ts` (`getUserRole`) | Cookie `mt-user-role` format check (`${user.id}:${role}`) + JWT `app_metadata.role` read + `profiles.role` DB fallback + admin-client NEVER used here + `cache: 'no-store'` on the Supabase factory it calls | 3-tier resolution. Skipping user-ID prefix check on cookie = cross-user pollution (observed 2026-03-06). Admin client in middleware = session pollution. |
| `middleware.ts` (client session path) | `mt-client-session` cookie HMAC verify + 7-day expiry check + does NOT touch Supabase cookies + `/profile` route scoped to client session only | Staff Supabase and client HMAC are two universes. Any cross-read breaks trust boundary. |
| `api/auth/session/keepalive/route.ts` | `active_sessions.last_active` UPDATE + `expires_at` sliding-window check + NO admin client in path | Keepalive is a high-frequency endpoint. Admin client here = session pollution across requests. |
| `api/auth/session/check/route.ts` + `ConcurrentLoginModal.tsx` | `active_sessions.session_token` uniqueness + `invalidateOldSessions` fired on new login + polling cadence in modal doesn't hammer | One profile with two `active_sessions` rows both unexpired = concurrent-login modal loops. |
| `api/auth/force-logout*/route.ts` | `active_sessions` DELETE (single or all) + `logAuthEvent('force_logout')` + session cookie clear on next request via middleware + owner-role check | Force-logout without auth_events write = no forensic trail. Without cookie clear = ghost session. |
| `api/auth/logout-device/route.ts` | Same as force-logout but scoped to caller's session id | Self-logout must NOT delete other users' sessions. RLS + application-level check. |
| `lib/auth/session-tracker.ts` (`invalidateOldSessions`) | `active_sessions` DELETE by profile_id + exclude current `session_token` + uses admin client (intentional RLS bypass) + no cascade into auth_events | This is the ONLY place admin client is acceptable for session ops — confirm it's not leaking elsewhere. |
| `lib/auth/logger.ts` (`logAuthEvent`) | `auth_events` INSERT + IP + user_agent from request + device_info via `device-detection.ts` + NEVER logs raw tokens or passwords | PII + secret hygiene. A token fragment in `auth_events` = persistent data leak. |
| `auth_events` row writes | RLS owner-select policy + barber-self-select policy + service-insert policy + `cleanup_old_auth_events()` 90-day retention | Missing retention = unbounded table growth. Missing self-select = barber can't see their own history. |
| `auth_lockouts` row writes | RLS owner-select + owner-update + service-all + `update_auth_lockouts_updated_at` trigger + `locked_until > NOW()` check-before-password in login route | A missing trigger leaves stale `updated_at`. Missing pre-password check = locked account still burns attempts. |
| `barbers.profile_id` FK chain | `profiles.role = 'barber'` + `auth.users` row + `staff_status` row for (barber, primary location) + `barber_schedules` ≥1 row | Creating a barber without any of these downstream rows = barber exists in staff list but can't clock in, can't be scheduled, can't appear on /team. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the auth domain values:

```sql
-- 1. Enumerate auth domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('auth_events','auth_lockouts','active_sessions','profiles','barbers')
ORDER BY table_name;
-- Expected: 5 rows. Missing any = inventory drift; STOP and ask user.

-- 2. RLS policies on every auth table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('auth_events','auth_lockouts','active_sessions','profiles')
ORDER BY tablename, policyname;
-- Expected: at least 10 rows (see SURFACE_INVENTORY.md section 12).
-- Any missing policy or extra-permissive policy = RLS gap; FLAG in coverage report.

-- 3. Triggers on auth-touched tables
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('auth_lockouts','auth_events','active_sessions','profiles')
ORDER BY event_object_table, trigger_name;
-- Expected: trigger_update_auth_lockouts_updated_at on auth_lockouts.

-- 4. RPC functions in domain
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('cleanup_old_auth_events','update_auth_lockouts_updated_at');
-- Expected: 2 rows, all has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%auth_security%' OR name ILIKE '%security_audit%'
   OR name ILIKE '%profiles_rls%' OR name ILIKE '%owner_role%'
   OR name ILIKE '%pii%' OR name ILIKE '%performance_indexes%'
ORDER BY executed_at;
-- Expected: at least 6 rows (015, 021, 025_fix_profiles_rls, 027, 031, 037 — see inventory section 13).
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **3-tier role resolution intact**
   - File: `src/middleware.ts` lines ~19-67 (`getUserRole` function).
   - Must check (in order): cookie cache with user-ID match → JWT `app_metadata.role` / `user_metadata.role` → `profiles.role` query.
   - Cookie must include user ID prefix (`${user.id}:${role}`) to prevent cross-user pollution.

2. **Service role key only server-side**
   - Files: `src/lib/supabase/admin.ts`, `src/lib/auth/session-tracker.ts`, `src/lib/auth/lockout.ts`.
   - Must use `SUPABASE_SERVICE_ROLE_KEY`, NOT `NEXT_PUBLIC_*`.
   - Grep: `grep -rn "NEXT_PUBLIC_SUPABASE_SERVICE_ROLE" src/` — expected 0 matches.
   - Grep: `grep -rn "SUPABASE_SERVICE_ROLE_KEY" src/` — matches should be in server files only (no `'use client'` files).

3. **No dev mock bypass in auth**
   - Per MEMORY.md (2026-03-05 production readiness): all dev mock/fallback was removed.
   - Grep: `grep -rn "if.*NODE_ENV.*development.*(role|bypass|mock)" src/app/api/auth/ src/middleware.ts src/lib/auth/` — expected 0 matches suggesting dev bypass.

4. **Lockout check happens before password attempt**
   - File: `src/app/api/auth/login/route.ts`
   - Must call `checkLockout(email)` BEFORE `supabase.auth.signInWithPassword`. Otherwise, locked accounts can still increment attempts.

5. **HMAC client session is separate from staff**
   - File: `src/lib/auth/client-session.ts`
   - Client tokens use HMAC-SHA256, 7-day expiry, cookie `mt-client-session`.
   - Must NOT intersect with Supabase auth cookies.
   - Middleware routes `/profile` based on client session; staff routes based on Supabase.

6. **Admin client isolation** (from 2026-03-06 incident)
   - File: `src/lib/supabase/admin.ts`
   - Service role client must NEVER be used for user fetches (e.g., `getUser()`). Only for admin operations where bypassing RLS is intentional.

7. **Cache `no-store` on Supabase clients** (shared with queue rule)
   - Files: `src/lib/supabase/admin.ts`, `src/lib/supabase/server.ts`.
   - Must wrap `global.fetch` with `cache: 'no-store'`.

8. **Concurrent login invalidation fires on login**
   - File: `src/app/api/auth/login/route.ts`
   - After successful signin, must call `invalidateOldSessions(profileId, sessionToken)` to kick old devices.

### Data-level invariants

Run queries in `references/audit-queries.sql`. SELECT-only.

### Output template — MANDATORY Coverage Report

Every auth audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Auth Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: X/5 (auth_events, auth_lockouts, active_sessions, profiles, barbers)
- RLS policies found: X (expected ≥10) — list any gaps
- Triggers found: X (expected: trigger_update_auth_lockouts_updated_at)
- RPCs found: X/2 (cleanup_old_auth_events)
- Migrations confirmed: X/6 (015, 021, 025_fix_profiles_rls, 027, 031, 037)

### Findings
[Ranked critical/high/medium/low with file:line anchors]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (from SURFACE_INVENTORY.md sections 1-9) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/middleware.ts | PASS/FAIL/NOT-RUN | e.g. "middleware.ts:42 — cookie format `${user.id}:${role}` enforced" |
| 2 | src/app/api/auth/login/route.ts | | |
| ... | [all files through 42] | | |

Files audited with proof-of-read: N / 42 (target: 42/42). Any PASS without evidence = treated as NOT-RUN.

### Pillar 2 — Database (5 tables from inventory section 10)
| Table | Row count | Distribution | NULL violations | Verdict |
|---|---|---|---|---|
| auth_events | | by event_type | | |
| auth_lockouts | | locked_until > NOW count | | |
| active_sessions | | expires_at < NOW count | | |
| profiles | | first_login_completed dist | | |
| barbers (onboarding cols only) | | onboarding_step dist | | |

Tables audited: N / 5

### Pillar 3 — Queries (from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | [query name] | | |
| ... | [all queries] | | |

Queries run: N / total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (4 tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| auth_events | | 3 (owner-select, self-select, service-insert) | |
| auth_lockouts | | 3 (owner-select, owner-update, service-all) | |
| active_sessions | | 5 (owner-select, self-select, owner-delete, self-delete, service-all) | |
| profiles | | self + owner + PII-restricted | |

RLS tables audited: N / 4

### Pillar 5 — Integrations (inventory sections 11, 14, 15)
| Integration | Verdict | Note |
|---|---|---|
| Supabase Auth (magic link + password + JWT) | | |
| Resend barber invite email | | |
| Twilio barber invite SMS | | |
| Session keepalive (no cron) | | |
| cleanup_old_auth_events (manual/cron?) | | |
| Trigger: update_auth_lockouts_updated_at | | |

Integrations audited: N / 6

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| Login success → {lockout reset, invalidateOldSessions, createSession, auth_events, active_sessions, cookie rewrite} | YES/NO | |
| Login failure → {recordFailedAttempt, auth_lockouts, auth_events, owner_alerts spike} | YES/NO | |
| lockAccount → {auth_lockouts.locked_until, auth_events, owner_alerts, exponential backoff} | YES/NO | |
| create-barber → {auth.users + profiles + barbers + schedules + staff_status + email + SMS + rollback} | YES/NO | |
| resend-invite → {Supabase magic-link regeneration, auth_events, Resend, Twilio, email_verified unchanged} | YES/NO | |
| set-password → {auth.updateUser, email_verified=true, auth_events, onboarding_step init, session creation} | YES/NO | |
| middleware.getUserRole → {cookie format, JWT metadata, profiles.role fallback, no admin client, cache:no-store} | YES/NO | |
| middleware client-session → {HMAC verify, 7-day expiry, no Supabase overlap, /profile scoping} | YES/NO | |
| session/keepalive → {active_sessions.last_active, sliding expiry, no admin client} | YES/NO | |
| session/check + ConcurrentLoginModal → {session_token uniqueness, invalidate on login, polling cadence} | YES/NO | |
| force-logout* → {active_sessions DELETE, auth_events, cookie clear, owner role check} | YES/NO | |
| logout-device → {self-scope enforcement, RLS self-delete} | YES/NO | |
| invalidateOldSessions → {DELETE by profile_id excluding current token, admin client justified, no auth_events cascade} | YES/NO | |
| logAuthEvent → {auth_events INSERT, IP + UA + device_info, no raw tokens/passwords} | YES/NO | |
| auth_events writes → {RLS owner-select, self-select, service-insert, 90-day retention} | YES/NO | |
| auth_lockouts writes → {RLS owner-select, owner-update, service-all, updated_at trigger, pre-password check} | YES/NO | |
| barbers.profile_id FK → {profiles.role=barber, auth.users, staff_status, barber_schedules} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/lib/auth/client-session.ts] | Touches HMAC sign/verify — silent secret-leak risk | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Supabase Dashboard — magic-link TTL, Resend deliverability, Twilio SMS status): <list>.

If zero gaps: write "No gaps identified. All 65+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 65+ (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL AUTH AUDIT — N surfaces unaudited, M coupling violations" instead of "Auth Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for symptom. Examples:
   - "I logged in as owner but got routed to /barber"
   - "Real user is locked out even though credentials are correct"
   - "Staff login works but dashboard shows someone else's data briefly"
   - "Barber invite email never arrived"
   - "Concurrent login modal keeps popping up"
   - "Client session on /profile invalidates unexpectedly"

2. Match against `references/incidents.md`.

3. Three-file rule. Two-strike rule.

4. **Stay in scope.** Auth debugging can sprawl. If a bug seems to require touching commission, queue, or bookings code, STOP and explain why to user.

---

## Mode: scale-check

1. **Role enum expansion readiness**
   - Current roles: `owner`, `barber`, `student`, `client`.
   - Adding a new role (e.g., `manager`, `trainee`) requires:
     - DB: no schema change needed (role is VARCHAR)
     - Middleware: add route mapping in `src/middleware.ts` role routing logic
     - Auth context: add to `UserRole` TypeScript union
     - UI: add booleans (`isManager`, etc.) and conditional rendering

2. **Hardcoded role strings**
```bash
grep -rEn "=== ?'owner'|=== ?\"owner\"|=== ?'barber'|=== ?\"barber\"|=== ?'student'|=== ?\"student\"|=== ?'client'|=== ?\"client\"" src/
```
Flag anywhere role comparison happens inline instead of via a constant or enum. A `ROLES` constant in `src/lib/constants/` would be safer for scale.

3. **Middleware routing strategy**
   - File: `src/middleware.ts`
   - Current: if/else chain per role. For N roles, this grows linearly.
   - Flag as refactor candidate (route map pattern).

4. **Session table scale**
   - `active_sessions` grows with barber count + location count + device count.
   - Verify cleanup cron is active: `SELECT * FROM pg_cron.job WHERE jobname ILIKE '%session%'` (if pg_cron enabled) OR check Vercel cron calling `/api/auth/session/cleanup`.
   - Rate of growth: ~10 sessions/barber/day assumed. Monitor.

5. **Auth events volume**
   - `auth_events` grows every login, failed login, password reset.
   - At 100 barbers × 5 logins/day = 500 events/day. Annually ~180k rows. Not a scale issue yet, but flag if `WHERE created_at` queries slow.

## Mode: fix

The only mode that writes code. Closes the loop between "audit/diagnose found X" and "X is fixed + verified." Does NOT commit, does NOT push, does NOT touch the production DB. See `references/fix-patterns.md` for the canonical patterns.

### Activation is EXPLICIT

Fix mode fires ONLY when the user types one of:
- `apply pattern N` — N is a pattern number from `references/fix-patterns.md`
- `fix <symptom-phrase>` — natural-language form; the skill maps to a pattern and CONFIRMS before doing anything
- `enter fix mode` followed by a scope

Any other phrasing → audit/diagnose instead. An audit finding NEVER auto-triggers a fix.

### Workflow (strict — every step, no shortcuts)

1. **Scope declaration.** Restate in 1–2 sentences which pattern (number + name), which file(s) will change, any mirror-page impact.
2. **Preflight.** Read the target file. Confirm the "before" block from `fix-patterns.md → Pattern N` still matches current code — imports, function signatures, surrounding context, NOT line numbers (which drift). If drift → STOP and report what differs. Do NOT apply a stale pattern.
3. **Scope audit.** Confirm the fix touches ONLY files named in the pattern's Before/After blocks. If a fix would require touching an unrelated system → STOP and ask for approval before expanding.
4. **Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes` / `apply` / `proceed`. No implicit approval.
5. **Apply.** Single `Edit` call. ONE pattern per fix-mode invocation. Never bundled.
6. **Post-fix verification.** `npx tsc --noEmit` passes. Re-run the pattern's post-fix grep and/or SQL check — must pass. For UI patterns, explicitly tell the user "you must test this in the browser before shipping — I can't verify UI."
7. **Mirror check.** If the fix touches any page in the Cross-Dashboard Code Mirroring map (`.claude/rules/context-awareness.md`), invoke the `mirror-check` skill before handoff.
8. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/<domain>-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for any dashboard-touching fix. |
| `safe-query` | If a pattern requires DB writes (rare), route through safe-query. |

---

## Downstream Consumers & Propagation

Auth state (role, session, lockout) flows to every route via middleware. A stale cache = wrong-role routing. A missed invalidation = concurrent login modal loop.

### Consumers (every surface that reads auth data)

| Consumer | File / URL | What it reads |
|---|---|---|
| Middleware | `src/middleware.ts` | role from cookie/JWT/DB on every request |
| Auth context | `src/lib/auth/context.tsx` | user object for all dashboard pages |
| Role-based UI | every dashboard page using `useAuth` / `isOwner` / `isBarber` | conditional rendering |
| Session keepalive | client polling `/api/auth/session/keepalive` | refresh `last_active` |
| Concurrent login modal | realtime / polling on `active_sessions` | display kick-out modal |
| Lockout check | `src/app/api/auth/login/route.ts` | checks `auth_lockouts` before password |
| Owner session inspection | `src/app/(dashboard)/dashboard/auth-log/page.tsx` | auth_events + active_sessions |
| Barber invite flow | `src/app/api/auth/create-barber/route.ts` writes to profiles + barbers + schedules + staff_status (cascade) |

### Propagation invariants

1. **Cookie `mt-user-role` includes user-ID prefix** — `${user.id}:${role}`. Without the prefix, switching users on the same device can briefly show wrong role.
2. **`app_metadata.role` synced on every successful login** — tier 2 of resolution stays fresh.
3. **`invalidateOldSessions` called after every login** — enforces single-session per profile.
4. **`resetLockout` called on successful login** — clears failed-attempt counter.
5. **Admin client NEVER used for `getUser()`** — per 2026-03-06 incident, session pollution across requests.
6. **Supabase factories wrap `cache: 'no-store'`** — else stale user data between auth check and DB query.

### Diagnose: "Just logged in as owner but routed to barber dashboard"

1. Cookie: inspect `mt-user-role` cookie value. Does it start with current user's ID?
2. JWT: inspect `user.app_metadata.role`. Matches profiles.role?
3. DB: `SELECT role FROM profiles WHERE id = '...'`. Source of truth.
4. Middleware: read `getUserRole()` function. Does cookie-cache check compare user IDs?
5. If a prior user's cookie lingered → the cookie-cross-user-pollution fix may have regressed. Read `src/middleware.ts` lines 19-67.

### Diagnose: "Concurrent login modal keeps popping up"

1. `active_sessions` rows for this profile: `SELECT id, device_type, created_at, expires_at, last_active FROM active_sessions WHERE profile_id = '...' ORDER BY created_at DESC`
2. More than 1 row with `expires_at > now()` → `invalidateOldSessions` isn't firing.
3. Read `src/lib/auth/session-tracker.ts` to verify the function is called after successful login.
4. If called but failing → check for silent error swallowing.

---

## HARD RULES

- NEVER write to production DB.
- NEVER test on real barber accounts. Use dev owner (`dev@mtbarbershop.com`) or test barbers (`b0020000…`, `b0030000…`, `b0040000…`).
- NEVER log raw passwords, service role keys, or session tokens.
- NEVER use admin (service role) client for user-facing `getUser()` — see 2026-03-06 incident.
- NEVER remove or weaken the lockout mechanism. 10 attempts / 5 min is the rule.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Stay in scope.
