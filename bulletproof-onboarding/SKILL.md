---
name: bulletproof-onboarding
description: Audit, diagnose, or scale-check the MT Barbershop barber onboarding system (7-step setup wizard at /barber/setup, invite flow via /api/auth/create-barber, barbers.onboarding_step, profiles.first_login_completed, commission acknowledgement, PWA install + push enrollment, Stripe Connect, profile completeness). Use when barbers can't finish setup, get stuck mid-wizard, lose track of how to install the PWA, never enable push, fall through the legacy commission gap, or before onboarding a new barber cohort. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to production DB. Never modifies application code without explicit user approval.
---

# Bulletproof Onboarding

Onboarding is the funnel that turns an invited email into a barber the customer can actually book. A leak anywhere in the funnel means the barber sits on the schedule but can't take customers, can't get paid (no Stripe Connect), can't get walk-in alerts on their phone (no push subscription), or worse — never legally agreed to the commission terms.

This skill audits the funnel, diagnoses single-barber stalls, and scale-checks the funnel before adding a new cohort.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Three onboarding states (read this first)

Every barber sits in exactly one of these states. The diagnose mode and audit funnel both lean on this taxonomy.

| State | DB signature | What it means | Common cause |
|---|---|---|---|
| **Pre-invite** | no row in `auth.users`, no `profiles`, no `barbers` | Owner hasn't created them yet | N/A — not a bug |
| **Invited, not started** | `auth.users` exists, `profiles.first_login_completed = false`, `barbers.onboarding_step = 1` (set by wizard on first paint) — OR `onboarding_step IS NULL` if they never opened the link | Magic link sent, never clicked or never set password | Magic link expired, email landed in spam, SMS invite ignored |
| **In-progress** | `profiles.first_login_completed = false`, `barbers.onboarding_step IN (1..7)` | Started wizard, stopped mid-flow | Closed tab on a step (Stripe OAuth + Booksy email gate are common drop-off points) |
| **Fully onboarded** | `profiles.first_login_completed = true`, `barbers.onboarding_step IS NULL`, `barbers.commission_acknowledged_at IS NOT NULL` | Hit Step 7 + acknowledged commission terms | N/A — happy path |
| **Legacy active** | `profiles.first_login_completed = true`, `barbers.onboarding_step IS NULL`, `barbers.commission_acknowledged_at IS NULL` | Active barber created BEFORE the commission acknowledgement step (Step 7) shipped | Pre-2026-03-20 barbers — recovered via `LegacyCommissionAckModal` (in-flight on `feature/onboarding-gap-1-pwa-install-schema` as of 2026-04-20) |
| **Fully onboarded with optional gaps** | `commission_acknowledged_at NOT NULL` AND (`stripe_account_id IS NULL` OR no push subscription OR no profile photo) | Wizard complete but skipped optional steps that block real work | Skipped Step 6 (Payouts) → no Stripe → can't get card payouts; never enabled push because the prompt isn't on `/barber/**` (incident 2026-04-20) |

The funnel-completion KPI (`completion_rate`) counts only the "Fully onboarded" row. Optional-gap barbers count as completed for funnel purposes but block on operational work.

---

## The 7-step wizard (canonical reference)

File: [src/app/(dashboard)/barber/setup/page.tsx](src/app/(dashboard)/barber/setup/page.tsx). Step labels live in the `currentStep` state (line ~43) and the comment on line 42. **Verify before reporting** — if these change, every step-numbered query below is wrong.

| Step | Label | Required? | API endpoint | Persists to | Skip behaviour |
|---|---|---|---|---|---|
| 1 | Password | Yes | `POST /api/auth/set-password` | `auth.users` (Supabase) | Cannot skip — wizard blocks |
| 2 | Profile (photo + bio) | No | direct Supabase upload + UPDATE | `profiles.avatar_url`, `barbers.bio`, `barbers.image_url` | "Skip" button advances to Step 3 |
| 3 | Services | Yes (≥1) | `POST /api/barber/custom-services` | `barber_custom_services` rows | Cannot skip — wizard blocks until ≥1 service |
| 4 | Schedule | No (Mon-Fri 9-7 default in wizard at line 64-69; create-barber endpoint inserts Mon-Sat 9-6 default at line 232 — drift) | `PUT /api/barber/schedule` | `barber_schedules` | "Save & Continue" with default = skip |
| 5 | Booksy | No | `PATCH /api/barber/booksy/settings` | `barbers.booksy_sync_enabled`, `barbers.booksy_sync_email` | Explicit "Skip" button (line ~1054) |
| 6 | Payouts (Stripe Connect) | No (skip → no digital payouts later) | `POST /api/barber/stripe/connect` (OAuth redirect) | `barbers.stripe_account_id`, `barbers.stripe_charges_enabled` | Explicit "Skip" button (line ~1144) |
| 7 | Terms (commission acknowledgement) | Yes | `POST /api/barber/acknowledge-commission` | `barbers.commission_acknowledged_at`, `barbers.grace_period_ends_at = NOW() + 30 days`, sets `barbers.onboarding_step = NULL`, sets `profiles.first_login_completed = true` | Cannot skip |

**Stripe nuance:** `stripe_account_id IS NOT NULL` only means the OAuth started. `stripe_charges_enabled = true` means Stripe accepted the bank details and the barber can actually receive payouts. Audit BOTH. A barber who started Connect but didn't finish bank verification has the first but not the second — they're still in Ledger B (shop owes them) per `bulletproof-commission`.

