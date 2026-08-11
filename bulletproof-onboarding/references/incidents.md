# Bulletproof Onboarding — Incident Log

Real incidents from MT Barbershop's barber onboarding system. Use these in `diagnose` mode to match symptoms before reading code.

---

## 2026-04-20 — Push enrollment systemic gap (17%)

**Symptom:** Owner reports barbers don't get walk-in alerts on their phone. Audit shows only 4 of 24 active barbers (17%) have any row in `push_subscriptions`.

**Root cause:** `PwaInstallPrompt` and `NotificationPrompt` components exist and are fully functional — but were ONLY mounted on public pages (`/queue/live`, `/book/confirmation`, `/mtclientlogin`, `/public/profile`). They were never wired into `/barber/**` or the setup wizard. New barbers complete the wizard, land on the dashboard, never see a push prompt, never enable notifications.

**Diagnostic signal (Query 5):** `enrollment_pct < 50%` is the threshold. Below that = systemic UX gap (not individual barber problem). At 17% in production.

**Fix in flight:** branch `feature/onboarding-gap-1-pwa-install-schema`:
- Phase 1 — schema (`profiles.pwa_install_dismissed_at`) + `/api/barber/setup-status` extension + `/api/barber/dismiss-install`
- Phase 2 — `/barber/install` page + `InstallStepCard` (iOS / Android)
- Phase 3 — extend `SetupStatusBanner` with 2 new items + add 2 help categories + mirror to `/dashboard/my-chair`
- Phase 4 — `LegacyCommissionAckModal` + resume banner on `/barber/setup`

**Latent vs live classification:** **Live (blocking)** — every active barber needs push to do their job; 20 of 24 are blocked.

---

## 2026-03-20 — Commission ack rolled out, 9 legacy barbers stranded

**Symptom:** Audit shows 9 active barbers with `is_active=true`, `first_login_completed=true`, `onboarding_step IS NULL`, but `commission_acknowledged_at IS NULL`. None of them are stuck in the wizard — they predate Step 7.

**Root cause:** Step 7 (commission acknowledgement) was added on 2026-03-20. Existing active barbers never got prompted because the wizard guard at `setup/page.tsx:141-142` redirects them to `/barber` before they can see Step 7. The `acknowledge-commission` API is idempotent and safe to call retroactively, but there was no UX path to trigger it.

**Diagnostic signal (Query 4):** `legacy_no_ack` count > 0 in funnel snapshot.

**Affected barbers (2026-04-20 audit):** Brayan Romero, Lili garcia, Stanley Hector, Juan Prado, Gustavo Olmedo, plus 4 in-progress (Yefry, Junii B., Juan, Fran).

**Fix:** `LegacyCommissionAckModal` component (Phase 4 of `feature/onboarding-gap-1-pwa-install-schema`). Shows on `/barber` next login if the legacy condition matches, calls `POST /api/barber/acknowledge-commission`.

**Latent vs live:** **Live** — these barbers haven't legally agreed to commission terms. Operationally fine, legally exposed.

---

## 2026-04-20 — Schedule default drift between create-barber and wizard

**Symptom:** New barber created by owner. Owner sees Mon-Sat schedule populated. Barber finishes wizard. Saturday hours disappear.

**Root cause:** `create-barber` route at line 232 inserts default Mon-Sat 9am-6pm schedule. The wizard Step 4 default UI shows Mon-Fri 9-7 (line 64-69 of setup page). If the barber clicks "Save & Continue" at Step 4 without modifying the schedule, the wizard PUT to `/api/barber/schedule` overwrites the create-barber default with the wizard's narrower default.

**Diagnostic signal:** Compare `barber_schedules` rows for a recent barber against the create-barber default. If Saturday is missing for someone whose owner-set assignment included Saturday, this is the cause.

**Fix:** Either (a) align create-barber default with wizard default to Mon-Fri, OR (b) wizard Step 4 should pre-load existing `barber_schedules` rows instead of using a constant. Pick one. Both involve touching the wizard which is locked per Section 8 of debugging-protocol.md — needs explicit approval.

**Latent vs live:** **Latent** — only affects barbers whose owner assigned Saturday hours that the wizard then silently drops. Currently low-impact since most barbers manually edit the schedule, but it's a trap.

---

## 2026-04-20 — Invite email + SMS advertise wrong step count

**Symptom:** Barber completes Steps 1-4, perceives the system as confusing because they thought it was a 4-step flow. Drops off at Step 5 or 6.

**Root cause:** `barberInviteEmail()` template at `src/lib/email/templates.ts:322-340` lists 4 setup steps (photo, bio, services, schedule). Wizard actually has 7 (adds password, Booksy, payouts, terms). SMS template `BarberSMS.sendInviteNotification` should be checked for the same drift.

