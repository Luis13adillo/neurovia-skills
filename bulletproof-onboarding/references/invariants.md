# Onboarding Invariants

An invariant is a statement that MUST be true at all times. If a query returns a violation, you have a bug. These are the assertions that protect the onboarding funnel's correctness.

Each invariant has a severity:
- **CRITICAL** — barber is blocked from work, legal/compliance exposure, or silent revenue leakage
- **HIGH** — funnel step produces wrong outcome but doesn't block work directly
- **MEDIUM** — state inconsistency that may not be user-visible immediately
- **LOW** — hygiene (orphan rows, stale test data, cosmetic drift)

All SQL is SELECT-only. Run via `mcp__supabase-mt__execute_sql`. Never INSERT / UPDATE / DELETE. For writes, follow Section 9 of `debugging-protocol.md` — state exact rows, wait for explicit approval.

---

## Data-level invariants

### 1. `onboarding_step` is NULL or 1..7 [CRITICAL]
Step values must be NULL (done / never started) or in the canonical range. Anything else = corruption. The wizard clamps to 1..7 on read (setup/page.tsx line 138-139) but a bad value written by SQL or a future API bug re-lands the user on Step 1, silently losing progress.
```sql
SELECT id, first_name, last_name, onboarding_step
FROM barbers
WHERE onboarding_step IS NOT NULL
  AND (onboarding_step < 1 OR onboarding_step > 7);
-- Expected: 0 rows
-- Same as Query 17 in audit-queries.sql
```

### 2. Wizard-complete state is internally consistent [CRITICAL]
If `commission_acknowledged_at IS NOT NULL`, the acknowledge-commission route guarantees `onboarding_step = NULL` AND `first_login_completed = true`. Violations mean either the route skipped a write, or someone edited DB state directly.
```sql
SELECT b.id, p.first_login_completed, b.commission_acknowledged_at, b.onboarding_step
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.commission_acknowledged_at IS NOT NULL
  AND (b.onboarding_step IS NOT NULL OR p.first_login_completed = false);
-- Expected: 0 rows
-- Same as Query 18 in audit-queries.sql
```

### 3. Every `barbers.profile_id` points to a real `profiles` row [CRITICAL]
Orphaned barbers = cascade rollback broke somewhere. They show up as "Unknown" in dashboards and can't log in because their auth user is also missing.
```sql
SELECT b.id, b.first_name, b.last_name, b.profile_id, b.created_at
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE p.id IS NULL
ORDER BY b.created_at DESC;
-- Expected: 0 rows (Query 16b in audit-queries.sql)
```

### 4. Every barber-role profile has a `barbers` row [CRITICAL]
Mirror of invariant #3. If `profiles.role = 'barber'` but no `barbers` row exists, the middleware routes them to `/barber` where every API call 404s. Indicates partial insert in `create-barber` without cascade cleanup.
```sql
SELECT p.id, p.email, p.created_at
FROM profiles p
LEFT JOIN barbers b ON b.profile_id = p.id
WHERE p.role = 'barber'
  AND b.id IS NULL
ORDER BY p.created_at DESC;
-- Expected: 0 rows (Query 16a in audit-queries.sql)
```

### 5. `first_login_completed` is one-way true [CRITICAL]
Only `/api/barber/acknowledge-commission` sets this to true. Nothing should set it back to false on an already-completed barber — that would trap them in the wizard permanently.
```sql
-- Detection: profile flipped true → false is not directly queryable without audit log,
-- but we can check for logical contradictions as a proxy:
SELECT b.id, p.first_login_completed, b.commission_acknowledged_at, b.onboarding_step, p.email
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE p.first_login_completed = false
  AND b.commission_acknowledged_at IS NOT NULL;
-- Expected: 0 rows (commission_acknowledged_at is immutable evidence they completed)
```