**Wizard guard (init):** [src/app/(dashboard)/barber/setup/page.tsx:99-164](src/app/(dashboard)/barber/setup/page.tsx). Reads `profiles.first_login_completed` + `onboarding_step`. If `first_login_completed=true` AND `onboarding_step IS NULL` → redirect to `/barber`. If owner role hits the page → redirect to `/dashboard`. If client role → redirect to `/`. Fetch has a 5-second timeout (line 133) — on timeout, falls through to `/barber` redirect if `first_login_completed=true`, otherwise stays on Step 1.

**Step persistence:** `saveStep()` at [src/app/(dashboard)/barber/setup/page.tsx:87-97](src/app/(dashboard)/barber/setup/page.tsx) PATCHes `/api/barber/onboarding-step` on every transition. If this fails, the barber loses their place silently (no toast, no retry).

---

## Mandatory Preflight — BEFORE any action

Read these four files in order. Skip none.

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "Authentication" section (3-tier role, invite flow, onboarding wizard).
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — onboarding-related entries + the test-account HARD RULE.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 7 (Zero Tolerance), 8 (Existing Systems Untouchable), 9 (Zero Production Data Contamination).
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Code Mirroring rule.

**Schema verification (run on every fresh invocation):**

```sql
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (
    (table_name = 'barbers' AND column_name IN (
      'id', 'profile_id', 'is_active', 'onboarding_step', 'onboarding_step_updated_at',
      'commission_acknowledged_at', 'grace_period_ends_at',
      'image_url', 'stripe_account_id', 'stripe_charges_enabled',
      'employment_type', 'preferred_location_id',
      'booksy_sync_email', 'booksy_sync_enabled', 'slug'
    ))
    OR
    (table_name = 'profiles' AND column_name IN (
      'id', 'first_login_completed', 'email_verified', 'avatar_url',
      'role', 'last_login_at', 'pwa_install_dismissed_at'
    ))
    OR
    (table_name = 'push_subscriptions' AND column_name IN ('user_id', 'queue_token', 'endpoint'))
  )
ORDER BY table_name, column_name;
```

Expected:
- `barbers.onboarding_step` INTEGER, nullable.
- `barbers.commission_acknowledged_at`, `grace_period_ends_at` TIMESTAMPTZ.
- `barbers.is_active` BOOLEAN.
- `barbers.stripe_charges_enabled` BOOLEAN — separate from `stripe_account_id`.
- `profiles.first_login_completed` BOOLEAN.
- `profiles.last_login_at` TIMESTAMPTZ — use this for "last seen" (NOT `onboarding_step_updated_at`, which freezes when wizard completes).
- `profiles.pwa_install_dismissed_at` TIMESTAMPTZ — only present after migration `20260420000000_add_pwa_install_dismissed_to_profiles.sql` ships. If absent, the install-banner dismissal can't be tracked yet.

If anything missing, STOP and tell the user — schema drift means audit queries will lie.

After reading + schema check, confirm to the user: **"Preflight complete. Running [mode]."** Then proceed.

---

## PII handling — owner-facing skill

This skill is owner-facing. The owner needs barber names, emails, and phone numbers to actually contact the people stuck in the funnel (text them a link, resend an invite, walk them through Stripe over the phone). So:

- **Names + emails + phone numbers ARE permitted in reports.** They are required to make the report actionable.
- **NEVER include in reports:** raw passwords, magic-link tokens (the long token_hash strings), session tokens, Stripe secret keys, VAPID private keys.
- **NEVER paste these values into any chat platform, ticket, or pastebin** (the user is the destination, end of chain).
- **NEVER include real-customer PII** (clients, customer phone numbers from `clients` table) in onboarding reports — that's out of scope; if the user asks, hand off to `bulletproof-bookings` or `bulletproof-communications`.

If the report goes to a non-owner audience (e.g., the user wants to share with a barber), name + last-4-of-phone is the right format. Ask before producing one of those.

---

## Choose a Mode

If the user didn't specify a mode, ask:

- **audit** — full funnel scan + code-plane checks (run before each cohort or weekly).
- **diagnose** — single-barber or single-location drilldown ("why hasn't X completed setup?", "what's wrong with the Edwardsville barbers?").
- **scale-check** — ratios + projections before inviting a new cohort.
- **fix** — apply canonical patterns from `references/fix-patterns.md`. EXPLICIT activation only; audit findings do NOT auto-trigger this mode.

