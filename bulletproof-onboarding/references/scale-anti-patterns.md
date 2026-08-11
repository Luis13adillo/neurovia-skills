# Onboarding Scale Anti-Patterns

The onboarding funnel works today for ~24 active barbers across 4 locations (Wilmington DE, Newark DE, New Castle DE, Edwardsville PA). Before the next cohort of > 5 new barbers, or before expanding to a 5th location, run every check here. Do NOT fix anything in scale-check mode — report only.

The funnel-completion baseline as of 2026-04-20 is 62%. If you're inviting N new barbers without closing the gaps below, expect ~0.38 × N to stall.

---

## 1. Invite delivery single-recipient assumption

The `POST /api/auth/create-barber` route is single-recipient. Each call: creates one auth user, sends one email, sends one SMS. There is no bulk-invite endpoint.

**Check:**
```bash
grep -rn "create-barber\|createBarber" src/app/api/ src/app/\(dashboard\)/dashboard/barbers/
```

**What breaks at scale:**
- Owner sits in `/dashboard/barbers` and pastes 10 emails one at a time — 10 independent API calls, 10 rollback windows, 10 chances for an orphan.
- If Resend (email) or Twilio (SMS) hits its rate limit mid-cohort, some barbers get the email, some don't. No centralized retry.
- No cohort tracking — impossible to answer "which barbers were invited in the same batch?" from DB alone.

**Refactor recommendation (do NOT implement in scale-check mode):**
- Add `POST /api/auth/create-barbers-bulk` that validates all rows, then loops with atomic rollback per row. Returns per-row result.
- Add `barbers.cohort_id` (UUID) populated at invite time. Index it for later analytics.

---

## 2. Magic-link TTL + invite expiry

Supabase default magic-link TTL is 1 hour. The invite email says "Complete your setup in a few minutes" but the link dies silently after an hour — then the barber's next click shows "token not found" with no context.

**Check:**
```bash
grep -rn "generateLink\|magiclink" src/app/api/auth/create-barber/ src/app/api/auth/resend-invite/
```

**What breaks at scale:**
- In a cohort where barbers are onboarded across days / evenings, most magic links expire before the barber opens the email.
- `/api/auth/resend-invite` exists but the owner has to manually click it per-barber from `/dashboard/barbers`. At 10+ stuck barbers, that's 10 manual resends.

**Refactor recommendation:**
- Surface "resend invite" as a bulk action on the staff list.
- Add a cron that auto-resends if barber hasn't logged in within 48 hours (once, not repeatedly — opt-out mechanic required).

---

## 3. PWA install instructions are device-specific, not centralized

As of 2026-04-20, the `PwaInstallPrompt` component lives at `src/components/ui/PwaInstallPrompt.tsx` and is NOT mounted inside `/barber/**`. The only install copy a new barber sees is on `/queue/live` (public surface) where `NotificationPrompt` is mounted.

**Check:**
```bash
ls src/app/\(dashboard\)/barber/install 2>&1
grep -rn "PwaInstallPrompt\|install the app" src/app/\(dashboard\)/barber/
```

**What breaks at scale:**
- iOS Safari install requires a specific tap path (Share → Add to Home Screen) that is NOT obvious. Chrome Android has a different install path. Desktop has a third path.
- Without a `/barber/install` page that detects device and shows the right copy, every new barber needs a manual walkthrough.
- Push-enrollment cannot happen without install on iOS (Apple requires the user to install the PWA before push permission can be requested).

**Refactor recommendation (Phase 2 of `feature/onboarding-gap-1-pwa-install-schema`):**
- Create `src/app/(dashboard)/barber/install/page.tsx` with device-aware instructions.
- Link it from `/barber/help` and from `SetupStatusBanner`.

**Scale math:** at 17% enrollment for an N=24 roster, 20 barbers are running the web tab, not the installed PWA. When foreground tab is closed, they miss every walk-in push. At N=40 that's ~33 barbers missing pushes.

