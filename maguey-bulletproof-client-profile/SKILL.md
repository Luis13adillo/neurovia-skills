---
name: maguey-bulletproof-client-profile
description: Audit, diagnose, or scale-check the Maguey Nightclub client profile surface — customer self-service (Profile.tsx, Account.tsx 631 lines, AccountSettings.tsx, useAuthProfile.ts, AvatarUpload, TwoFactorSetup, VerifyEmail, ticket transfer UI) plus staff-facing CustomerManagement.tsx. The customer identity model is auth.users + order/ticket history (no separate profiles extension table in production). Use when avatar uploads break, 2FA setup fails, ticket history shows wrong data, email-change doesn't take effect, account deletion is requested, or customers report privacy issues. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB. Flags KNOWN GAPS every audit: production DB has no `profiles` / `user_loyalty` / `user_devices` / `referrals` / `magic_links` / `login_activity` / `customer_stats` — any UI code depending on them is dead-code until migrations deploy. TOTP not actually verified (only backup codes checked). Refunded tickets show as upcoming. Avatar files orphan on re-upload. Account deletion not implemented.
---

# Maguey Bulletproof Client Profile

The client profile is the customer's self-service home: where they see their tickets, edit their details, manage 2FA, and trust that their data is under control. Breakages here rarely lose a sale directly — but they cost trust.

## Schema Reality Check (verified 2026-04-21 against live DB)

This is the most important section. On 2026-04-21 I queried the live DB — many tables the original draft of this skill depended on **don't exist in production**. Code may reference them via migrations that exist in `maguey-pass-lounge/supabase/migrations/` but haven't been applied to the live project (`djbzjasdrwvbsoifxqzd`).

**Tables that DO NOT exist in the live DB:**
- `profiles` — extended customer profile (first_name, last_name, avatar_url, phone, DOB, 2FA fields)
- `user_loyalty` — points/credits/tier/totals
- `user_devices` — WebAuthn credentials
- `referrals` — referral rewards
- `magic_links` — passwordless tokens
- `login_activity` — auth audit trail
- `organizer_profiles` — event organizer accounts

**Views that DO NOT exist:**
- `customer_stats` — the aggregate view `CustomerManagement.tsx` queries

**RPCs that DO NOT exist:**
- `get_customer_visit_count(email)`

**What this means:**
- Any code path that reads/writes these tables will 500 in production.
- Any audit finding based on "query the profiles table" is currently unanswerable.
- The migration files for these tables live at `maguey-pass-lounge/supabase/migrations/20250320000000_auth_enhancements.sql`, `20250303000002_create_user_loyalty.sql`, `maguey-gate-scanner/supabase/migrations/20260401000001_customer_stats_view.sql`. They exist as plans, not as deployed schema.
- If the user intends to ship the customer account features described by `useAuthProfile.ts` etc., those migrations need `supabase db push` first. That's a WRITE operation and out of this skill's scope — delegate to `maguey-bulletproof-ship`.

**What actually exists and is live for customer identity:**
- `auth.users` (Supabase-managed) — id, email, email_confirmed_at, last_sign_in_at, user_metadata jsonb, app_metadata jsonb
- `orders` — id, user_id (uuid), purchaser_email (text), purchaser_name, event_id, subtotal, fees_total, total, payment_provider, payment_reference, status, metadata (jsonb), promo_code_id, created_at, updated_at
- `tickets` — linked to orders; customer-visible via `attendee_email` RLS filter
- `ticket_transfers` — transfer audit trail

**Existing customer-facing RLS:**
- `orders` policy "Users can view own orders or staff can view all" (public role, keys on purchaser_email JWT claim + staff role)
- `tickets` policies allow anon INSERT (guest checkout) + authenticated/public SELECT with same JWT-email gating

---

## Covered files

