# Onboarding — Fix Patterns

Paste-ready diffs for the onboarding gaps that are code-level and safe to touch. This file is what `bulletproof-onboarding` points to when an audit surfaces a fixable failure. Every pattern cites the exact invariant or incident it closes.

All patterns follow the skill's HARD RULES:

- Read-only SQL via `mcp__supabase-mt__execute_sql`.
- **NEVER write to production DB.** `onboarding_step`, `commission_acknowledged_at`, `grace_period_ends_at`, `first_login_completed` are off-limits without explicit owner approval — these patterns touch code only.
- **NEVER modify the 7-step wizard flow itself** (Section 8, locked system). Aligning defaults between two places is fine; adding/removing a step is not.
- Single `Edit` per pattern. One pattern per invocation.
- Mirror-check after any `/barber/**` or `/dashboard/my-chair/**` change.

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "before" block against the current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If anything doesn't match → STOP and report what differs. Do NOT apply a stale pattern.
2. **Classify (live vs latent)** — Run the invariant query or Query 1 / Query 5 / Query 6 from `audit-queries.sql`. Confirm whether this gap is affecting real barbers right now (live) or is a prospective trap (latent). User decides urgency from this.
3. **Confirm diff** — Show the exact `old_string` / `new_string`. Wait for explicit `yes` before editing. If the change touches a HARD-RULE column in the DB → refuse and explain.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Verify** — Run the pattern's post-fix verification (grep + `npx tsc --noEmit`, plus an SQL check when the pattern is data-tied). Every check must pass.
6. **Mirror** — If the pattern touches anything under `/barber/**` or `/dashboard/my-chair/**`, invoke the `mirror-check` skill before handoff.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit from this skill.

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Cascade rollback on create-barber failure

**When:** Invariant C4 failing (missing reverse-cascade DELETE) OR Query 16a/16b returning orphans. Closes the "Orphaned auth user from create-barber failure" incident in `incidents.md`.

**Before:** `src/app/api/auth/create-barber/route.ts` lines ~347-411 (the outer `catch` block). If ANY insert after `auth.users` creation throws, orphans remain (`auth.users` row without `profiles`, or `profiles` without `barbers`, or `barbers` without `barber_schedules`/`staff_status`). The next create-barber attempt for the same email returns a misleading 409.

**After:** Wrap every step insert in a try/rollback pattern where the catch reverses in FK-respecting order:

```ts
// In the outer catch block near end of POST handler
} catch (err) {
  console.error('[CreateBarber] failed, starting cascade rollback', {
    email, // email-as-identifier is permitted per C11
    step: stepReached, // track which step we reached
    error: err instanceof Error ? err.message : 'unknown',
  })

  // Reverse-cascade in FK-respecting order. Log each step; never rethrow from
  // cleanup — partial rollback is worse than noisy rollback.
  try {
    if (barberRecordId) {
      await admin.from('staff_status').delete().eq('barber_id', barberRecordId)
      await admin.from('barber_schedules').delete().eq('barber_id', barberRecordId)
      await admin.from('barbers').delete().eq('id', barberRecordId)
    }
    if (profileId) {
      await admin.from('profiles').delete().eq('id', profileId)
    }
    if (authUserId) {
      await admin.auth.admin.deleteUser(authUserId)
    }
  } catch (rollbackErr) {
    console.error('[CreateBarber] cascade rollback partial — orphan may remain', {
      authUserId, profileId, barberRecordId,
      rollbackError: rollbackErr instanceof Error ? rollbackErr.message : 'unknown',
    })
  }

  return NextResponse.json({ error: 'Failed to create barber' }, { status: 500 })
}
```

**Post-fix verification:**
- `grep -n "staff_status\|barber_schedules\|barbers\|profiles\|deleteUser" src/app/api/auth/create-barber/route.ts` → confirm each of the five DELETE targets appears inside the catch block.
- Re-run Invariants #3, #4, #10 (Query 16a / 16b / 16c) in production → still 0 rows (no new orphans created).
- `npx tsc --noEmit` → no new errors.
- **Live probe (deferred):** force a 500 by asking the user to re-run a known-failing create (e.g., schedule insert blocked by FK). Confirm no orphan row in `auth.users`, `profiles`, or `barbers`.

---

## Pattern 2 — Reject magic-link type drift in create-barber

**When:** Invariant C5 failing — `grep -n "type: 'invite'" src/app/api/auth/create-barber/route.ts` returns > 0. Also check `incidents.md` → "magic-link expired before barber clicked" cross-reference.

**Before:** `src/app/api/auth/create-barber/route.ts` lines ~273-280. Any refactor that changes `type: 'magiclink'` to `type: 'invite'` breaks login for users created via `admin.auth.admin.createUser({ email_confirm: true })` — Supabase quirk: `'invite'` tokens expect the user to NOT be confirmed yet, but `createUser` confirms them at creation.