---

## 4. Push-enrollment UX lives on public pages only

Component: `src/components/queue/NotificationPrompt.tsx`. Mounted today on `/queue/live` and `/queue/[location]` (public surfaces). NOT mounted on `/barber/**`.

**Check:**
```bash
grep -rn "NotificationPrompt" src/app/
```

**What breaks at scale:**
- New barbers never open a public queue page — their whole workflow is `/barber/**`. So the push prompt never fires.
- Baseline: 4/24 barbers enrolled (17%). At N=40 without the fix, expect ~7 enrolled.

**Refactor recommendation (Phase 2/3 of `feature/onboarding-gap-1-pwa-install-schema`):**
- Mount `NotificationPrompt` on `/barber` home and/or `/barber/install` page.
- Mirror to `/dashboard/my-chair` per Cross-Dashboard Code Mirroring rule.
- Respect `profiles.pwa_install_dismissed_at` (migration `20260420000000` pending).

---

## 5. Wizard defaults drift between create-barber and setup page

`/api/auth/create-barber` line 232 inserts Mon-Sat 9-6 as the default schedule. The wizard Step 4 UI at `src/app/(dashboard)/barber/setup/page.tsx:64-69` shows Mon-Fri 9-7 as its default.

**Check:**
```bash
grep -n "day_of_week\|dayOfWeek\|start_time" \
  src/app/api/auth/create-barber/route.ts \
  src/app/\(dashboard\)/barber/setup/page.tsx
```

**What breaks at scale:**
- Every barber who clicks "Save & Continue" at Step 4 without changing anything OVERWRITES the DB Mon-Sat 9-6 with the wizard's Mon-Fri 9-7 default. Saturday hours silently disappear. Wilmington and New Castle have weekend hours — a barber without a Saturday schedule is invisible to Saturday bookings.
- Not catchable by invariant queries because the schedule is "present" — it's just wrong.

**Refactor recommendation:**
- Align both defaults to the same value (probably Mon-Sat 9-6 per location hours).
- Better: pre-load existing schedule rows in the wizard Step 4 instead of showing a fresh default.

---

## 6. No batch reconciliation for "stuck > 72 hours"

Query 3 in `audit-queries.sql` returns days-stuck. There is no automated alert or owner-facing dashboard widget that surfaces "3 barbers haven't progressed in > 72 hours."

**Check:**
```bash
grep -rn "onboarding_step_updated_at" src/app/
```

**What breaks at scale:**
- At N=24, the owner can eyeball `/dashboard/barbers`. At N=40+, stuck barbers stop being noticed until someone complains.
- No SMS/email to the owner ("Brayan is stuck at Step 5 for 3 days") exists today.

**Refactor recommendation:**
- Add a cron (`/api/cron/onboarding-health`) that runs Query 3 daily. If any barber `days_stuck > 3` on a required step, send owner an SMS.
- Gate with `CRON_SECRET` per MEMORY.md "Production Readiness."

---

## 7. Legacy barbers block rollout of new terms

`LegacyCommissionAckModal` (Phase 4 of `feature/onboarding-gap-1-pwa-install-schema`, not yet shipped) shows a one-time commission acknowledgement on `/barber` next login.

**Check:**
```bash
grep -rn "LegacyCommissionAckModal\|legacy.*commission" src/components/ src/app/
```

**What breaks at scale:**
- If commission terms change (different percentage, new grace period length), there is no mechanism to re-prompt all barbers. `commission_acknowledged_at` is a single timestamp, not a versioned acceptance record.
- At N=24, a manual SMS + one-off route patch works. At N=40 across 4+ locations, you're calling each barber on the phone.

**Refactor recommendation:**
- Add `barbers.commission_terms_version INT NOT NULL DEFAULT 1` (migration).
- On load, `SetupStatusBanner` reads current `COMMISSION_TERMS_VERSION` env constant. If barber's version < current, re-prompt.
- Owner updates env var to force re-acknowledgement for the entire roster.