Customer-facing (maguey-pass-lounge):
- `src/pages/Profile.tsx` (241) — name/phone/DOB form + avatar UI. **Depends on missing `profiles` table** — forms submit against a table that does not exist. Flag as dead-code in every audit until migrations deploy.
- `src/pages/Account.tsx` (631) — ticket history, VIP reservations, transfers, upcoming/past events. Reads `tickets` + `orders` + `ticket_transfers` — these DO exist, so this page actually functions.
- `src/pages/AccountSettings.tsx` (189) — 2FA toggle, biometric, activity log, delete account (stub). **All features depend on missing tables.**
- `src/hooks/useAuthProfile.ts` (234) — updateProfile/uploadAvatar etc. Writes against `profiles` (missing) + `avatars` storage bucket (check if bucket exists).
- `src/hooks/useAuthMethods.ts` (~350) — enable2FA/verify2FA. Writes against `profiles` (missing).
- `src/pages/TwoFactorSetup.tsx` (218), `VerifyEmail.tsx` (149), `components/auth/AvatarUpload.tsx` (201)
- `src/lib/orders/user-tickets.ts` (~185) — fetches customer's tickets. Runs against `tickets` table (exists).
- `src/lib/ticket-transfer-service.ts` (~77) — transfer flow. Runs against `ticket_transfers` (exists).

Staff-facing (maguey-gate-scanner):
- `src/pages/CustomerManagement.tsx` (490) — **depends on missing `customer_stats` view**. Until deployed, this page 500s or shows empty.

**Not covered here:**
- Auth session/login flows → `maguey-bulletproof-auth`
- Ticket purchase/inventory → `maguey-bulletproof-tickets`
- VIP reservations → `maguey-bulletproof-vip`
- Email delivery → `maguey-bulletproof-email`

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md`.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md`.
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

**BEFORE running any audit query**, re-verify the Schema Reality Check — schema drifts. If the migrations have since deployed, update this file and remove the "dead code" flags for affected features.

```sql
-- Quick schema re-check (run first):
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('profiles','user_loyalty','user_devices','referrals','magic_links','login_activity','customer_stats');
-- If this returns rows for any of them, that table now exists and the skill's flags for it can be lifted.
```

Confirm "Preflight complete. Running [mode]." Supabase: `mcp__supabase__execute_sql` project `djbzjasdrwvbsoifxqzd`. Read-only.

---

## KNOWN GAPS — flag every audit, until fixed

### Schema-level (the big ones)
1. **Profile infrastructure migration not deployed** — `profiles`, `user_loyalty`, `user_devices`, `referrals`, `magic_links`, `login_activity` tables + `customer_stats` view + `get_customer_visit_count` RPC are all missing from the live DB. Any feature that depends on them is dead in production. Decision needed: deploy the migration, or remove the UI features (Profile.tsx, AccountSettings.tsx 2FA panel, CustomerManagement.tsx).

### Security / trust (will apply once migration lands)
2. **TOTP verification not actually implemented.** `useAuthMethods.ts verify2FA()` only checks entered code against `backup_codes` array. The TOTP from the authenticator app is never validated against `profiles.two_factor_secret`. An attacker with ANY backup code bypasses 2FA. Code comment even says TODO.
3. **2FA secret + backup codes stored PLAINTEXT** (when/if the `profiles` migration deploys). `two_factor_secret` and `backup_codes` TEXT[] unencrypted. DB-read leak = full 2FA bypass. Encrypt secret via Supabase Vault; hash backup codes with bcrypt/argon2.
4. **No rate limit on 2FA verification** — 6-digit code = 1M combos, brute-forceable.

### GDPR
5. **Account deletion is a stub** — `AccountSettings.tsx handleDeleteAccount()` returns a toast-error. Non-compliant with EU/CA right-to-delete.
6. **No data export endpoint** — non-compliant with GDPR Article 15/20.