**After:** Keep `'magiclink'`. Add a short inline comment pointing at the contract so the next reviewer doesn't "fix" it:

```ts
// HARD RULE: type MUST be 'magiclink', NOT 'invite'.
// Users are created with email_confirm=true via createUser(), which makes
// 'invite' tokens invalid — barber clicks link, Supabase returns
// "One-time token not found". See bulletproof-onboarding invariant C5.
const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
  type: 'magiclink',
  email,
  options: {
    redirectTo: `${appUrl}/auth/confirm?next=${encodeURIComponent('/barber/setup')}`,
  },
})
```

**Post-fix verification:**
- `grep -n "type: 'invite'\|type: \"invite\"" src/app/api/auth/create-barber/route.ts` → 0 matches.
- `grep -n "type: 'magiclink'" src/app/api/auth/create-barber/route.ts` → ≥1 match.
- `npx tsc --noEmit` → no new errors.
- **Live probe (deferred):** create a test barber (test account — NOT a real barber per MEMORY.md HARD RULE), click the email magic link within 1 hour, confirm redirect to `/auth/confirm` → `/barber/setup`.

---

## Pattern 3 — Align schedule defaults between create-barber and wizard

**When:** Anti-pattern #5 (wizard defaults drift) AND incident 2026-04-20 "Schedule default drift." Verify by running `grep -n "day_of_week\|start_time" src/app/api/auth/create-barber/route.ts src/app/\(dashboard\)/barber/setup/page.tsx` — if the two defaults differ, this applies.

**Before:** `src/app/api/auth/create-barber/route.ts` line ~232 inserts Mon-Sat 9am-6pm as the default schedule. `src/app/(dashboard)/barber/setup/page.tsx` lines ~64-69 initializes wizard Step 4 local state to Mon-Fri 9am-7pm. A barber who clicks "Save & Continue" on Step 4 without editing OVERWRITES the create-barber default → Saturday hours silently disappear for locations where Saturday is a real working day (Wilmington, Newark, New Castle all have Saturday hours — see CLAUDE.md).

**After (choice A — align both to Mon-Sat 9-6, MINIMAL):** Update wizard Step 4 initial state to match the create-barber default. The wizard is a locked system (Section 8), so this is a default-value tweak, NOT a flow change — still needs explicit owner approval before applying.

```tsx
// src/app/(dashboard)/barber/setup/page.tsx — the useState initializer for schedule
const [schedule, setSchedule] = useState<ScheduleState>({
  monday:    { enabled: true,  start: '09:00', end: '18:00' },
  tuesday:   { enabled: true,  start: '09:00', end: '18:00' },
  wednesday: { enabled: true,  start: '09:00', end: '18:00' },
  thursday:  { enabled: true,  start: '09:00', end: '18:00' },
  friday:    { enabled: true,  start: '09:00', end: '18:00' },
  saturday:  { enabled: true,  start: '09:00', end: '18:00' },
  sunday:    { enabled: false, start: '10:00', end: '16:00' },
})
```

**After (choice B — pre-load existing rows, SAFER):** Fetch existing `barber_schedules` in `initOnboarding` and seed the wizard state from the DB. This preserves whatever the owner chose at create time. Higher blast radius — recommend only if the user OKs a wizard change.

**Post-fix verification:**
- `grep -n "day_of_week\|start_time\|end_time" src/app/api/auth/create-barber/route.ts src/app/\(dashboard\)/barber/setup/page.tsx` → two files show IDENTICAL default shape.
- Query 8 (active barbers without schedule rows) → still 0 rows (no regression).
- For a freshly-created test barber, compare `barber_schedules` row count before and after the wizard's Step 4 "Save & Continue" → must be identical.
- `npx tsc --noEmit` → no new errors.
- **Mirror-check** — `/dashboard/my-chair` doesn't run the setup wizard, so no mirror work needed here. Skip mirror-check skill.

---

## Pattern 4 — Mount PWA install + push prompts on `/barber/**`

**When:** Invariant C9 latent (grep returns zero inside `/barber/**`) AND Query 5 shows push enrollment < 50%. This is the **live-blocking 17% enrollment gap** from incident 2026-04-20.

**Before:** `PwaInstallPrompt.tsx`, `NotificationPrompt.tsx`, `SetupStatusBanner.tsx` exist under `src/components/` but none are mounted inside `src/app/(dashboard)/barber/**`. Verified missing: `ls src/app/(dashboard)/barber/install` → directory does not exist as of 2026-04-21.

**After:** This pattern is a SCAFFOLD outline, not a single `Edit` — it's Phase 2+3 of `feature/onboarding-gap-1-pwa-install-schema`. Apply in three separate fix-mode invocations:

