---
name: maguey-bulletproof-ship
description: Safely ship Maguey Nightclub changes to production. Covers git push, Supabase Edge Function deploy, Supabase migration apply, and Vercel deploy across the 3-app monorepo (maguey-nights, maguey-pass-lounge, maguey-gate-scanner). The primary path is a single command — `./ship.sh` — which figures out what changed on the current branch and deploys only what needs deploying. This skill is the last line of defense. Use when the user says "commit this", "push it", "ship it", "merge this", "deploy", or after finishing any code change. Never skips hooks. Never force-pushes main without explicit approval. Never deploys Stripe-related changes without dry-run via Stripe CLI.
---

# Maguey Bulletproof Ship

Maguey has three Vercel projects and one Supabase project. One wrong push and customers can't buy tickets, staff can't scan, or the marketing site 500s. This skill is the guardrail for every deploy.

## The one command

**`./ship.sh`** at the repo root does everything needed to ship the current branch:

1. Refuses to run if you're on `main` or have uncommitted changes
2. Pushes the branch to GitHub
3. Detects what files changed on this branch vs `origin/main`
4. Deploys any changed Edge Function to Supabase (`supabase functions deploy <name>`)
5. Deploys any changed Vite app to Vercel prod (calls `./deploy-all.sh <app>`) — only the apps that actually changed
6. Flags any migration files as "do NOT auto-apply" and lists them for you to review
7. Prints the GitHub PR URL at the end

**Flags:**
- `./ship.sh --dry-run` — show the plan without doing anything (safe even with a dirty tree)
- `./ship.sh --yes` — skip the confirmation prompt
- `./ship.sh --help` — print usage

**When to NOT use `./ship.sh`:**
- Re-deploying a branch already pushed + deployed (script is idempotent but wasteful)
- Deploying a specific preview build (`vercel deploy` non-prod from inside the workspace)
- Applying a migration (script never does this — intentional)
- Shipping from `main` directly (not allowed)

For all the cases above, fall back to the step-by-step procedure below.

**Affected by this skill:**
- Git workflow (branches, commits, merges)
- Vercel prod deploys for all 3 projects via `./deploy-all.sh` (manual CLI — auto-deploy is dead, see below)
- Supabase Edge Function deploys (`supabase functions deploy`) — 20 in `maguey-pass-lounge/supabase/functions/` + 14 in `maguey-gate-scanner/supabase/functions/` (maguey-nights has no Edge Functions)
- Supabase migrations (`supabase db push` or manual via SQL editor)
- Environment variables across Vercel (3 projects) + Supabase Edge Function secrets
- CI/CD via `.github/workflows/e2e.yml`

## Two-Command Shipping Model (locked in 2026-04-21)