### Customer-visible bugs (tickets/orders are live, so these are actively hitting customers)
7. **Refunded tickets show as upcoming.** `user-tickets.ts` does NOT filter `status IN ('refunded','cancelled')`. Customer sees a ticket for an event they got refunded from. Fix: add `.not('status', 'in', '("refunded","cancelled")')` to the query. Highest-impact production-visible bug in this skill.
8. **RESOLVED 2026-04-21** — Ticket transfer previously removed state optimistically; `Account.tsx handleTransfer` now awaits `transferTicket()` and only mutates `setTickets` after the `!result.success` early-return guard. Prior concern obsolete. (The network-drop-mid-request edge case — server succeeded but client never received the response — still exists, but falls under "transient network failure recovery" rather than "optimistic state removal" and is documented separately in `references/incidents.md`.)
9. **Email change shows new email optimistically** before confirmation link clicked. Display drift until session refresh.

### Operational (when the migration deploys)
10. **`get_customer_visit_count()` uses SECURITY DEFINER** (per migration code). Re-audit body carefully when migration lands.
11. **`CustomerManagement.tsx` has no pagination** — will OOM the browser once customer count grows and the `customer_stats` view actually returns rows.
12. **Avatar file orphaning** (when `avatars` bucket is provisioned): `uploadAvatar()` upserts `{user.id}/{timestamp}.ext` but never deletes prior files.

---

## Choose a Mode