### 6. Active barbers have at least one schedule row [HIGH]
Without it, availability API returns empty and fair rotation silently excludes them. Customers see them on `/team` but can't book. See also `bulletproof-schedules`.
```sql
SELECT b.id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                p.email) AS name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND NOT EXISTS (
    SELECT 1 FROM barber_schedules s
    WHERE s.barber_id = b.id AND s.is_active = true
  )
ORDER BY b.created_at DESC;
-- Expected: 0 rows (Query 8 in audit-queries.sql)
```

### 7. Active barbers have at least one service [HIGH]
Either global (`barber_services`) or custom (`barber_custom_services`). Without either, the barber is invisible in the booking flow's Step 3 (Service). Can happen if Step 3 of the wizard was bypassed by a manual DB edit.
```sql
SELECT b.id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                p.email) AS name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND NOT EXISTS (SELECT 1 FROM barber_services bs WHERE bs.barber_id = b.id)
  AND NOT EXISTS (SELECT 1 FROM barber_custom_services bcs
                  WHERE bcs.barber_id = b.id AND bcs.is_active = true)
ORDER BY b.created_at DESC;
-- Expected: 0 rows (Query 9 in audit-queries.sql)
```

### 8. Grace-period consistency [HIGH]
When `commission_acknowledged_at` is set, `grace_period_ends_at` must also be set (acknowledge-commission sets both atomically). A barber with ack but no grace-period end is in an ambiguous state for `bulletproof-commission` waiver rules.
```sql
SELECT id, first_name, last_name, commission_acknowledged_at, grace_period_ends_at
FROM barbers
WHERE commission_acknowledged_at IS NOT NULL
  AND grace_period_ends_at IS NULL;
-- Expected: 0 rows
```

### 9. Stripe split-state coherence [HIGH]
`stripe_charges_enabled = true` requires `stripe_account_id IS NOT NULL`. The reverse is not an invariant (Connect can be started but not finished). This check catches data that would cause commission routing to misfire — sending a payout to an `account_id` that doesn't exist.
```sql
SELECT id, first_name, last_name, stripe_account_id, stripe_charges_enabled
FROM barbers
WHERE COALESCE(stripe_charges_enabled, false) = true
  AND stripe_account_id IS NULL;
-- Expected: 0 rows
```

### 10. Every active barber has a `staff_status` row [MEDIUM]
`create-barber` inserts this at line 250-263; the insert is non-fatal, so failures leak orphans. Active barbers without a staff_status row can't clock in, appear in the queue manager, or transition through `transition_staff_status`.
```sql
SELECT b.id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                'Unknown') AS name
FROM barbers b
WHERE b.is_active = true
  AND NOT EXISTS (SELECT 1 FROM staff_status ss WHERE ss.barber_id = b.id)
ORDER BY b.created_at DESC;
-- Expected: 0 rows (Query 16c in audit-queries.sql)
```

### 11. Public-visible barbers are fully onboarded [MEDIUM]
The public team page filter is `is_active=true AND onboarding_step IS NULL AND first_login_completed=true`. Any barber visible to customers while still in the wizard = misfire. Verify by cross-checking `is_active=true` barbers against funnel state.
```sql
SELECT b.id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                p.email) AS name,
       b.onboarding_step,
       p.first_login_completed
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND (b.onboarding_step IS NOT NULL OR p.first_login_completed = false);
-- Expected rows: ONLY legacy active barbers (ack_at IS NULL), which is a deliberate state.
-- Any barber with onboarding_step IS NOT NULL AND is_active=true = bug (they're mid-wizard but public).
```

### 12. Barber slug uniqueness [MEDIUM]
`create-barber` auto-generates slug with count-suffix fallback (lines 200-208). Collisions indicate the suffix logic broke.
```sql
SELECT slug, COUNT(*) AS n, array_agg(id) AS barber_ids
FROM barbers
WHERE slug IS NOT NULL
GROUP BY slug
HAVING COUNT(*) > 1;
-- Expected: 0 rows (Query 19 in audit-queries.sql)
```