1. **Create `src/app/(dashboard)/barber/install/page.tsx`** — device-aware instructions page. iOS Safari (Share → Add to Home Screen, with screenshot), Android Chrome (three-dot menu → Install app), desktop Chrome (address bar install icon). Use `canEnablePush()` and `isIOSSafari()` from `src/lib/push/client.ts` (see `bulletproof-push-notifications` Pattern 6 — reuse, don't duplicate).
2. **Mount `SetupStatusBanner` in `src/app/(dashboard)/barber/page.tsx`** — reads `/api/barber/setup-status` and renders two new items: "Install the app" (link → `/barber/install`) and "Enable push notifications" (link → same page). Respect `profiles.pwa_install_dismissed_at` (Phase 1 migration).
3. **Mirror to `src/app/(dashboard)/dashboard/my-chair/page.tsx`** — per C10 + `.claude/rules/context-awareness.md` Cross-Dashboard Code Mirroring. Owner (Gustavo) is also a barber and needs the same nudges.

**Post-fix verification:**
- `ls src/app/\(dashboard\)/barber/install/page.tsx` → file exists.
- `grep -rn "SetupStatusBanner" src/app/\(dashboard\)/barber/ src/app/\(dashboard\)/dashboard/my-chair/` → ≥2 matches (one per dashboard).
- `grep -rn "PwaInstallPrompt\|NotificationPrompt" src/app/\(dashboard\)/barber/` → ≥1 match.
- **Mirror-check** — invoke the `mirror-check` skill after step 3. Must report 0 drift between `/barber` and `/dashboard/my-chair`.
- Query 5 (push enrollment) — re-run 7 days after shipping; enrollment % should climb toward the 80% target. If it doesn't, the prompts render but barbers are dismissing them — different problem, hand off to `bulletproof-push-notifications` diagnose mode.
- **Never write to `push_subscriptions` or `barbers` on behalf of barbers** — no forced enrollment, no forced install flag.

---

## Pattern 5 — Idempotent acknowledge-commission API

**When:** Invariant C3 failing — the route is not safe to re-call for an already-acknowledged barber. The `LegacyCommissionAckModal` (Phase 4) depends on idempotency for backfill: the modal POSTs the same endpoint, and if it resets `grace_period_ends_at` to `NOW() + 30 days`, a legacy barber's grace clock restarts incorrectly.

**Before:** `src/app/api/barber/acknowledge-commission/route.ts`. If the route unconditionally runs `UPDATE barbers SET commission_acknowledged_at = NOW(), grace_period_ends_at = NOW() + INTERVAL '30 days' ...`, it will overwrite existing values on every POST.

**After:** Short-circuit when already acknowledged. Return the existing state, do not mutate:

```ts
// After auth + role check, BEFORE the UPDATE:
const { data: existing } = await supabase
  .from('barbers')
  .select('commission_acknowledged_at, grace_period_ends_at')
  .eq('profile_id', user.id)
  .single()

if (existing?.commission_acknowledged_at) {
  // Idempotent: already acknowledged. Do NOT reset grace_period_ends_at.
  return NextResponse.json({
    success: true,
    already_acknowledged: true,
    acknowledged_at: existing.commission_acknowledged_at,
    grace_period_ends_at: existing.grace_period_ends_at,
  })
}

// Only proceed with the UPDATE when commission_acknowledged_at IS NULL
// ... existing UPDATE logic ...
```

**HARD-RULE note:** this pattern READS those fields and skips the write when set. It does NOT reset them — that is explicitly forbidden without owner approval (per SKILL.md HARD RULES and invariant #5).

**Post-fix verification:**
- `grep -n "already_acknowledged\|existing.commission_acknowledged_at" src/app/api/barber/acknowledge-commission/route.ts` → ≥1 match.
- Run Invariant #2 query in production → still 0 rows.
- Run Invariant #8 query (grace-period consistency) → still 0 rows.
- `npx tsc --noEmit` → no new errors.
- **Live probe (deferred):** call `POST /api/barber/acknowledge-commission` twice for the SAME already-acknowledged test barber. First call returns `already_acknowledged: true`. Second call returns the same timestamps. Neither changes DB state.

---

## Pattern 6 — Remove PII from onboarding logs

**When:** Invariant C11 failing. Run the grep check from the invariant:

```bash
grep -n "console.log\|console.error" \
  src/app/api/auth/create-barber/route.ts \
  src/app/api/auth/resend-invite/route.ts \
  src/app/api/barber/onboarding-step/route.ts \
  src/app/\(dashboard\)/barber/setup/page.tsx
```

Any `console.*` that logs full phone numbers (`${phone}`), magic-link tokens (`hashed_token`, `token_hash`, `linkData.properties.hashed_token`), Supabase service role key fragments, or raw password strings is a violation.

**Before:**

```ts
// BAD — leaks magic-link token to Vercel logs
console.log('[CreateBarber] link generated', linkData.properties.hashed_token)

// BAD — leaks full phone to logs
console.log(`[CreateBarber] SMS sent to ${phone}`)
```

**After:**

```ts
// OK — email-as-identifier is permitted per C11 (it's already in the Resend dashboard + user inbox)
console.log(`[CreateBarber] link generated for ${email}`)

// OK — redact phone to last 4 digits
const phoneLast4 = phone?.slice(-4) ?? 'xxxx'
console.log(`[CreateBarber] SMS sent to ***${phoneLast4}`)
```

**Post-fix verification:**
- `grep -n "hashed_token\|token_hash\|properties\.hashed" src/app/api/auth/ src/app/\(dashboard\)/barber/` → 0 matches inside `console.*` calls.
- `grep -n "console.*\\\${phone}" src/app/api/auth/ src/app/\(dashboard\)/barber/` → 0 matches (phone should be redacted if logged at all).
- `npx tsc --noEmit` → no new errors.
- **No live probe** — log hygiene is verified by grep. Don't write test data to generate logs.

---

## Pattern 7 — Align invite email + SMS templates with actual wizard step count

**When:** Invariant C8 drift + incident 2026-04-20 "Invite email + SMS advertise wrong step count." Run:

```bash
grep -n "4 setup steps\|4 quick steps\|5 setup steps\|6 setup steps\|7 setup steps" \
  src/lib/email/templates.ts src/lib/twilio/sms.ts
```

Currently `barberInviteEmail()` says "4 setup steps" (photo, bio, services, schedule). Wizard has 7.

**Before:** `src/lib/email/templates.ts` lines ~322-340 (inside `barberInviteEmail()`) lists 4 steps.

**After (choice A — drop the count):** Least-risky. Never go stale when wizard count changes:

```ts
// src/lib/email/templates.ts — barberInviteEmail()
<p>When you click the link below, you'll be guided through a quick setup to get your profile ready for customers.</p>
// (remove the numbered "4 steps" list, or keep an unnumbered bullet list without a count)
```

**After (choice B — single source of truth constant):** Import a shared constant:

```ts
// src/lib/constants/onboarding.ts (new file OR add to existing constants module)
export const WIZARD_STEP_COUNT = 7

// src/lib/email/templates.ts
import { WIZARD_STEP_COUNT } from '@/lib/constants/onboarding'

// inside barberInviteEmail():
<p>${WIZARD_STEP_COUNT} quick steps to get you set up for customers.</p>
```

Apply the same to `src/lib/twilio/sms.ts` → `BarberSMS.sendInviteNotification`. Keep the change minimal — this is copy, not logic.

**Post-fix verification:**
- `grep -n "4 setup steps\|4 quick steps" src/lib/email/templates.ts src/lib/twilio/sms.ts` → 0 matches.
- `grep -n "WIZARD_STEP_COUNT" src/lib/` → ≥2 matches (constant + both templates) if choice B, OR 0 if choice A.
- `npx tsc --noEmit` → no new errors.
- **Live probe (deferred):** create a test barber, inspect Resend dashboard preview of the invite email + Twilio SMS body. Confirm step count matches the actual wizard.

---

## Cross-pattern rules

1. **Single pattern per fix-mode invocation.** Never chain two patterns in one session — each has its own preflight, verification, and mirror check.
2. **Never write to `onboarding_step`, `commission_acknowledged_at`, `grace_period_ends_at`, `first_login_completed` without explicit owner approval.** These are legally/operationally meaningful. Patterns in this file touch CODE only.
3. **Never modify the 7-step wizard flow itself** (Section 8, locked system). Adding/removing a step, re-ordering — OFF LIMITS. Default-value tweaks (Pattern 3) are borderline; get approval.
4. **Never create test data in production.** Use test accounts (`a274e1cf…`, `b0020000…`, `b0030000…`, `b0040000…`) for probes. Real barbers OFF LIMITS per MEMORY.md HARD RULE.
5. **Mirror-check after any `/barber/**` or `/dashboard/my-chair/**` change.** Especially Pattern 4.
6. **Stop at `bulletproof-ship`.** This skill never commits.

---

## When adding a NEW pattern

Checklist:
1. Cite the exact invariant (I1–I18) or code invariant (C1–C13) it closes.
2. Reference the incident in `incidents.md` if one exists.
3. Does it touch any HARD-RULE DB column? If yes → reject the pattern; escalate to owner.
4. Does it touch the 7-step wizard flow shape? If yes → reject (locked system).
5. Does it need a cross-dashboard mirror? If yes → include mirror-check in post-fix verification.
6. Can it be verified by grep + `tsc`? If not, add the SQL invariant query that confirms it.

If any answer is "no" or "unclear," stop and ask the user before adding.