GitHub → Vercel auto-deploy webhook is DEAD on this account (GitHub Trust & Safety flag blocks all third-party OAuth, which breaks Vercel's integration). User chose this model permanently over filing a support ticket. **Do not mention "restore auto-deploy" or "GitHub support ticket" in reports unless the user brings it up first.**

**Two independent commands, always:**

1. **Push code to GitHub** (repo in sync)
   ```bash
   git push -u origin <branch>      # feature branch
   # or after PR merge, pull main:
   git pull origin main
   ```

2. **Deploy code to Vercel prod** (live on .com)
   ```bash
   ./deploy-all.sh                         # all 3 apps
   ./deploy-all.sh maguey-pass-lounge      # just one app
   ./deploy-all.sh maguey-gate-scanner
   ./deploy-all.sh maguey-nights
   ```

**The deploy script** (`deploy-all.sh` at repo root) works around a Vercel CLI bug where `deploy --prebuilt` double-applies `rootDirectory` when run from inside a workspace. For each target:
- `cd <ws>` → `vercel pull --environment=production` → `vercel build --prod`
- Copy `<ws>/.vercel/` to repo root so `rootDirectory=<ws>` resolves correctly
- Run `vercel deploy --prebuilt --prod --yes` from repo root
- Clean up `.vercel/` at repo root

**Rules of the model:**
- Push and deploy are two independent steps. One does not trigger the other.
- Never assume Vercel has picked up a push. Explicitly run `./deploy-all.sh`.
- Preview deploys on PRs do NOT fire automatically. If user wants a preview, run `./deploy-all.sh <app>` manually, or `vercel deploy` (non-prod) from within the workspace.
- The script is authoritative. Do not hand-roll `vercel deploy` commands unless the script breaks — then fix the script, don't work around it.

---

## Schema Reality Check (verified 2026-04-21 against live DB)

Several migrations exist on disk but have NOT been applied to production. If a deploy includes any of the following migration files, that's a real schema change — treat as TIER 3 risk, coordinate with the related skill:

- **Profile infrastructure:** `maguey-pass-lounge/supabase/migrations/20250320000000_auth_enhancements.sql` + `20250303000002_create_user_loyalty.sql`. Deploys: `profiles`, `user_loyalty`, `user_devices`, `referrals`, `magic_links`, `login_activity`. When applied, Profile.tsx / AccountSettings.tsx / TwoFactorSetup.tsx switch from dead-code to live. See `maguey-bulletproof-client-profile` and `maguey-bulletproof-auth` for the phased rollout plan (2FA secrets need to be encrypted and TOTP verification added before cutover).
- **Customer stats view:** `maguey-gate-scanner/supabase/migrations/20260401000001_customer_stats_view.sql`. Deploys `customer_stats` VIEW + `get_customer_visit_count` RPC (SECURITY DEFINER). Unblocks `CustomerManagement.tsx`.
- **Realtime publication:** `supabase_realtime` publication has 0 tables in it as of 2026-04-21. Cross-site realtime sync silently fails. Fix is `ALTER PUBLICATION supabase_realtime ADD TABLE events, ticket_types, orders, vip_reservations, vip_guest_passes` — but it's a WRITE operation and requires user approval before shipping. See `maguey-bulletproof-sync` for the context.

Before running `supabase db push`, diff the staged migrations against `list_migrations` output and confirm each one is intended. A single unintended migration can deploy weeks of unreviewed schema work.

---

## Mandatory Preflight — BEFORE any commit/push

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — "Running Locally", "Remaining Blockers", constraints.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — current deploy blockers (Stripe prod keys outstanding).
3. Check: `git status`, `git log --oneline -5`, `git branch` — do you know what state you're in?

---

## Step 1: Scope Audit — What changed, what does it touch?

Before staging anything:

```bash
git status
git diff --stat
git diff  # full diff on modified files
```

**Red flags to check:**

1. **Files you didn't intend to change**
   - Did you open a file out of curiosity and accidentally save it? `git diff` will show.
   - Reset those: `git checkout -- <file>`

2. **Large noise**
   - Autoformatter reformatted unrelated code? Separate commits.
   - Generated files (`dist/`, `build/`, `*.log`) — should be gitignored. If tracked, fix .gitignore.

3. **Cross-app bleeding**
   - Working on maguey-pass-lounge but edits show in maguey-gate-scanner or maguey-nights? Intentional? Document in commit message.
   - Working on one app's migration but also touched the other's? Usually a bug.

4. **Sensitive files**
   - `.env*` files — `.env` should NOT be in any commit. Only `.env.example` tracked.
   - Credentials, API keys, tokens — even in comments. Grep: `grep -rn "pk_live\|sk_live\|eyJhbGci\|Bearer " --include="*.ts" --include="*.tsx"` before committing.

5. **Database migrations**
   - New SQL file in `maguey-pass-lounge/supabase/migrations/` or `maguey-gate-scanner/supabase/migrations/`?
   - Is it idempotent? (Can it run twice without error?)
   - Does it have a rollback plan?
   - Is it really separate from the other app? Some cross-app schema changes need both.

6. **Edge Function changes**
   - File in `supabase/functions/**` modified?
   - Deploy requires `supabase functions deploy <name>` — does NOT happen automatically on git push.
   - Flag to user: "Edge Function changed — remember to `supabase functions deploy <name>` after merge."

---

## Step 2: Branch Workflow

**ABSOLUTE RULE:** no direct commits to `main`.

1. Verify current branch: `git branch`
2. If on main, create feature branch first:
   ```bash
   git checkout -b fix/descriptive-slug  # or feature/... for larger work
   ```
3. If already on a feature branch: proceed.

**Branch naming:**
- `fix/<short-slug>` — bugfixes
- `feature/<short-slug>` — new features
- `chore/<short-slug>` — refactors, docs, maintenance
- `hotfix/<short-slug>` — urgent prod fix (fast-track review)

---

## Step 3: Pre-Commit Sanity

Run ALL of these before committing. Any failure = don't commit.

1. **TypeScript compile**
   ```bash
   npm run -w maguey-pass-lounge build
   npm run -w maguey-gate-scanner build
   npm run -w maguey-nights build
   ```
   All 3 should succeed. All 3 have TypeScript strict enabled (per MEMORY.md).

2. **Lint**
   ```bash
   npm run -w maguey-pass-lounge lint  # if script exists
   ```

3. **Unit tests (if changes touch tested code)**
   ```bash
   npm run -w maguey-pass-lounge test
   npm run -w maguey-gate-scanner test
   ```

4. **Don't skip hooks**
   - Never use `git commit --no-verify` or `git push --no-verify` unless the user explicitly asks.
   - If hook fails, FIX the issue. Do not bypass.

---

## Step 4: Commit Message Style

Match recent Maguey commits. Run `git log --oneline -10` to see convention.

**Format:**
```
<type>: <short imperative summary>

<optional body — the WHY, not the WHAT>
```

**Types:**
- `feat` — new feature
- `fix` — bug fix
- `chore` — maintenance
- `docs` — documentation only
- `refactor` — code restructuring, no behavior change
- `perf` — performance
- `test` — tests
- `ci` — CI/CD config

**Examples (real Maguey commits):**
```
fix: resolve CI lint failures in pass-lounge
feat: tier-based bottle service management + wizard step 3
feat: VIP floor plan improvements, event detail page, and UI updates
```

**Bad commit messages to avoid:**
- "update code"
- "fix stuff"
- "WIP"
- "asdf"

---

## Step 5: Stage & Commit

```bash
# Prefer staging specific files:
git add src/pages/Checkout.tsx src/lib/orders/order-creation.ts

# Avoid:
git add -A  # catches junk
git add .   # same issue
```

Commit with HEREDOC for formatting:

```bash
git commit -m "$(cat <<'EOF'
fix: promo code race condition in order saga

The previous implementation allowed promo codes to exceed
usage_limit under concurrent redemption. Added atomic check
in promo-codes.ts via FOR UPDATE lock.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Step 6: Pre-Push Sanity

Before `git push`:

1. **Verify commit looks right**
   ```bash
   git log -1 --stat
   git show HEAD
   ```

2. **Re-run build** if commit introduced any non-trivial changes
   ```bash
   npm run -w <affected-workspace> build
   ```

3. **Running on a feature branch?** Yes → safe to push.
   Pushing to main directly? **STOP.** Confirm with user. Note: pushing to main does NOT auto-deploy anymore — Vercel only sees code after you manually run `./deploy-all.sh`. But policy is still no-direct-to-main; always go through a feature branch + PR.

4. **E2E test sanity** (if significant changes)
   ```bash
   npm run cy:run  # runs Cypress headless
   ```
   If tests fail, FIX before push. Don't push hoping CI will pass.

---

## Step 7: Push

```bash
git push -u origin <branch-name>
```

For first push of a branch, `-u` sets upstream.

---

## Step 8: PR Creation (if merging via GitHub)

Use `gh pr create` with HEREDOC body:

```bash
gh pr create --title "Fix promo code race condition" --body "$(cat <<'EOF'
## Summary
- Atomic promo redemption via FOR UPDATE lock in order saga
- Prevents usage_limit overflow under concurrent redemption

## Changed files
- maguey-pass-lounge/src/lib/orders/order-creation.ts
- maguey-pass-lounge/src/lib/orders/promo-codes.ts

## Test plan
- [x] Unit tests pass
- [x] Ran promo concurrency test locally
- [ ] Reviewer: verify SQL lock visible in DB logs during test

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Step 9: Post-Merge Deploy

Once PR is merged to main:

### Step 9a: Sync local main

```bash
git checkout main && git pull origin main
```

### Step 9b: Vercel prod deploy — MANUAL via CLI (no auto-deploy)

**Auto-deploy is disabled** (GitHub account flag). You MUST run the deploy script from the repo root:

```bash
./deploy-all.sh                          # all 3 apps
./deploy-all.sh maguey-pass-lounge       # only pass-lounge
./deploy-all.sh maguey-gate-scanner      # only gate-scanner
./deploy-all.sh maguey-nights            # only marketing site
```

Scope the deploy to the app(s) that actually changed — if only `maguey-pass-lounge` was touched, don't redeploy the other two. Faster + lower blast radius.

What the script does per app:
1. `cd <ws>` → `vercel pull --environment=production` → `vercel build --prod`
2. Copy `<ws>/.vercel/` to repo root (workaround for Vercel CLI `rootDirectory` path-doubling bug)
3. `vercel deploy --prebuilt --prod --yes` from repo root
4. Clean up `.vercel/` at repo root

Verify each deploy succeeded:
```bash
npx --yes vercel@latest ls maguey-pass-lounge --prod | head -5
npx --yes vercel@latest ls maguey-gate-scanner --prod | head -5
npx --yes vercel@latest ls maguey-nights --prod | head -5
```
Look for `● Ready · Production` at the top. Age should read `<age_seconds>` or `<age_minutes>`.

If a deploy FAILS, investigate build log. Common causes:
- Env var missing in Vercel (check `.env.production.local` in `<ws>/.vercel/` after pull)
- TypeScript strict error caught only in prod build
- Dependency issue (e.g. package-lock out of sync)
- `rootDirectory` not set correctly in Vercel project settings (should be `<ws>`, not empty)

### Supabase Edge Functions (manual deploy required)
If your changes included Edge Function code:
```bash
cd maguey-pass-lounge/supabase
supabase functions deploy create-checkout-session
# or:
supabase functions deploy stripe-webhook
# etc.
```

Verify deploy: check Supabase Dashboard → Edge Functions → [name] → version number updated.

### Supabase Migrations (manual via SQL editor or CLI)
```bash
cd maguey-pass-lounge
supabase db push
```
**GOTCHA:** Maguey uses two separate supabase/migrations directories. Run `db push` from the right workspace.

### Environment variables
- Did your change add a new env var? Update in Vercel (3 projects if applicable) + Supabase Edge Function secrets.
- Don't forget any of the 3 Vercel projects.

### Post-deploy smoke tests
1. Hit marketing site → see events?
2. Hit purchase site → event list loads?
3. Hit scanner login → can sign in?
4. If payments changed: make a test purchase with `testcustomer@maguey.com`
5. Check Sentry / logs for new errors in the 10 min after deploy

---

## Risk Tiers: what requires extra care

### TIER 1 (low risk) — safe to merge with normal review
- UI copy changes, styling tweaks
- Marketing site-only changes
- Non-critical documentation

### TIER 2 (medium risk) — extra review, smoke test after
- Event management UI changes
- Dashboard/analytics tweaks
- Email template changes (send a test email first)
- Non-atomic DB query optimizations

### TIER 3 (high risk) — requires coordinated deploy, staging rehearsal
- Stripe webhook changes
- QR signing logic changes
- Atomic RPC modifications (`create_order_with_tickets_atomic`, `create_vip_reservation_atomic`, etc.)
- RLS policy changes
- Auth flow changes
- Scanner state machine changes
- Schema migrations that alter existing columns

For TIER 3:
1. Merge during off-hours (not during an active event)
2. Test on staging/branch deployment first
3. Monitor logs for 30 min after deploy
4. Have rollback plan ready

---

## Stripe-Specific Caution

Never deploy webhook or checkout changes without:

1. Test with Stripe CLI locally: `stripe listen --forward-to http://localhost:54321/functions/v1/stripe-webhook`
2. Trigger test events: `stripe trigger checkout.session.completed`
3. Verify DB state matches expectation
4. Then deploy

Stripe prod keys switch (remaining P0 blocker per MEMORY.md):
- Coordinated changeover required: update Vercel env var + Supabase Edge Function secrets + Stripe webhook URL — all at once.
- Do NOT switch during an active event.

---

## Rollback Procedures

### Vercel rollback
Vercel Dashboard → Project → Deployments → previous deployment → "Promote to Production". Instant rollback.

### Supabase Edge Function rollback
`supabase functions deploy <name>` again with the previous version's code. Keep git history clean so you can `git checkout <old-sha> -- supabase/functions/<name>/` and redeploy.

### Supabase Migration rollback
Migrations are NOT auto-reversible. Need to write a manual reversal migration. Plan for this BEFORE applying a risky migration.

### Git revert vs reset
- Public branch (pushed/merged): use `git revert <sha>` to create an inverse commit.
- Local unpushed: `git reset --hard <prev-sha>` is fine.
- NEVER force-push main without explicit user approval.

---

## HARD RULES

- **NEVER push directly to main** unless explicitly instructed.
- **NEVER force-push main** without explicit user approval.
- **NEVER skip hooks** (`--no-verify`) unless user explicitly asks.
- **NEVER commit secrets** — grep before committing. `.env` files excluded. `.vercel/` and `.vercel-backup/` contain `.env.production.local` and MUST stay gitignored.
- **NEVER deploy Stripe changes without Stripe CLI test.**
- **NEVER deploy during an active event** — Maguey's weekend nights are live ops.
- **NEVER apply a migration without a rollback plan.**
- **NEVER assume a Vercel deploy happened after a git push** — auto-deploy is dead. `./deploy-all.sh` is the only path to prod.
- **NEVER mention GitHub support ticket / auto-deploy restoration** in reports unless the user brings it up first. The two-command model is the permanent choice.
- **ALWAYS verify `git status` before committing.**
- **ALWAYS re-run build after any file change — TypeScript strict is on across all 3 apps.**
- **ALWAYS run `./deploy-all.sh` after merge to main** if the change affects client-side code in any app. Skip only if the change was migration-only, Edge-Function-only, or docs-only.
- **ALWAYS monitor for 10 min after any deploy.**

---

## When user says "ship it"

Default path: **`./ship.sh`** — one command, detects what changed, deploys everything.

```bash
./ship.sh --dry-run    # see the plan first (optional)
./ship.sh              # run it, with confirmation prompt
./ship.sh --yes        # run it, no prompt (for automation)
```

What ship.sh does:
1. Refuses to run on `main` or with a dirty working tree.
2. Diffs the branch against `origin/main`, figures out what changed.
3. Pushes the branch to GitHub.
4. Deploys every changed Edge Function via `supabase functions deploy`.
5. Applies any new migrations via `supabase db push --include-all` (idempotent — Supabase skips migrations already in `schema_migrations`).
6. Deploys only the Vite apps whose client code actually changed, via `./deploy-all.sh <app>`.
7. Creates a PR via `gh pr create` and squash-merges it via `gh pr merge --squash --delete-branch --admin`.
8. Checks out main, pulls, deletes the local feature branch. Leaves you on a clean main.

Flags:
- `--dry-run` — preview only
- `--yes` — skip confirmation
- `--no-merge` — push + deploy, but don't auto-create or merge the PR (useful when a human review cycle is needed)

Exit code = number of failed sub-deploys. 0 means clean success.
Auto-merge is SKIPPED (not failed) if any earlier step had a failure — script leaves the PR creation for you to do manually after reviewing the failure.

### Fallback: manual step-by-step

Only use the manual procedure (Steps 1–9 above) when:
- `./ship.sh` fails and you need to diagnose why
- You're re-deploying something already shipped (for cache-bust or env-var refresh)
- You need a preview deploy (non-prod)
- You're applying a migration (always manual, via Supabase dashboard or MCP `apply_migration` after review)

For those cases, the commands are:
- **Push:** `git push -u origin <branch>`
- **Vercel:** `./deploy-all.sh [<app>]`
- **Edge Function:** `cd <workspace> && supabase functions deploy <name>`
- **Migration:** review SQL first, then apply via Supabase dashboard or `supabase db push`

Never skip a step. If you're unsure at any step, ask the user.