### 13. Legacy barbers are intentional, not accidental [MEDIUM]
Pre-2026-03-20 barbers are allowed to have `is_active=true AND first_login_completed=true AND commission_acknowledged_at IS NULL` (the "legacy active" state). But a barber created AFTER 2026-03-20 in this state means the acknowledge-commission route failed silently.
```sql
SELECT b.id, b.created_at::date,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                p.email) AS name
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.is_active = true
  AND b.onboarding_step IS NULL
  AND b.commission_acknowledged_at IS NULL
  AND b.created_at > '2026-03-20'::date;
-- Expected: 0 rows. Legitimate legacy barbers all pre-date that line.
```

### 14. `preferred_location_id` points to a real location [MEDIUM]
```sql
SELECT b.id, b.preferred_location_id
FROM barbers b
LEFT JOIN locations l ON l.id = b.preferred_location_id
WHERE b.preferred_location_id IS NOT NULL
  AND l.id IS NULL;
-- Expected: 0 rows
```

### 15. Push subscriptions belong to real barber profiles [MEDIUM]
Orphan push subscriptions burn web-push delivery attempts against endpoints that can't be used. See `bulletproof-push-notifications` for the delivery-side invariants.
```sql
SELECT ps.id, ps.user_id, ps.created_at
FROM push_subscriptions ps
LEFT JOIN profiles p ON p.id = ps.user_id
WHERE p.id IS NULL
   OR p.role NOT IN ('barber', 'owner', 'client');
-- Expected: 0 rows (0 for test-account filtering, inspect manually if >0)
```

### 16. Test barber accounts are never publicly visible [HIGH]
Same rule as every other audit skill. Test barbers (`a274e1cf...`, `b0020000...`, `b0030000...`, `b0040000...`) must have `is_active = false`. If any flip to true, they show on `/team`, the booking flow, and /`queue` — contaminating the experience for real customers.
```sql
SELECT id, first_name, last_name, is_active
FROM barbers
WHERE id IN (
  'a274e1cf-955a-46f1-bc4c-dcd06a0510af',
  'b0020000-0000-0000-0000-000000000002',
  'b0030000-0000-0000-0000-000000000003',
  'b0040000-0000-0000-0000-000000000004'
)
AND is_active = true;
-- Expected: 0 rows
```

### 17. Invite delivery log is not building up failures [LOW]
Soft check — if many recent `role='barber'` profiles have `last_login_at IS NULL` after 48+ hours, the invite delivery pipeline is leaking (email bounced, SMS failed silently, magic link expired).
```sql
SELECT p.id, p.email, p.created_at, b.onboarding_step
FROM profiles p
LEFT JOIN barbers b ON b.profile_id = p.id
WHERE p.role = 'barber'
  AND p.last_login_at IS NULL
  AND p.created_at < NOW() - INTERVAL '48 hours'
  AND b.is_active = true
ORDER BY p.created_at DESC
LIMIT 20;
-- Expected: few or none. Investigate if >5. Resend invite via /api/auth/resend-invite.
```

### 18. `onboarding_step_updated_at` moves when `onboarding_step` moves [LOW]
Soft check — the timestamp should track wizard activity. A barber with `onboarding_step = 5` but `onboarding_step_updated_at` weeks old + `profiles.last_login_at` recent means they're logging in past the wizard guard somehow (or the PATCH `/api/barber/onboarding-step` call silently failed).
```sql
SELECT b.id,
       COALESCE(NULLIF(TRIM(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, '')), ''),
                p.email) AS name,
       b.onboarding_step,
       b.onboarding_step_updated_at,
       p.last_login_at
FROM barbers b
LEFT JOIN profiles p ON p.id = b.profile_id
WHERE b.onboarding_step IS NOT NULL
  AND b.is_active = true
  AND p.last_login_at > b.onboarding_step_updated_at + INTERVAL '7 days'
ORDER BY p.last_login_at DESC;
-- Expected: few rows. Investigate each — saveStep() toast-on-fail is a latent gap.
```