- **audit** → weekly; focuses on the 3 live-and-broken gaps (#7, #8, #9) plus schema drift check
- **diagnose** → specific customer complaint
- **scale-check** → before the profile-migration deploy (infer what to fix BEFORE shipping it)

---

## Mode: audit

### Code-level invariants

1. **Refunded tickets filtered out of the user's ticket history**
   - File: `maguey-pass-lounge/src/lib/orders/user-tickets.ts`
   - Must exclude `status IN ('refunded','cancelled')` from the returned list.
   - Grep: `grep -n "status.*refunded\|not.*refunded\|neq.*refunded\|status.*in" maguey-pass-lounge/src/lib/orders/user-tickets.ts`
   - KNOWN GAP until fixed.

2. **Ticket transfer awaits server before state removal**
   - File: `maguey-pass-lounge/src/pages/Account.tsx`
   - In the transfer handler, `setTickets(prev => prev.filter(...))` MUST come AFTER the `await transferTicket(...)` call succeeds.
   - PASS (verified 2026-04-21): `handleTransfer` at `Account.tsx:129-169` awaits the call, and the `setTickets(...)` filter at line 151 runs only after the `!result.success` early-return guard at line 145.

3. **Email change UI reflects pending state**
   - File: `maguey-pass-lounge/src/pages/Profile.tsx`
   - After `updateEmail(new)` the UI should show "pending confirmation — check {new_email}" and continue to display `auth.users.email` until `email_confirmed_at` flips.

4. **No direct `from('profiles').update(...)` or `from('user_loyalty').*` from components**
   - Grep: `grep -rn "from.*'profiles'\|from.*'user_loyalty'" maguey-pass-lounge/src`
   - Until the migration deploys, any match is dead code that will 500 for the customer.

5. **ProtectedRoute wraps every profile page**
   - `/profile`, `/account`, `/settings`, `/2fa/setup`, `/verify-email` all inside `<ProtectedRoute>`
   - Grep: `grep -n "Profile\|Account\|Settings\|TwoFactor\|VerifyEmail" maguey-pass-lounge/src/App.tsx` + verify wrapper

6. **Data minimization in selects**
   - Client code must NEVER `select('*')` from `profiles` (it would expose `two_factor_secret`/`backup_codes`).
   - Relevant only after migration deploys.

### Data-level invariants

Run `references/audit-queries.sql` — most queries guard with a schema check and SKIP if the table is missing.

### Audit output template

```
## Client Profile Audit Report — [YYYY-MM-DD]

### Schema Reality (re-verify)
- [DEPLOYED / NOT-DEPLOYED] profiles
- [DEPLOYED / NOT-DEPLOYED] user_loyalty
- [DEPLOYED / NOT-DEPLOYED] user_devices
- [DEPLOYED / NOT-DEPLOYED] referrals
- [DEPLOYED / NOT-DEPLOYED] magic_links
- [DEPLOYED / NOT-DEPLOYED] login_activity
- [DEPLOYED / NOT-DEPLOYED] customer_stats (view)
- [DEPLOYED / NOT-DEPLOYED] get_customer_visit_count (RPC)

### KNOWN GAPS (persistent)
- [OPEN/CLOSED] Refunded tickets shown as upcoming (live-production bug)
- [OPEN/CLOSED] Email change UI no pending state (live-production bug)
- [OPEN/CLOSED] Profile infrastructure migration not deployed
- [OPEN/CLOSED] TOTP not verified vs secret (applicable after migration)
- [OPEN/CLOSED] 2FA secret + backup codes plaintext (applicable after migration)
- [OPEN/CLOSED] Account deletion unimplemented (GDPR)
- [OPEN/CLOSED] No data export endpoint (GDPR)
- [OPEN/CLOSED] Avatar files orphan (applicable once avatars bucket used)
- [OPEN/CLOSED] CustomerManagement no pagination (applicable after migration)
- [OPEN/CLOSED] No rate limit on 2FA verification (applicable after migration)

### Code-level
- [PASS/FAIL] Refunded tickets filter in user-tickets.ts
- [PASS/FAIL] Transfer awaits server
- [PASS/FAIL] Email change pending UI
- [PASS/FAIL] ProtectedRoute on all profile routes
- [PASS/FAIL] No client-side writes to missing tables (0 matches, OR matches all flagged as dead code)

### Data-level
- [PASS/FAIL] No tickets shown where status=refunded (query #1 — live)
- [N/A or PASS/FAIL] profiles RLS intact (query #2 — skip if table missing)
- [PASS/FAIL] No orphan ticket_transfers (query #3 — live)
- [N/A or PASS/FAIL] customer_stats sanity (skip if view missing)

### Failures + Known Gaps
[List]
```

---

## Mode: diagnose

### Step 1: Ask
- Customer email / user_id?
- Symptom? (ticket history wrong, avatar won't load, email change stuck, CustomerManagement blank, "Delete Account" button errors)
- Page/flow?

### Step 2: Simple checks
```sql
-- Does the user exist?
SELECT id, email, email_confirmed_at, last_sign_in_at, user_metadata
FROM auth.users WHERE email = '<email>';

-- What tickets do they see (roughly — same query user-tickets.ts runs):
SELECT t.id, t.status, t.event_id, e.name AS event_name, e.event_date,
       t.qr_token IS NOT NULL AS has_qr
FROM tickets t LEFT JOIN events e ON e.id = t.event_id
WHERE t.attendee_email = '<email>'
ORDER BY t.issued_at DESC NULLS LAST LIMIT 20;

-- Orders:
SELECT id, status, total, payment_reference, created_at
FROM orders WHERE purchaser_email = '<email>' ORDER BY created_at DESC LIMIT 5;
```

### Step 3: Match against incidents (see `references/incidents.md`)
- "Ticket history shows an event I got refunded for" → KNOWN GAP; add the status filter in `user-tickets.ts`.
- "I transferred a ticket, it's gone but recipient never got it" → transfer race (KNOWN GAP).
- "Customer management page is blank/errors" → `customer_stats` view not deployed. Delegate to ship skill.
- "Delete account button errors" → unimplemented stub.
- "Avatar upload errors / nothing happens" → avatars bucket may not exist; `profiles.avatar_url` column doesn't exist until migration deploys.
- "2FA setup fails / I can't toggle 2FA" → `profiles` table missing; feature is dead.

### Step 4-6: 3-file rule, Two-strike rule, stay in scope.

---

## Mode: scale-check

If the user is preparing to deploy the profile-infrastructure migration, run this BEFORE `supabase db push`:

### 1. Migration dry-run
- Read the migration files list in MEMORY.md — especially `20250320000000_auth_enhancements.sql`, `20250303000002_create_user_loyalty.sql`, `20260401000001_customer_stats_view.sql`.
- Test them against a branch database or staging first. They CASCADE to auth.users (via FK); if any existing auth.users have corrupted data, migration fails mid-flight.

### 2. Backfill plan
- Existing customers have rows in `auth.users` but NONE in `profiles`. On first profile load the app must upsert a `profiles` row — is that logic present? If not, users see the form empty and editing creates the row.

### 3. Avatar bucket
- Does the `avatars` bucket exist in Supabase Storage? Check Dashboard. Create if missing BEFORE the Profile.tsx UI is re-enabled.

### 4. 2FA rollout phasing
- See `incidents.md` "2FA migration plan" — don't just flip a switch. Phased rollout (add TOTP check while preserving backup codes, migrate secrets to encrypted storage, hash backup codes, THEN drop legacy) is required to avoid locking out users.

### 5. customer_stats RLS
- The migration creates a VIEW with GRANT SELECT to authenticated. Verify staff RLS still gates who sees customer PII. `get_customer_visit_count` is SECURITY DEFINER — audit the body.

### Output

```
## Client Profile Scale Readiness (pre-migration-deploy)

### Migration files staged: [list]
### Branch DB test: [PASS/FAIL]
### Backfill plan: [present? / missing]
### avatars bucket: [EXISTS / MISSING]
### 2FA rollout plan reviewed: [YES / NO]
### customer_stats RLS verified: [YES / NO]

### Verdict: [READY / NOT READY]
```

---

## Critical Flows (current, with dead-feature flags)

### FLOW A: Customer views tickets — WORKS
1. `/account` fetches via `getUserTickets(email, userId)` → queries `tickets` table directly (bypasses orders RLS by design).
2. Filter: `attendee_email = <JWT email>`.
3. Join: events (name/date), ticket_types (category).
4. **GAP:** no status filter → refunded tickets leak in.

### FLOW B: Ticket transfer — WORKS
1. Client calls `transferTicket` Edge Function.
2. Edge Function regenerates QR (new token + signature), issues new ticket, invalidates old.
3. Transfer emails enqueued (types `ticket_transfer_received`, `ticket_transfer_sent` — both in the `email_queue` CHECK constraint).
4. Client removes the ticket from state only after the awaited server call returns `success: true` (verified `Account.tsx handleTransfer`, 2026-04-21). Network-drop-mid-response is still a latent edge case — see `incidents.md` for recovery path.

### FLOW C: Profile edit — DEAD until `profiles` migration deploys
### FLOW D: Avatar upload — DEAD until `profiles.avatar_url` + `avatars` bucket exist
### FLOW E: 2FA setup — DEAD until `profiles.two_factor_*` columns exist
### FLOW F: Staff customer intelligence — DEAD until `customer_stats` view + `get_customer_visit_count` RPC deploy

---

## HARD RULES

- **NEVER write to prod DB.** Read-only via MCP.
- **NEVER propose a UI fix for a feature whose backing table doesn't exist yet.** Fix the migration first (via `maguey-bulletproof-ship`), or document the feature as disabled.
- **NEVER manually edit `auth.users.email` or `email_confirmed_at`.** Always through Supabase Auth flows.
- **NEVER expose `profiles.two_factor_secret` or `backup_codes` in any client-bound SELECT** (once the migration deploys).
- **NEVER ship the 2FA fix without phased rollout** — existing users' secrets are stored; a hot cutover locks them all out.
- **Branch workflow:** fix/... or feature/... branches.
- **User reports override queries.** "My ticket disappeared after transfer" → trust that; look at `ticket_transfers` + the Edge Function response.

---

## What to Return

- **audit** → schema-reality + KNOWN GAPS + live-bugs pass/fail
- **diagnose** → minimal repro + one-file fix or "need direction"
- **scale-check** → ready/not-ready pre-migration-deploy