Pick exactly one. Never run two modes in the same invocation.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (58+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY step-specific endpoint, and EVERY integration (Supabase Auth magic link, Resend, Twilio, Stripe Connect, web-push). Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. Onboarding is a multi-table funnel — a partial audit misses silent dropouts.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `api/auth/create-barber/route.ts` (owner invite) | Supabase `auth.admin.createUser` + `profiles` INSERT (role='barber', first_login_completed=false) + `barbers` INSERT + default `barber_schedules` INSERT (Mon-Sat 9-6 @ line 232) + `staff_status` INSERT + `barberInviteEmail` via Resend + `BarberSMS.sendInviteNotification` via Twilio + reverse-cascade catch block (staff_status → schedules → barbers → profiles → auth.users) | 7-write atomic. Any partial failure orphans rows. Reversed cascade order = FK deadlock. |
| `api/auth/resend-invite/route.ts` | Supabase magic-link regeneration + email resend + SMS resend + `profiles.email_verified` unchanged + pending-barbers list filter | Magic link TTL is 1 hour — resend must mint a fresh token AND invalidate the old one. |
| `setup/page.tsx` init guard (lines 99-164) | `profiles.first_login_completed` read + `barbers.onboarding_step` read + owner→`/dashboard` redirect + client→`/` redirect + 5-second fetch timeout fallback + JWT role resolution | Init guard bugs either trap completed barbers on the wizard or let in-progress barbers into an empty `/barber`. |
| `setup/page.tsx` `saveStep()` (lines 87-97) | PATCH `/api/barber/onboarding-step` + silent-failure toast (CURRENTLY MISSING) + state rollback on failed PATCH | If PATCH fails silently, barber closes tab = loses place. Step persistence must be observable. |
| Step 1 (`api/auth/set-password/route.ts`) | `auth.updateUser({password})` + `profiles.email_verified = true` + `barbers.onboarding_step = 1` initialization + session creation + `logAuthEvent('password_changed')` | Password set is the bridge from "invited" to "in-progress". Missing email_verified flip = stuck. |
| Step 3 (`api/barber/custom-services/route.ts`) | `barber_custom_services` INSERT + ≥1 row gate (wizard blocks advance until ≥1 service) + RLS barber-self-CRUD + public-select for profile page visibility | If the ≥1 gate breaks, barber lands on public profile with no services — can't take bookings. |
| Step 4 (`api/barber/schedule/route.ts`) | `barber_schedules` UPSERT + default conflict with create-barber Mon-Sat 9-6 (wizard shows Mon-Fri 9-7 — silent Saturday loss) + pre-load existing schedule (CURRENTLY MISSING) | Default drift between create-barber and wizard = saved customer hours silently overwritten. |
| Step 5 (`api/barber/booksy/settings/route.ts`) | `barbers.booksy_sync_email` UPDATE + `barbers.booksy_sync_enabled` + per-barber email uniqueness (for inbound resolver) + "Skip" button path does NOT write | Duplicate booksy emails collide in inbound Booksy parser (owned by `bulletproof-booksy-parser` — hand off if booksy sync downstream breaks). |
| Step 6 (`api/barber/stripe/connect/route.ts` + `callback/route.ts` + `status/route.ts`) | OAuth redirect URL + callback sets `barbers.stripe_account_id` + status poll sets `stripe_charges_enabled` + both columns must be distinguished (account exists ≠ charges enabled) + commission Ledger B/B' classification depends on `stripe_charges_enabled` | `stripe_account_id IS NOT NULL AND stripe_charges_enabled = false` = started OAuth, didn't finish verification. Commission routing MUST check charges_enabled, not account_id. |
| Step 7 (`api/barber/acknowledge-commission/route.ts`) | `barbers.commission_acknowledged_at = NOW()` + `barbers.grace_period_ends_at = NOW() + 30 days` + `barbers.onboarding_step = NULL` + `profiles.first_login_completed = true` + route idempotent for LegacyCommissionAckModal backfill | Step 7 flips FOUR fields atomically. Any missed field = legacy-state barber (funnel looks done, data says incomplete). Idempotency required for backfill modal. |
| `SetupStatusBanner.tsx` (on `/barber` + `/dashboard/my-chair`) | `/api/barber/setup-status` GET + reads services count + schedule exists + photo set + (post-Phase-1) push subscription count + (post-Phase-1) pwa_install_dismissed_at + MIRROR parity on both dashboards | Cross-Dashboard Code Mirroring HARD RULE. Banner must live on owner-as-barber page too — owner is also a barber. |
| `PwaInstallPrompt.tsx` + `NotificationPrompt.tsx` | Mounted on `/barber/**` (Phase 2 — CURRENTLY MISSING as of 2026-04-20) + `/barber/install` page exists (Phase 2 — CURRENTLY MISSING) + `/barber/help` documents iOS Safari quirk + push enrollment writes `push_subscriptions` row | 17% push enrollment baseline = prompts only mounted on public pages. New cohort will replicate the gap. |
| `barberInviteEmail()` in `lib/email/templates.ts` | Wizard step count advertised (CURRENTLY 4, wizard has 7 — drift) + magic-link URL format + Resend from-address + locationState for footer + NO raw token logging | Invite template advertising wrong step count = barber confusion. Log-hygiene: don't leak `hashed_token`. |
| `BarberSMS.sendInviteNotification` | Twilio `messaging_service_sid` or `from` number + per-location phone config + opt-out status check + onboarding-SMS NOT treated as marketing (mandatory transactional) | Transactional invite SMS must bypass marketing opt-out but respect STOP keywords. |
| `api/barber/onboarding-step/route.ts` | PATCH validates step IN 1..7 + persists `barbers.onboarding_step` + `onboarding_step_updated_at` + RLS self-write only + audit trail | Corrupted step value (>7 or <1) silently resets to 1 on next load. Worth logging to Sentry but currently silent. |
| `cron/grace-period-notifications/route.ts` | `barbers.grace_period_ends_at` window check + `barbers.commission_acknowledged_at NOT NULL` precondition + Twilio send + owner_alerts on threshold + CRON_SECRET auth | Grace-period cron is the only enforcement of the 30-day clock. Silent cron failure = no enforcement. |
| Legacy backfill (`LegacyCommissionAckModal`) | `barbers.commission_acknowledged_at IS NULL AND profiles.first_login_completed = true` query + idempotent POST to acknowledge-commission + owner-approval gate before manual override | Legacy barbers existed before Step 7 shipped. Backfill must NOT trigger 30-day grace reset on re-ack. |
| `public/team/page.tsx` (public visibility gate) | `barbers.is_active = true` + `barbers.onboarding_step IS NULL` + `profiles.first_login_completed = true` + `barbers.image_url` present (soft) | In-progress barbers must NOT appear publicly. Missing any filter = premature visibility. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the onboarding domain values:

```sql
-- 1. Enumerate onboarding-touched tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'barbers','profiles','barber_schedules','staff_status',
    'barber_custom_services','push_subscriptions'
  )
ORDER BY table_name;
-- Expected: 6 rows. Missing any = inventory drift; STOP and ask user.

-- 2. RLS policies on every onboarding-touched table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'barbers','profiles','barber_schedules','staff_status',
    'barber_custom_services','push_subscriptions'
  )
ORDER BY tablename, policyname;
-- Expected: at least 6 tables with self-read/update + owner-all policies.
-- Any missing policy or extra-permissive policy = RLS gap; FLAG in coverage report.

-- 3. Triggers on onboarding-touched tables (expected: none owned by onboarding)
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('barbers','profiles','barber_schedules','staff_status','barber_custom_services')
ORDER BY event_object_table, trigger_name;
-- Expected: no onboarding-specific triggers. Anything on barbers.onboarding_step = surface drift.

-- 4. RPC functions — onboarding owns none, but verify columns exist
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (
    (table_name = 'barbers' AND column_name IN (
      'onboarding_step','onboarding_step_updated_at',
      'commission_acknowledged_at','grace_period_ends_at',
      'image_url','stripe_account_id','stripe_charges_enabled',
      'employment_type','booksy_sync_email','booksy_sync_enabled','slug'
    ))
    OR (table_name = 'profiles' AND column_name IN (
      'first_login_completed','email_verified','last_login_at',
      'avatar_url','pwa_install_dismissed_at'
    ))
  )
ORDER BY table_name, column_name;
-- Expected: every column above present (pwa_install_dismissed_at only post-Phase-1).
-- Missing column = broken feature; STOP.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%auth_security%' OR name ILIKE '%onboarding%'
   OR name ILIKE '%custom_services%' OR name ILIKE '%payment_schema_catchup%'
   OR name ILIKE '%pwa_install%'
ORDER BY executed_at;
-- Expected: at least 4 rows (021, 20260306*_add_onboarding_step, 20260306*_create_barber_custom_services, 20260320*_payment_schema_catchup; + Phase-1 pwa_install if shipped).
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **Wizard guard intact**
   - File: [src/app/(dashboard)/barber/setup/page.tsx:99-164](src/app/(dashboard)/barber/setup/page.tsx)
   - On mount: redirect owner→`/dashboard`, client→`/`. If barber AND `first_login_completed=true` AND `onboarding_step IS NULL` → redirect to `/barber`. Otherwise stay on wizard at saved step.
   - Failure mode: a barber lands on `/barber` without setup → empty dashboard, no schedule, no services → can't take customers.

2. **Step persistence on every transition**
   - File: [src/app/(dashboard)/barber/setup/page.tsx:87-97](src/app/(dashboard)/barber/setup/page.tsx) `saveStep()` function.
   - Every step transition PATCHes `/api/barber/onboarding-step` with the new step number.
   - Failure mode (silent): if the PATCH fails, the barber who closes the tab loses their place. Should toast on failure but currently doesn't.

3. **Resume banner on re-entry** [LATENT — banner not yet shipped]
   - When `onboarding_step` is set on mount, the wizard resumes at that step but does NOT visibly tell the barber "Welcome back, you left off at step N." This is a latent UX gap, scheduled for Phase 4 of the onboarding-gap-1 work (2026-04-20).

4. **Commission acknowledgement is the wizard's terminal step**
   - File: [src/app/api/barber/acknowledge-commission/route.ts](src/app/api/barber/acknowledge-commission/route.ts)
   - Step 7 POST → sets `commission_acknowledged_at = NOW()`, `grace_period_ends_at = NOW() + 30 days`, `onboarding_step = NULL`, `profiles.first_login_completed = true`.
   - **Critical:** the API must remain idempotent — safe for `LegacyCommissionAckModal` to re-call for legacy backfill.

5. **Skip-able steps don't block completion**
   - Steps 2 (Profile), 4 (Schedule), 5 (Booksy), 6 (Payouts) have skip buttons. Steps 1 (Password), 3 (Services), 7 (Terms) are required.
   - Failure mode: if a UI bug silently disables skip on Steps 5/6, barbers stall at a step they can't and shouldn't be forced through.

6. **PWA install + push prompts visible inside `/barber/**`** [LIVE-blocking as of 2026-04-20]
   - Components: `src/components/ui/PwaInstallPrompt.tsx`, `src/components/queue/NotificationPrompt.tsx`, `src/components/barber/SetupStatusBanner.tsx`.
   - Grep: `grep -rn "PwaInstallPrompt\|NotificationPrompt\|barber/install" src/app/\(dashboard\)/barber/`
   - Failure mode: prompts only mounted on public pages → 17% push enrollment (4/24 barbers as of 2026-04-20). Phase 2 of `feature/onboarding-gap-1-pwa-install-schema` mounts a `/barber/install` page; Phase 3 mounts the banner.

7. **`/barber/help` page documents PWA + push** [LATENT until Phase 3 ships]
   - File: [src/app/(dashboard)/barber/help/page.tsx](src/app/(dashboard)/barber/help/page.tsx)
   - Must include sections: "Install the App" (iOS Safari + Android Chrome instructions, with the iOS Safari quirk explicitly called out) and "Push Notifications" (why enable, what triggers fire).

8. **Mirror parity: owner-as-barber sees the same nudges**
   - Owner (Gustavo / MT) is also a barber. `/dashboard/my-chair` is the mirror of `/barber`. Per Cross-Dashboard Code Mirroring HARD RULE, any onboarding nudge added to `/barber` MUST appear on `/dashboard/my-chair`.
   - Verify: `SetupStatusBanner` and any `LegacyCommissionAckModal` mounted on both pages.

9. **Invite outreach matches the actual wizard**
   - File: [src/lib/email/templates.ts](src/lib/email/templates.ts) → `barberInviteEmail()` (lines ~294-359). SMS template: [src/lib/twilio/sms.ts](src/lib/twilio/sms.ts) → `BarberSMS.sendInviteNotification` (called from create-barber line 315).
   - Email currently advertises "4 setup steps" (photo, bio, services, schedule). Wizard has 7. SMS template should be checked for the same drift.
   - Drift cost: barber expects a 4-step flow, hits Steps 5/6/7 unexpectedly, perceives the system as confusing.

10. **No PII in onboarding logs**
    - Grep `console.log` calls in [src/app/api/auth/create-barber/route.ts](src/app/api/auth/create-barber/route.ts), [src/app/api/auth/resend-invite/route.ts](src/app/api/auth/resend-invite/route.ts), [src/app/(dashboard)/barber/setup/page.tsx](src/app/(dashboard)/barber/setup/page.tsx), [src/app/api/barber/onboarding-step/route.ts](src/app/api/barber/onboarding-step/route.ts).
    - Phone numbers, full emails, magic-link tokens (`hashed_token`, `token_hash` query params), Supabase service role key fragments must NOT be logged. Email-as-identifier in `[CreateBarber] ... ${email}` style is permitted (it's already in the email subject line / Resend dashboard).

11. **Cascade rollback on create-barber failure**
    - File: [src/app/api/auth/create-barber/route.ts:347-411](src/app/api/auth/create-barber/route.ts)
    - If any of profile / barbers / schedules / staff_status inserts fail, the catch block must reverse-cascade-delete in FK-respecting order: staff_status → barber_schedules → barbers → profiles → auth.users.
    - Failure mode: orphaned rows from a partial insert. Detected by Query 6 (orphaned auth users / orphaned barbers).

12. **Schedule default drift between create-barber and wizard**
    - `create-barber` line 232 inserts a default Mon-Sat 9-6 schedule.
    - Wizard Step 4 default UI shows Mon-Fri 9-7 (line 64-69 of setup page).
    - If the barber clicks "Save & Continue" at Step 4 without changing anything, they OVERWRITE the create-barber Mon-Sat default with the Mon-Fri wizard default. Saturday hours disappear silently. **Either align the defaults or the wizard should pre-load existing schedule.**

### Data-level invariants

Run queries in `references/audit-queries.sql` (SELECT-only, expected 0 rows for violation queries unless the comment says otherwise). Report each as PASS/FAIL with row counts.

### Output template — MANDATORY Coverage Report

Every onboarding audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Onboarding Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: X/6 (barbers, profiles, barber_schedules, staff_status, barber_custom_services, push_subscriptions)
- RLS policies found: X — list any gaps
- Triggers found: X (expected: none onboarding-owned; `tr_referral_conversion` etc. are other skills' territory)
- Required columns present: X/Y (see preamble query 4)
- Migrations confirmed: X/5 (021, 20260306*_onboarding_step, 20260306*_custom_services, 20260320*_payment_catchup, 20260420*_pwa_install if shipped)

### Funnel state (from Query 1)
- Active barbers: N
- Fully onboarded: N (X%) — target ≥ 95%
- In-progress: N (stuck at steps: 1=N, 2=N, 3=N, 4=N, 5=N, 6=N, 7=N)
- Legacy active (no commission ack): N
- Fully-onboarded-with-optional-gaps: N (Stripe missing: N, push missing: N, photo missing: N)

### Coverage (from Queries 5–9)
- Push subscription ≥1 device: N/total (X%) — target ≥ 80%
- Stripe Connect (charges_enabled=true): N/total (X%) — target ≥ 80%
- Profile photo: N/total (X%) — target ≥ 90%
- Schedule: N/total
- Services (global or custom): N/total

### Findings
[Ranked critical/high/medium/low with file:line anchors]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (from SURFACE_INVENTORY.md sections 1-7) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/(dashboard)/barber/setup/page.tsx | PASS/FAIL/NOT-RUN | e.g. "setup/page.tsx:141 — init guard redirect for completed barbers" |
| 2 | src/app/api/auth/create-barber/route.ts | | |
| ... | [all 27 onboarding-owned files] | | |

Files audited with proof-of-read: N / 27 (target: 27/27). Any PASS without evidence = treated as NOT-RUN.

### Pillar 2 — Database (7 tables from inventory section 8)
| Table | Row count | Distribution | NULL violations | Verdict |
|---|---|---|---|---|
| barbers (onboarding cols) | | onboarding_step dist, ack NULL count | | |
| profiles | | first_login_completed dist | | |
| barber_schedules | | default vs customized | | |
| staff_status | | rows per barber | | |
| barber_custom_services | | per-barber count dist | | |
| push_subscriptions | | per-user count dist | | |
| auth.users | | (invite stats — do NOT SELECT unless needed) | | |

Tables audited: N / 7

### Pillar 3 — Queries (from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | funnel-state | | |
| 2 | step-drop-off | | |
| 3 | stuck-barbers | | |
| ... | [all queries] | | |

Queries run: N / total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (6 tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| barbers | | owner-all, self-read/update, public select limited | |
| profiles | | self + owner + PII-restricted | |
| barber_schedules | | barber self-write, owner full | |
| staff_status | | barber self, owner full | |
| barber_custom_services | | barber self CRUD, public read | |
| push_subscriptions | | self CRUD, owner read | |

RLS tables audited: N / 6

### Pillar 5 — Integrations (inventory sections 12, 14)
| Integration | Verdict | Note |
|---|---|---|
| Supabase Auth magic-link TTL | | 1-hour default |
| Resend barber invite email | | |
| Twilio barber invite SMS | | |
| Stripe Connect OAuth | | charges_enabled handshake |
| web-push VAPID / push_subscriptions | | |
| Cron: grace-period-notifications | | |

Integrations audited: N / 6

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| create-barber → {auth.users + profiles + barbers + schedules + staff_status + email + SMS + rollback} | YES/NO | |
| resend-invite → {magic-link regen, email, SMS, email_verified unchanged} | YES/NO | |
| setup init guard → {first_login_completed, onboarding_step, owner/client redirects, 5s timeout} | YES/NO | |
| saveStep → {onboarding-step PATCH, failure toast, state rollback} | YES/NO | |
| Step 1 set-password → {auth.updateUser, email_verified=true, onboarding_step init, session, auth_events} | YES/NO | |
| Step 3 custom-services → {barber_custom_services, ≥1 gate, RLS, profile-page propagation} | YES/NO | |
| Step 4 schedule → {barber_schedules UPSERT, default drift with create-barber, pre-load existing} | YES/NO | |
| Step 5 booksy → {booksy_sync_email uniqueness, booksy_sync_enabled, skip path, inbound resolver impact} | YES/NO | |
| Step 6 stripe connect → {account_id + charges_enabled distinction, callback, status poll, commission routing} | YES/NO | |
| Step 7 acknowledge-commission → {ack_at + grace_ends + onboarding_step=NULL + first_login_completed=true + idempotency} | YES/NO | |
| SetupStatusBanner → {setup-status API, services/schedule/photo/push/install, mirror parity} | YES/NO | |
| PWA/push prompts → {mounted on /barber/**, /barber/install page, /barber/help docs, push_subscriptions write} | YES/NO | |
| barberInviteEmail → {step count accuracy, magic-link format, footer locationState, no token logging} | YES/NO | |
| BarberSMS invite → {Twilio config, opt-out bypass rules, location phone} | YES/NO | |
| onboarding-step route → {step IN 1..7 validate, persist, RLS self-write, corrupt-value logging} | YES/NO | |
| grace-period cron → {grace_period_ends_at window, commission_acknowledged_at precondition, Twilio, owner_alerts, CRON_SECRET} | YES/NO | |
| Legacy backfill → {ack_at IS NULL AND first_login_completed query, idempotent POST, no grace reset} | YES/NO | |
| public /team gate → {is_active + onboarding_step IS NULL + first_login_completed + image_url} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/barber/acknowledge-commission/route.ts] | Step 7 idempotency not verified — legacy backfill may reset grace | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Supabase magic-link TTL, Resend deliverability, Twilio delivery status, Stripe Connect test account, web-push browser support): <list>.

If zero gaps: write "No gaps identified. All 58+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 58+ (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

### Latent vs live classification
- **Live (blocking)** — real barbers blocked from work right now.
- **Latent (prospective)** — code gap that will hit the next cohort.

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL ONBOARDING AUDIT — N surfaces unaudited, M coupling violations" instead of "Onboarding Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

### Symptoms this skill handles

1. **"Barber X can't finish setup"** (in-progress state)
   - Query their `barbers.onboarding_step` + `profiles.first_login_completed` (Query 12 — single-barber drilldown).
   - If step is set: tell user which step + what that step requires (see step table above).
   - Verify they have a Supabase auth user (`SELECT id, email_confirmed_at, last_sign_in_at FROM auth.users WHERE email = '...'` — only if user has not yet logged in once).
   - Verify the magic-link invite hasn't expired (Supabase magiclink TTL is 1 hour by default — check `auth.users.confirmation_sent_at` if `last_sign_in_at IS NULL`).

2. **"Barber X never gets walk-in pushes on their phone"**
   - Query `push_subscriptions` for their `user_id` (= `barbers.profile_id`). 0 rows = never enabled.
   - **Pre-Phase-2:** send to `/queue/live` (where `NotificationPrompt` is mounted today) and tell them to tap "Enable Notifications".
   - **Post-Phase-2:** send to `/barber/install`.
   - ≥1 row but they still don't get pushes = delivery, not enrollment. **Hand off to `bulletproof-push-notifications` diagnose mode.**

3. **"Owner reports a new barber 'isn't on the team page'"**
   - Public team page filters: `barbers.is_active = true` AND `barbers.onboarding_step IS NULL` AND `profiles.first_login_completed = true`. If any of those is false, they're still in onboarding and won't appear publicly.

4. **"Barber finished setup weeks ago but never received commission acknowledgement"** (legacy state)
   - Check `barbers.commission_acknowledged_at`. If NULL but `onboarding_step IS NULL` AND `is_active = true`, they're a legacy barber who pre-dates the commission flow.
   - Recovery: `LegacyCommissionAckModal` on `/barber` next login (Phase 4 of `feature/onboarding-gap-1-pwa-install-schema`).
   - Manual override: ask owner before calling `POST /api/barber/acknowledge-commission` on their behalf.

5. **"Barber stuck on 'Setup' page, can't get past it"**
   - Check `profiles.first_login_completed`. If false, the init guard (line 141-142) traps them.
   - Check `onboarding_step` — corrupted value (>7 or <1) is silently truncated by Step persistence (line 138 validates 1..7) but if the DB has a bad value via SQL injection or manual edit, the wizard re-loads at Step 1.
   - **Never reset `onboarding_step` to NULL without explicit owner approval** — that fires the wizard guard's redirect-to-/barber path which will leave them with an empty profile.

6. **"Barber finished the wizard but Stripe / push / photo are missing"** (fully-onboarded-with-optional-gaps — most common as of 2026-04-20)
   - `commission_acknowledged_at IS NOT NULL` AND missing Stripe/push/photo.
   - Map each gap to its remediation link (see Diagnose output template below).
   - Stripe specifically: distinguish `stripe_account_id IS NULL` (never started Connect) vs `stripe_account_id IS NOT NULL AND stripe_charges_enabled = false` (started OAuth, didn't finish bank verification). Different remediation copy.

7. **"Two Edwardsville barbers haven't gotten paid yet"** (location-scoped diagnose)
   - Use Query 13 (find by location) to identify all barbers attached to the location. Run Query 12 on each.
   - Output a per-barber runbook with the exact links to text them.

### Diagnose output template — runbook punch list

```
## [Location or Barber] Onboarding Diagnose — [YYYY-MM-DD]

### Funnel state
| Field | Barber 1 | Barber 2 |
|---|---|---|
| Email | ... | ... |
| Created | YYYY-MM-DD | YYYY-MM-DD |
| `first_login_completed` | ✅/❌ | ✅/❌ |
| `onboarding_step` | NULL or N | NULL or N |
| `commission_acknowledged_at` | ✅/❌ + date | ✅/❌ + date |
| Grace period ends | YYYY-MM-DD | YYYY-MM-DD |
| Profile photo | ✅/❌ | ✅/❌ |
| Schedule | ✅/❌ | ✅/❌ |
| Services | ✅ N items | ✅ N items |
| Stripe account | none / started / charges_enabled | ... |
| Push devices | N | N |
| Last login (`profiles.last_login_at`) | YYYY-MM-DD | YYYY-MM-DD |

### Runbook punch list

**Barber 1** ({email})
- [ ] **{Gap 1}** — text: "{exact copy}" — link: `https://mtbarbershop.com/{exact route}`
- [ ] **{Gap 2}** — ...

**Barber 2** ({email})
- [ ] ...

### Notes
- Grace period clock for any barber: ends YYYY-MM-DD (N days). After that, walk-in commission is owed.
- Cross-skill handoffs:
  - Push delivery (subscription exists but no notifications) → `bulletproof-push-notifications`
  - Stripe Connect routing (started OAuth but not getting paid) → `bulletproof-commission`
  - Location data correctness (wrong phone in templates, wrong state) → `bulletproof-locations`
  - Schedule visibility / availability bugs → `bulletproof-schedules`

### What this skill cannot verify
Whether the barber actually understands the system. Structural completeness only. Manual ride-along is the only way to confirm comprehension.
```

### Diagnose protocol

1. Ask user for the affected identifier (email, name, barber_id, OR location slug for location-scoped diagnose).
2. Run Query 12 for single barber, OR Query 13 + Query 12 for location-scoped.
3. Map missing artifact → wizard step that creates it (use the canonical 7-step table above).
4. **Three-file rule.** If after reading 3 files you still don't know what's broken, STOP and report.
5. **Two-strike rule.** If your first hypothesis is wrong, your second attempt MUST use a different approach. After two failed attempts, STOP.
6. **Never reset `onboarding_step`, `commission_acknowledged_at`, `grace_period_ends_at`, or `first_login_completed` without explicit owner approval.** These are legally + operationally meaningful.
7. **Skip "verify auth user exists" + "check invite expiry"** when `first_login_completed = true` (they obviously logged in already).

---

## Mode: scale-check

### Pre-cohort fix list

Before inviting > 5 new barbers, the following must be true:

1. **Push prompt mounted on `/barber/**`** (Phase 2/3 of `feature/onboarding-gap-1-pwa-install-schema`). Without it, new cohort will replicate the 17% enrollment baseline.
2. **`/barber/install` page exists** (Phase 2). iOS + Android instructions in one place.
3. **`/barber/help` covers PWA + push** (Phase 3).
4. **Resume banner on `/barber/setup`** (Phase 4) — soft UX but non-trivially reduces drop-off.
5. **`LegacyCommissionAckModal` exists if the cohort includes any backfill barbers** (Phase 4).
6. **Email + SMS invite templates updated** to mention 7 steps (not 4) — currently drift (Code invariant #9).

### Funnel queries

Run Queries 1, 5, 6, 7, 11, 14 from `references/audit-queries.sql` and produce ratios:

- Onboarding completion rate (target ≥ 95%, baseline 2026-04-20: 62%)
- Step-by-step drop-off
- Time-stuck distribution (median, p90)
- Push enrollment ratio (target ≥ 80%)
- Stripe Connect coverage (target ≥ 80%)
- Photo coverage (target ≥ 90%)
- Median + p90 days from invite to completion (Query 11)

### Cohort projection

If the funnel is at 62% completion and you're about to invite N new barbers, expect ~0.38 × N to stall. Pre-cohort fix list above is the gate.

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

When a barber's onboarding state changes (status flip, commission ack, push enabled), every surface that reads it must reflect immediately.

### Consumers (every surface that reads onboarding data)

| Consumer | File / URL | What it reads |
|---|---|---|
| Wizard guard | [src/app/(dashboard)/barber/setup/page.tsx:99-164](src/app/(dashboard)/barber/setup/page.tsx) | `profiles.first_login_completed`, `barbers.onboarding_step` |
| Public team page | `src/app/(public)/team/page.tsx` (or equivalent) | `barbers.is_active`, indirectly `onboarding_step IS NULL` and `first_login_completed=true` (only fully-onboarded barbers should appear) |
| Booking flow | `src/app/(public)/book/page.tsx` | `barbers.is_active`, `barber_schedules` |
| Public profile | `src/app/(public)/mtbarbers/[slug]/page.tsx` | `barbers.slug`, `barbers.image_url`, services |
| `/barber` home dashboard | [src/app/(dashboard)/barber/page.tsx](src/app/(dashboard)/barber/page.tsx) | `SetupStatusBanner` reads `/api/barber/setup-status`; commission balance reads `barbers.commission_acknowledged_at` + `barbers.grace_period_ends_at` |
| `/dashboard/my-chair` (owner-as-barber mirror) | [src/app/(dashboard)/dashboard/my-chair/page.tsx](src/app/(dashboard)/dashboard/my-chair/page.tsx) | Same as `/barber` for owner |
| `/api/barber/setup-status` | [src/app/api/barber/setup-status/route.ts](src/app/api/barber/setup-status/route.ts) | Aggregates: services, schedule, photo (and post-Phase-1: push, install dismissal) |
| Owner staff management | [src/app/(dashboard)/dashboard/barbers/page.tsx](src/app/(dashboard)/dashboard/barbers/page.tsx) | All onboarding state for staff list / pending onboarding / resend invite |
| Commission system | `bulletproof-commission` | `barbers.grace_period_ends_at` for booking-client fee waiver, `barbers.stripe_charges_enabled` for payment routing |
| Push notification delivery | `bulletproof-push-notifications` | `push_subscriptions.user_id` joined to `barbers.profile_id` |

### Propagation invariants

1. **`first_login_completed` flip is one-way.** Only set true by `acknowledge-commission` route. Never reset by any other path.
2. **`onboarding_step = NULL` is one-way for happy-path barbers.** Set null by `acknowledge-commission`. If you find a non-NULL value on a barber who already has `commission_acknowledged_at`, that's data corruption — investigate before "fixing".
3. **Realtime publication does NOT include `barbers` or `profiles`.** Setup-status changes propagate via SetupStatusBanner's mount-time fetch, not realtime. So new barbers see updated banner only on next page load.
4. **Cascade rollback on create-barber failure** (invariant #11). If any insert fails, all reverse.
5. **Magic-link tokens have a 1-hour TTL** by default. Resend invite via `/api/auth/resend-invite` regenerates a fresh token.

---

## Critical Operational Flows

Three multi-step flows where a break at ANY step causes the symptom. Load `references/flows.md` in diagnose mode when the symptom spans multiple wizard steps:

- **FLOW A** — Owner creates barber → invite delivered → wizard completes → barber active
- **FLOW B** — Barber clicks invite → sets password → resumes wizard
- **FLOW C** — Legacy backfill — barber active without commission ack

Full step-by-step tables and diagnose breakpoints for each flow live in [references/flows.md](references/flows.md).

---

## When to invoke other skills

| You see | Hand off to |
|---|---|
| Push subscription exists but barber isn't getting notifications | `bulletproof-push-notifications` (delivery layer) |
| Stripe Connect started but commission routing wrong | `bulletproof-commission` (Ledger A/B/B' classification) |
| Wrong phone or address in invite email/SMS | `bulletproof-locations` (location data correctness) |
| Schedule rows exist but availability API returns nothing | `bulletproof-schedules` (per-day routing) |
| Magic link expires too fast / lockouts during invite | `bulletproof-auth` (Supabase auth + lockouts) |
| Invite email never sent (Resend webhook failure) | `bulletproof-communications` (delivery) |

---

## When firecrawl is useful (and when it isn't)

Useful:
- Verifying current Supabase magic-link TTL if it changed
- Checking Stripe Connect onboarding redirect behaviour
- Confirming web push API support changes per browser

Not useful:
- "How do other barbershops onboard staff" — generic, doesn't know our wizard
- "Best onboarding UX in SaaS" — too broad

Invoke firecrawl ONLY at diagnosis time when a specific external question comes up. Do not pre-scrape into this skill.

---

## What to return to the user

End every invocation with one of:
- A completed report (audit / scale-check)
- A runbook punch list (diagnose)
- An explicit "I don't know — here's what I found, need direction"

Never silently retry. Never keep reading files past the 3-file rule.

---

## HARD RULES

- **NEVER write to production DB.** Read-only via `mcp__supabase-mt__execute_sql`. If a fix requires writes (e.g. resetting an onboarding_step, marking a barber inactive), STATE THE EXACT ROWS and wait for explicit approval. Section 9 of debugging-protocol.md.
- **NEVER reset `onboarding_step`, `commission_acknowledged_at`, `grace_period_ends_at`, or `first_login_completed` without explicit owner approval.** These are legally + operationally meaningful.
- **NEVER bypass the wizard guard** at `setup/page.tsx:141-142` to "let a barber in" — fix the underlying step instead.
- **NEVER modify the 7-step wizard flow itself** without explicit approval (Section 8 of debugging-protocol.md — locked system). Adding a new step, removing a step, or re-ordering is OFF LIMITS.
- **PII rule:** owner-facing reports may include barber names, emails, phones. Never include passwords, magic-link tokens, session tokens, Stripe secret keys, VAPID private keys. Never include real-customer PII (clients table is out of scope).
- **ALWAYS use `mcp__supabase-mt__`** (never `mcp__supabase__` — that's the nightclub project).
- **ALWAYS use test accounts when verifying flows** — Dev Owner `dev@mtbarbershop.com`, Luis Barber, Test Barbers 3/4. Real barbers OFF LIMITS for testing per CLAUDE.md.
- **Branch workflow** per `.claude/rules/branch-workflow.md`. Stay in scope.
- **Mirror check** per `.claude/rules/context-awareness.md` after any `/barber/**` or `/dashboard/my-chair/**` change.
- **Three-file rule + two-strike rule** during diagnose. If you've read 3 files and don't have an answer, STOP. If your second attempt fails, STOP and ask the user.
- **Confirm "Preflight complete. Running [mode]." before doing anything.**