**Diagnostic signal:** No SQL query for this — code-plane invariant #9. Read the email template + SMS template to confirm.

**Fix:** Update both templates to mention 7 steps OR rephrase to "complete your setup" without specifying a count.

**Latent vs live:** **Latent** — qualitative UX issue, doesn't block any barber.

---

## 2026-04-11 — Auto-start fired for wrong client (cross-reference)

This is documented in MEMORY.md and `bulletproof-queue` — listed here because it's adjacent to onboarding (the `calledClientIdRef` HARD RULE applies to barbers using the dashboard, which is post-onboarding behavior).

If a recently-onboarded barber complains about auto-start firing for a client they didn't call, hand off to `bulletproof-queue` diagnose mode. Don't try to fix the queue logic from this skill.

---

## Pattern: silent saveStep failure

**Symptom:** Barber says "I made it to Step 5 yesterday but today the wizard starts at Step 1."

**Root cause hypothesis:** `saveStep()` at `setup/page.tsx:87-97` swallows fetch errors silently (`console.error` only). If the PATCH to `/api/barber/onboarding-step` fails (network, 500, timeout), the step doesn't persist and the barber loses their place.

**Diagnostic protocol:**
1. Query `barbers.onboarding_step_updated_at` for that barber. If it's stale (> 1 day before the user's "yesterday"), `saveStep` failed silently.
2. Check `/api/barber/onboarding-step` route logs (Vercel) for that user_id.
3. The 5-second timeout in `initOnboarding` (line 133) fires `controller.abort()` which can mask both missing-step and stuck-fetch.

**Fix:** Add a toast on `saveStep` failure + retry-once. Currently latent.

**Latent vs live:** **Latent** until reported. Add a UX surface for the failure.

---

## Pattern: orphaned auth user from create-barber failure

**Symptom:** Owner tries to create a barber with email X. Gets 409 conflict ("account exists"). Owner says "but I never created them!"

**Root cause hypothesis:** A previous create-barber attempt failed mid-cascade (e.g., barbers insert succeeded but barber_schedules failed). The cascade rollback at lines 347-411 deletes in reverse order, but if any DELETE fails (FK constraint, permission), the rollback is partial. Result: orphaned `auth.users` row + maybe orphaned `profiles` row.

**create-barber's auto-cleanup path** (lines 122-167) handles the case where the orphan is detectable as "auth user exists, no profiles, no barbers". It will auto-delete and retry. But if the orphan also has a profiles row (partial cascade), it returns the 409.

**Diagnostic protocol (Query 16a/b):**
1. Query 16a: profiles WHERE role='barber' AND no barber row.
2. Query 16b: barbers WHERE no matching profile.
3. If 16a returns the email's row → manually delete profile + auth user (with explicit owner approval) OR ask owner if it's safe to deactivate.

**Fix:** Make cascade rollback wrap each DELETE in a savepoint OR ensure idempotency. Currently relies on log-and-continue.

**Latent vs live:** **Live** any time a create-barber 500 happens.

---

## Pattern: magic-link expired before barber clicked

**Symptom:** Barber clicks email link → "One-time token not found" error.

**Root cause:** Supabase magic-link tokens have a default 1-hour TTL. If the email landed in spam and the barber dug it out 2 hours later, the token is dead.

**Diagnostic protocol:**
1. `SELECT confirmation_sent_at, last_sign_in_at FROM auth.users WHERE email = '...'`
2. If `last_sign_in_at IS NULL` AND `confirmation_sent_at` is > 1 hour ago, the link is expired.
3. Owner uses `/api/auth/resend-invite` to generate a fresh link.

**Note:** The email template comment at create-barber.route.ts:270-272 explains the choice of `'magiclink'` over `'invite'`. Don't switch this — `'invite'` doesn't work with `createUser`-created users.

**Latent vs live:** **Live** for any barber who delays > 1 hour after invite.

---

## Pattern: silent push subscription orphaning during wizard

**Symptom (hypothetical, not yet observed):** Barber enables push during onboarding (post-Phase-2), then resets password later. The original `push_subscriptions.user_id` is `barbers.profile_id` which is stable across password reset, so the subscription survives. ✅ Not a bug — just verifying.

If a push subscription is orphaned (user_id IS NULL but no queue_token), it's the customer-facing tracker pattern, not a barber issue. Hand off to `bulletproof-push-notifications`.

---

## How to add a new incident here

When you encounter a new failure mode that isn't listed:

1. Title: `## YYYY-MM-DD — Short description`
2. Sections: **Symptom**, **Root cause**, **Diagnostic signal** (which query / file), **Fix** (or "in flight on branch X"), **Latent vs live classification**.
3. If the incident is fully resolved + has shipped to production, mark with ✅ in the title.
4. Cross-reference MEMORY.md if the incident already lives there to avoid drift.