---

## 8. Stripe Connect onboarding has no "stuck halfway" surface

Gap between `stripe_account_id IS NOT NULL` (OAuth redirect completed) and `stripe_charges_enabled = true` (bank verification passed). A barber can start Connect, upload tax docs, then never finish. They disappear from "never started" but don't count as "enabled."

**Check:** Query 6 in `audit-queries.sql` classifies: never_started / started_not_enabled / charges_enabled. Currently no UI surfaces `started_not_enabled` separately.

**What breaks at scale:**
- At N=24 with 17% Connect coverage, half the roster is "started_not_enabled" (eyeballed). None get nudged back to Stripe.
- Without Connect, the barber shows up in `bulletproof-commission`'s Ledger B (shop owes them), not Ledger A (paid direct). Cash-flow implication at month-end.

**Refactor recommendation:**
- `SetupStatusBanner` should distinguish the three states with different copy:
  - "Finish setting up payouts so we can pay you digitally" (never started)
  - "Your bank details need a final check — tap here to finish" (started, not enabled)
  - Nothing (enabled)
- Add a weekly cron that SMS's barbers in `started_not_enabled` state.

---

## 9. No location-scoped onboarding reports

The audit report (Query 2) returns a flat list of all active barbers. There is no view that answers "how's the Edwardsville cohort doing" or "are New Castle barbers lagging on Stripe?"

**Check:**
```bash
grep -rn "location_id\|preferred_location_id" src/app/api/barber/setup-status/
```

**What breaks at scale:**
- Adding a 5th location (e.g., Dover, Philly) means 5–10 new barbers join that cohort. Owner can't easily compare their onboarding health against the older locations.
- Query 13 (find barbers by location) exists in `audit-queries.sql` but no dashboard surfaces it.

**Refactor recommendation:**
- Add a per-location tab to `/dashboard/barbers` showing cohort onboarding stats.
- Surface the same in `/dashboard/analytics/locations`.

---

## 10. VAPID key rotation breaks every push subscription silently

VAPID keys are stored in env vars: `NEXT_PUBLIC_VAPID_PUBLIC_KEY` + `VAPID_PRIVATE_KEY` (see CLAUDE.md).

**Check:**
```bash
grep -rn "VAPID_PUBLIC_KEY\|VAPID_PRIVATE_KEY" src/lib/push/
```

**What breaks at scale:**
- If VAPID keys rotate (intentional key hygiene or accidental rotation via Vercel env change), every existing `push_subscriptions` row has endpoints signed by the OLD public key. All push sends fail silently.
- No "push health" endpoint exists that detects the rotation and prompts re-enrollment.
- At N=24, 4 of them lose pushes until noticed. At N=40, 7 lose pushes.

**Refactor recommendation (out of scope for this skill — goes to `bulletproof-push-notifications`):**
- Add `push_subscriptions.vapid_public_key_fingerprint` column, set at subscribe time.
- On VAPID rotation, batch-delete stale subscriptions and trigger re-enrollment prompt on next login.

---

## 11. Hardcoded wizard step count in copy

The email invite template and SMS invite template mention "4 setup steps." The wizard has 7.

**Check:**
```bash
grep -rn "setup steps\|onboarding steps\|4 steps\|5 steps\|6 steps\|7 steps" \
  src/lib/email/templates.ts src/lib/twilio/sms.ts
```

**What breaks at scale:**
- Barber expects 4 steps, sees 7, perceives the system as buggy or misleading. Drop-off spikes at Step 5 (Booksy) because it feels "extra."
- When wizard adds an 8th step (likely), this drift compounds.

**Refactor recommendation:**
- Import step count from a single constant (`WIZARD_STEP_COUNT`) and interpolate into templates.
- Better: drop the count entirely from copy ("Complete a few quick setup steps").

---

## 12. Test account drift at scale

