# Ship Preflight Checklist

Copy this block at the start of every commit/push session. Check each item.

---

## 1. Context check (read BEFORE anything else)

- [ ] Read `CLAUDE.md` — current system state, HARD RULES
- [ ] Read `MEMORY.md` — recent incidents, test accounts, column names
- [ ] Read `.claude/rules/branch-workflow.md`
- [ ] Read `.claude/rules/debugging-protocol.md` §6, §7, §8, §9
- [ ] Read `.claude/rules/context-awareness.md` — cross-dashboard mirroring
- [ ] Know the task in one sentence. Can you state what the user asked for?

## 2. Git state

- [ ] `git status` — what's modified, staged, untracked
- [ ] `git branch --show-current` — are you on a feature branch?
- [ ] `git log --oneline -5` — what does the recent history look like?

## 3. Scope

- [ ] Every changed file is DIRECTLY required by the task
- [ ] No "while I'm here" cleanup, renaming, or refactoring
- [ ] No new files unless the task required a new file
- [ ] No new RPCs/migrations without explicit user approval
- [ ] File count matches the task's natural size (bug fix = 1-3 files usually)

## 4. Secrets

- [ ] No `sk_live_...` values in diff
- [ ] No `SUPABASE_SERVICE_ROLE_KEY=...` values
- [ ] No `VAPID_PRIVATE_KEY=...` values
- [ ] No `TWILIO_AUTH_TOKEN=...` values
- [ ] No `.env.local` or `.env.local.prod` in staged files
- [ ] No long base64-looking JWT strings

## 5. Mirror pages (if dashboard changed)

- [ ] Changed `src/app/(dashboard)/barber/<X>`? Mirror to `dashboard/my-chair/<X>` done?
- [ ] Changed `dashboard/my-chair/<X>`? Mirror to `barber/<X>` done?
- [ ] Shared component (InServiceMode, PostServiceFlow, PaymentCollectionModal) change — does it still work in both dashboards?

## 6. Test accounts

- [ ] No real barber IDs in test files (will fail pre-commit hook anyway)
- [ ] Using `TEST_OWNER_BARBER_ID` / `TEST_BARBER_ID` constants instead of raw UUIDs

## 7. Production data

- [ ] No script that INSERTs/UPDATEs/DELETEs against prod without explicit user approval
- [ ] No test data writes left behind from earlier in the session

## 8. Hooks parity

- [ ] `npx tsc --noEmit` passes locally
- [ ] `npm run test:check-ids` passes locally
- [ ] (If pushing to main) `npm run build` succeeds locally

## 9. Commit message draft

- [ ] Type from: `fix | feat | chore | docs | ci | merge`
- [ ] Scope is specific: `queue`, `booking`, `schedule`, `sw`, `dashboard/calendar` — NOT vague
- [ ] Subject is imperative: "fix X" / "add Y" — not "fixed X" / "added Y"
- [ ] Subject describes WHY/WHAT, not which files
- [ ] Co-Authored-By line included

## 10. Push impact

- [ ] Pushing to `main`? Confirmed with user: "This auto-deploys to prod. Proceed?"
- [ ] Know which URL(s) to check after deploy to verify the change
- [ ] Ready to watch `/tmp/mt-vercel-autodeploy.log`

---

## STOP CONDITIONS

Any of these = STOP and talk to the user:

- Change touches more than 5 files and the task was "fix a bug"
- Migration file in the diff without prior approval
- New API route in the diff without prior approval
- Secret value in the diff (even if unchanged — don't commit a line containing a production secret)
- Mirror page not updated
- Type error or test:check-ids failure
- Pre-push build fails
- Confusion about what branch to use