---

## Code-level invariants (verify via Read / Grep, not SQL)

### C1. Wizard guard intact [CRITICAL]
File: [src/app/(dashboard)/barber/setup/page.tsx:99-164](src/app/(dashboard)/barber/setup/page.tsx).
Must redirect owner → `/dashboard`, client → `/`, and barber with `first_login_completed=true AND onboarding_step IS NULL` → `/barber`. The 5-second fetch timeout (line 133) is the safety valve.

**Failure mode:** if the guard is weakened (e.g., "let them through if auth fetches", or default fall-through without role check), a barber lands on `/barber` without completed setup → empty dashboard, no schedule, no services → looks broken.

### C2. Step persistence on every transition [CRITICAL]
File: [src/app/(dashboard)/barber/setup/page.tsx:87-97](src/app/(dashboard)/barber/setup/page.tsx) `saveStep()`.
Every step change must PATCH `/api/barber/onboarding-step` with the new number. Currently toasts silently on failure — that's a known UX gap, not an invariant violation, but the PATCH itself must not be removed.

### C3. Acknowledge-commission writes all three fields atomically [CRITICAL]
File: [src/app/api/barber/acknowledge-commission/route.ts](src/app/api/barber/acknowledge-commission/route.ts).
Must set: `commission_acknowledged_at = NOW()`, `grace_period_ends_at = NOW() + 30 days`, `onboarding_step = NULL`, `profiles.first_login_completed = true`. All four in one transaction — otherwise the state can be torn (invariant #2 violation).

**Idempotency check:** re-calling the route for an already-acknowledged barber must NOT reset `grace_period_ends_at`. Legacy ack backfill depends on idempotency.

### C4. Cascade rollback on create-barber failure [CRITICAL]
File: [src/app/api/auth/create-barber/route.ts:347-411](src/app/api/auth/create-barber/route.ts).
On any failure after `auth.users` creation, catch must reverse-delete in FK-respecting order: staff_status → barber_schedules → barbers → profiles → auth.users. Skipping a layer produces invariant #3, #4, or #10 violations.

Grep check:
```bash
grep -n "admin.auth.admin.deleteUser\|from('profiles').delete\|from('barbers').delete\|from('barber_schedules').delete\|from('staff_status').delete" src/app/api/auth/create-barber/route.ts
```
Expect at least one reverse-cascade DELETE for each of the 5 tables.

### C5. Magic-link type is `'magiclink'`, not `'invite'` [CRITICAL]
File: [src/app/api/auth/create-barber/route.ts:273-280](src/app/api/auth/create-barber/route.ts).
The existing code generates `'magiclink'` type — comment at line 270-272 explains why. If someone changes to `'invite'`, links break for users created via `createUser` (Supabase quirk).

Grep check:
```bash
grep -n "type: 'invite'\|type: \"invite\"" src/app/api/auth/create-barber/route.ts
```
Expected: 0 matches.

### C6. `onboarding-step` API clamps 1..7 [HIGH]
File: [src/app/api/barber/onboarding-step/route.ts](src/app/api/barber/onboarding-step/route.ts).
Body validation must reject step < 1 or > 7. Otherwise invariant #1 gets violated by a bad client.

### C7. Commission-ack guard on public surfaces [HIGH]
The public team page (`src/app/(public)/team/page.tsx` or equivalent) filter must combine `is_active=true AND onboarding_step IS NULL AND first_login_completed=true`. A narrower filter (e.g., just `is_active=true`) leaks mid-wizard barbers onto the public site.

Grep check:
```bash
grep -rn "from('barbers')" src/app/\(public\)/
```
Review each result for the correct filter combination.

### C8. Invite email template matches actual wizard [MEDIUM]
File: [src/lib/email/templates.ts](src/lib/email/templates.ts) → `barberInviteEmail()`.
Currently advertises "4 setup steps" (photo, bio, services, schedule). Wizard has 7. This is documented drift — not a bug per se, but a trust-eroding UX gap. If you update the wizard's step count, update this template in the same PR.

SMS template: [src/lib/twilio/sms.ts](src/lib/twilio/sms.ts) → `BarberSMS.sendInviteNotification`.

### C9. PWA + push prompts live in owner-routed areas [HIGH, LATENT]
Components: `src/components/ui/PwaInstallPrompt.tsx`, `src/components/queue/NotificationPrompt.tsx`, `src/components/barber/SetupStatusBanner.tsx`.

Grep check:
```bash
grep -rn "PwaInstallPrompt\|NotificationPrompt\|SetupStatusBanner" \
  src/app/\(dashboard\)/barber/ \
  src/app/\(dashboard\)/dashboard/my-chair/
```
As of 2026-04-20: prompts mount on public queue pages only. Post-Phase-2 of `feature/onboarding-gap-1-pwa-install-schema`, a `/barber/install` page mounts `PwaInstallPrompt`. Post-Phase-3, `SetupStatusBanner` mounts on both `/barber` and `/dashboard/my-chair` per the Cross-Dashboard Code Mirroring rule.

**Current reality-check:** `/barber/install` does NOT exist yet (verified 2026-04-21). Grep above returns zero matches inside `(dashboard)/barber/**` — this is the known 17% push-enrollment baseline.

### C10. Cross-dashboard mirror parity for onboarding UI [HIGH]
Per `.claude/rules/context-awareness.md`, any onboarding-related nudge (`SetupStatusBanner`, `LegacyCommissionAckModal`, install prompts) added to `/barber/**` must also mount on `/dashboard/my-chair/**`. The owner is a barber too — if only the barber path gets the nudges, the owner misses commission-ack or push-enrollment prompts.

### C11. No PII in onboarding logs [MEDIUM]
Grep check:
```bash
grep -n "console.log" \
  src/app/api/auth/create-barber/route.ts \
  src/app/api/auth/resend-invite/route.ts \
  src/app/api/barber/onboarding-step/route.ts \
  src/app/\(dashboard\)/barber/setup/page.tsx
```
Each `console.log` must NOT include: full phone numbers, magic-link tokens (`hashed_token`, `token_hash` query params), Stripe secret keys, Supabase service role key fragments. Email-as-identifier (e.g. `[CreateBarber] created ${email}`) is permitted — the email is already in the Resend dashboard log and the user's own inbox.

### C12. MCP client is `supabase-mt` only [HIGH]
Grep check:
```bash
grep -rn "mcp__supabase__" .claude/ ~/.claude/skills/bulletproof-onboarding/
```
Expected: 0 matches. `mcp__supabase__` is the Maguey Nightclub project, NOT MT Barbershop.

### C13. Test barber IDs not used as seed for real flows [MEDIUM]
Per MEMORY.md Test Accounts HARD RULE. Grep check:
```bash
grep -rn "a274e1cf-955a-46f1-bc4c-dcd06a0510af\|b0020000-0000-0000-0000-000000000002" \
  src/ --include='*.ts' --include='*.tsx'
```
Expected: 0 matches in `src/` (test IDs belong to `tests/` only). If they leak into production code, they become de-facto real barbers on next `is_active` flip.

---

## How to use this file

- **Audit mode:** Run each data invariant query. Report each as PASS (0 rows) or FAIL (N rows). Note CRITICAL failures at the top of the audit report.
- **Diagnose mode:** When a specific barber's symptom doesn't map cleanly to a wizard step, walk through invariants #1–#15 looking for a contradiction. Often the "why" is a torn state from a half-failed transaction.
- **Scale-check mode:** Run invariants #6, #7, #10 against the whole active roster. If >5% of active barbers violate, the next cohort will inherit the same leak at the same rate.

Never fix in audit or scale-check mode. Report only. Fixes require explicit approval per Section 7 of `debugging-protocol.md`.