Test barber IDs are hardcoded in `tests/utils/database.ts` with constants `TEST_OWNER_BARBER_ID`, `TEST_BARBER_ID`, `TEST_BARBER_3_ID`, `TEST_BARBER_4_ID`. Per MEMORY.md HARD RULE.

**Check:**
```bash
cd /Users/luismiguel/Desktop/MT-Barbershop-Systems && npm run test:check-ids 2>&1 | head -20
```

**What breaks at scale:**
- At N=24, 4 test accounts (16% of roster) are enough. At N=40, test accounts are 10% — still OK.
- But the 4 test accounts are all at Newark. Testing multi-location onboarding flows (especially the new Edwardsville PA location with cross-state email footers) requires adding test barbers at other locations.

**Refactor recommendation (requires user approval):**
- Add Test Barber 5 at Wilmington, Test Barber 6 at Edwardsville. Update `tests/utils/database.ts` constants.
- Keep `is_active = false` for all.
- This is a DATA CHANGE to the production DB — MUST be approved per Section 9 of `debugging-protocol.md`.

---

## 13. `SetupStatusBanner` fetches aren't realtime

`SetupStatusBanner` reads `/api/barber/setup-status` on mount. There is no realtime subscription to `barbers` or `profiles` (the realtime publication covers `queue_entries`, `staff_status`, `bookings`, `barber_notifications`, `waitlist` — per CLAUDE.md).

**Check:**
```bash
grep -rn "setup-status\|useSetupStatus" src/ --include='*.ts' --include='*.tsx'
```

**What breaks at scale:**
- A barber dismisses the install prompt → the banner re-fetches on next mount but not immediately. Small UX issue at N=24, compounds at N=40 when cohort dismissals happen concurrently.

**Refactor recommendation:** Not worth it unless the cohort is huge. Most barbers refresh naturally.

---

## 14. Email footer `locationState` propagation

Per MEMORY.md location fix (2026-04-20): email templates accept optional `locationState` param, default `'DE'`. Invite emails currently may not pass state because the invite isn't location-scoped — the barber is assigned a location but the template renders a generic shop footer.

**Check:**
```bash
grep -rn "locationState\|locationCity" src/lib/email/templates.ts
```

**What breaks at scale:**
- Adding a PA-only cohort (Edwardsville) or a future NJ/MD location means the invite email footer needs to show the right state.
- Currently the invite is probably OK (it's about the barber onboarding, not a location-scoped booking) but worth verifying before adding a 5th state.

---

## 15. Cohort-in-progress overlap with production commission rollout

If a cohort is mid-onboarding when commission terms change, the new wizard Step 7 copy says one thing and the legacy modal says another. No mechanism prevents two concurrent cohorts from seeing different terms.

**Refactor recommendation:**
- Version the terms (see anti-pattern #7).
- Gate changes: don't deploy commission term changes while an active cohort is < 50% complete.

---

## Output: scale-readiness verdict

After running all checks, produce this summary:

```
## Onboarding Scale Readiness — cohort of N new barbers

### Ready (no blockers for this cohort size)
- [list: standard funnel queries return in-target numbers, no invariant violations]

### Must fix before inviting more than N=5
1. [anti-pattern # and one-line summary] — why it breaks at scale
2. ...

### Must fix before location #5
1. [anti-patterns #9, #14 especially]
2. ...

### Recommended cleanup (not blocking)
- [refactor suggestions from above]

### Current funnel metrics (from audit-queries.sql)
- Completion rate: X% (target ≥ 95%, baseline 62%)
- Push enrollment: X% (target ≥ 80%)
- Stripe charges_enabled: X% (target ≥ 80%)
- Photo coverage: X% (target ≥ 90%)
- Median days invite → completion: X (Query 11)

### Verdict
[READY for cohort of N / BLOCKED BY K MUST-FIX ITEMS]
```

Never make fixes in scale-check mode. The user decides which anti-patterns to tackle and when.
