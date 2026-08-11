---
name: bulletproof-ship
description: Safely stage, commit, push, and deploy MT Barbershop changes without breaking production. Enforces branch workflow, scope audit, pre-commit parity, commit message style, and pre-push sanity checks. Every push to main auto-deploys to Vercel production — this skill is the last line of defense. Use when the user says "commit this", "push it", "ship it", "merge this", "deploy", or after finishing any code change. Never skips hooks. Never force-pushes main without explicit approval.
---

# Bulletproof Ship

> **Skill family:** WORKFLOW (commit/push/deploy). Not an audit skill. Intentionally uses `preflight-checklist.md`, `commit-message-style.md`, `common-pitfalls.md`, `deploy-infrastructure-state.md`, `post-push-monitoring.md` instead of the audit family's `audit-queries.sql / incidents.md / invariants.md / scale-anti-patterns.md / fix-patterns.md`. Every other `bulletproof-*` skill is audit family — this one is not, and that's deliberate.

Every push to `origin/main` triggers an automatic Vercel production deploy via the LOCAL husky pre-push hook (`.husky/pre-push` → `.husky/vercel-deploy.sh`). A broken push = broken production. A sneaky file in the commit = a feature that shouldn't exist in production. This skill exists because the commit/push layer has been the single biggest source of pain.

This skill READS `CLAUDE.md`, `MEMORY.md`, and `.claude/rules/*.md` and runs a structured protocol. It does NOT replace the husky hooks — it runs the same checks PROACTIVELY so the hook never blocks.

## Deploy Infrastructure State (as of 2026-04-20)

Three deploy paths existed historically. Current state:

| Path | Status |
|---|---|
| Vercel GitHub App auto-deploy | BROKEN (uninstalled 2026-04-17) |
| GitHub Actions `vercel-deploy.yml` | BLOCKED — "Actions has been disabled for this user" at account level. Workflow file, secrets, and repo-level permission are all correct; GitHub itself is rejecting dispatch |
| `.husky/pre-push` → `vercel-deploy.sh` | ONLY WORKING PATH |

Implication: deploys only happen when YOU push from YOUR laptop. A push via the GitHub UI (merge button, edit in web), or from any other machine, will NOT deploy. If the husky hook is ever broken/missing/loses exec bit, production deploys stop silently. See `references/deploy-infrastructure-state.md` for how to check/fix Actions and what to do once it's re-enabled.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/branch-workflow.md` — branching rules
2. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 6, 7, 8, 9
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Code Mirroring
4. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md`

Then run:
```bash
git status
git branch --show-current
git log --oneline -5
```

---

## Choose a Mode

- **prep** — about to commit: audit what's staged/unstaged, verify scope, fix before committing
- **commit** — create a clean commit on the correct branch with a correctly formatted message
- **push** — push to remote safely; if target is `main`, verify production-readiness first
- **merge** — merge a feature branch to `main` after explicit user approval
- **rollback** — recover from a bad push (revert, redeploy, or branch restore)

---

## Dashboard reporting [OPTIONAL — never blocks]

`prep` → `commit` → `push` is drawn as a live pipeline in the RUBRIC dashboard
(Flows tab → "MT Barbershop · Ship"). Report each gate as you reach it:

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 3 "Scanning diff for secrets"
~/Desktop/rubric/tools/flow-event.sh step:complete 3
~/Desktop/rubric/tools/flow-event.sh step:error 3 "sk_live_ key found in .env.local.prod"
```

Step indexes are POSITIONAL and must match the pipeline exactly:

| # | Gate | Section |
|---|---|---|
| 0 | Branch check | prep 1 |
| 1 | Scope audit | prep 2 |
| 2 | Mirror check | prep 3 |
| 3 | Secrets + prod-data sweep | prep 4 and 5 |
| 4 | Pre-commit parity | prep 6 |
| 5 | Commit | commit 1-3 |
| 6 | Pre-push build | push 2 |
| 7 | Push to main | push 3 |
| 8 | Watch deploy + confirm | push 4-5 |

Step 6 also records one **structured QA Run** (RUBRIC → QA Runs tab), bound to the commit
about to be pushed. Unlike the `flow-event.sh` calls above it writes a permanent record, so
it is the one dashboard call whose refusals are worth reading — it prints a single stderr
line when it declines. It still always exits 0 and still never changes what you do.

Rules for these calls:
- They are reporting only. NEVER let one change what you do, and never stop
  because one failed — the script always exits 0 whether the dashboard is
  running or not.
- On any STOP or FAIL, send `step:error` with the reason BEFORE stopping. The
  step turns red and stays red, which is the whole point.
- `merge` mode reports steps 6-8 when it reaches `push` mode.
- `rollback` mode does not report — it is not part of this pipeline.

---

## Mode: prep

Run BEFORE staging. Answer these in order — stop on the first FAIL.

```bash
~/Desktop/rubric/tools/flow-event.sh workflow:start
```

### 1. Branch check [HARD RULE — branch-workflow.md]

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 0 "Checking branch"
git branch --show-current
```

- If `main`: is this change ONLY to `.claude/`, `CLAUDE.md`, or `MEMORY.md`? If not → STOP. Create a feature branch: `git checkout -b (fix|feature|chore)/<description>`.
- If feature branch: verify name matches the work. `fix/...` for bugs, `feature/...` for new work, `chore/...` for maintenance.

```bash
~/Desktop/rubric/tools/flow-event.sh step:complete 0
```

### 2. Scope audit [HARD RULE — debugging-protocol.md §7]

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 1 "Auditing scope"
git status
git diff --stat
```

For every file listed, ask: **"Is this file directly required by what the user asked for?"**

RED FLAGS (stop and ask the user):
- More than 5 files when the task was "fix a bug"
- New files in `src/app/api/**` when not asked to add an endpoint
- New RPCs or migrations in `supabase/migrations/**` without explicit approval
- New hooks in `src/lib/hooks/**` when the task didn't mention one
- Any file whose change isn't explained by the task

Do NOT stage unrelated files. If you see `.env.local`, `.env.local.prod`, `.auth/*`, or `.firecrawl/**` in untracked, leave them.

```bash
~/Desktop/rubric/tools/flow-event.sh step:complete 1
```

### 3. Cross-dashboard mirror check [HARD RULE — context-awareness.md]

If ANY changed file matches `src/app/(dashboard)/barber/**` OR `src/app/(dashboard)/dashboard/my-chair/**`:

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 2 "Checking mirror pages"
git diff --name-only | grep -E '(barber|my-chair)'
```

Verify the equivalent mirror page was also updated. Map:
- `/barber/walk-ins` ↔ `/dashboard/my-chair`
- `/barber/reports` ↔ `/dashboard/my-chair/reports`
- `/barber/clients` ↔ `/dashboard/my-chair/clients`
- `/barber/calendar` ↔ `/dashboard/my-chair/calendar`
- `/barber/schedule` ↔ `/dashboard/my-chair/schedule`
- `/barber/analytics` ↔ `/dashboard/my-chair/analytics`

If only one side changed → STOP. Tell the user "I changed X but didn't mirror to Y. Should I mirror now?"

```bash
~/Desktop/rubric/tools/flow-event.sh step:complete 2
```

### 4. Secrets sweep [CRITICAL]

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 3 "Scanning diff for secrets"
git diff --cached 2>/dev/null; git diff
```

Grep the diff for leaked secrets. BLOCK the commit if any show up:
- `sk_live_` (Stripe live key)
- `VAPID_PRIVATE_KEY=` followed by a value
- `SUPABASE_SERVICE_ROLE_KEY=` followed by a value
- `TWILIO_AUTH_TOKEN=` followed by a value
- `eyJhbGci` at the start of a long string (JWT)
- `.env*` files being staged (unless `.env.example`)

### 5. Production data contamination check [debugging-protocol.md §9]

If the diff touches scripts/, ensure no one-shot INSERT/UPDATE/DELETE against production is in the commit. Test scripts are OK; live-data scripts need explicit user approval.

```bash
~/Desktop/rubric/tools/flow-event.sh step:complete 3
```

### 6. Parity with husky hooks [run manually before committing]

The pre-commit hook runs `npx tsc --noEmit` + `npm run test:check-ids`. Run them FIRST so the hook never blocks you:

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 4 "tsc + test:check-ids"
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
npx tsc --noEmit
npm run test:check-ids
~/Desktop/rubric/tools/flow-event.sh step:complete 4
```

If either fails → fix it BEFORE staging. Never `--no-verify` around a failing check.
Report the failure first: `flow-event.sh step:error 4 "<what failed>"`.

### Output of prep mode

```
## Prep report

### Branch: <name>
- Workflow compliant: [YES/NO + reason]

### Scope (N files)
- In scope: [list]
- Out of scope / questionable: [list with why]

### Mirror pages
- [PASS / file X changed but mirror Y untouched]

### Secrets sweep: [PASS / FAIL]

### Pre-commit parity: [tsc PASS / tsc FAIL, test:check-ids PASS / FAIL]

### Verdict: [SAFE TO COMMIT / BLOCKED — fix above]
```

Stop on any FAIL. Do not stage.

---

## Mode: commit

Runs AFTER `prep` reports SAFE TO COMMIT.

### 1. Stage explicitly

Never `git add -A` or `git add .`. Stage by path:

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 5 "Staging and committing"
git add <file1> <file2> ...
```

This prevents accidentally staging:
- `.env.local.prod`, `.auth/**`, `.firecrawl/**` (already in git status as untracked)
- `.planning/*  2.md` (macOS duplicate files from iCloud sync)
- `*.orig`, `*.patch` leftover from merges
- Test artifacts

### 2. Craft the commit message

Match the style of recent commits (`git log --oneline -20`):

```
<type>(<scope>): <subject — lowercase, imperative, no period>

<optional body: why, not what>
```

Types observed in this repo: `fix`, `feat`, `chore`, `docs`, `ci`, `merge`.

Scopes observed: `queue`, `schedule`, `dashboard`, `dashboard/calendar`, `booking`, `notifications`, `sw`, `commissions`, `alerts`, `locations`.

Subject style: short, concrete, describes the bug or the feature — NOT the files touched.

Examples from the log:
- `fix(queue): make walk-in Call/Skip reachable from anywhere + replay-on-mount`
- `feat(locations): add Edwardsville PA as 4th location`
- `fix(sw): bump cache key + network-first for dashboard shells`

### 3. Commit

ALWAYS via HEREDOC (preserves formatting):

```bash
git commit -m "$(cat <<'EOF'
fix(<scope>): <subject>

<body if needed — describe WHY the change was made>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 4. If pre-commit hook fails

**NEVER `--amend` and never `--no-verify`.** The hook not passing means the commit did NOT happen. Fix the underlying error (usually TS errors), re-stage the fix, create a NEW commit.

Report it: `flow-event.sh step:error 5 "pre-commit hook failed: <reason>"`.

### 5. Verify

```bash
git log --oneline -3
git status
~/Desktop/rubric/tools/flow-event.sh step:complete 5
```

---

## Mode: push

**Pushing to `main` = production deploy.** Do NOT skip steps.

### 1. Verify push target

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "no-upstream"
```

- Feature branch with no upstream: `git push -u origin <branch>` is safe. No production impact.
- `main` branch: STOP. Confirm with user: "This will trigger a Vercel production deploy. Proceed?"

### 2. Pre-push sanity (before pushing to main)

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 6 "Local production build"
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"

# Re-run the cheap gates against the COMMITTED tree. Step 4 ran them before
# staging, on a dirty tree — those results describe code that was never
# committed. check-ids takes 0.7s, so re-running it costs nothing.
npx tsc --noEmit;       TSC=$?
npm run test:check-ids; IDS=$?

# Production build (the deploy-breaker — test it locally FIRST).
# PIPESTATUS[0] is MANDATORY. After a pipe, $? is tail's status and is ALWAYS
# 0, so `npm run build 2>&1 | tail -40; B=$?` records a broken build as a pass.
# The :-${pipestatus[1]} fallback is also mandatory: zsh does not define
# PIPESTATUS at all (its array is lowercase and 1-indexed), so the bash-only
# form yields empty in a zsh session and silently loses every build result.
# Skipped entirely if a cheaper gate already failed; BUILD then stays empty,
# which is recorded as "not attempted", never as success.
BUILD=
if [ $TSC -eq 0 ] && [ $IDS -eq 0 ]; then
  npm run build 2>&1 | tail -40
  BUILD=${PIPESTATUS[0]:-${pipestatus[1]}}
fi

# One structured QA Run against the commit that is about to be pushed. This is
# the only place it can be honest: at step 4 the commit did not exist yet and
# the tree was dirty, so there was nothing truthful to bind the evidence to.
# Results come from the exit codes above, NEVER from your reading of the
# output. Set QA_TASK_ID first if this ship closes a Sprint task; never guess
# one. The script exits 0 whatever happens and refuses to record at all if the
# tree is dirty or HEAD is detached.
export QA_TASK_ID=B-0003   # ONLY if this ship closes a Sprint task. Never guess one.
~/Desktop/rubric/tools/qa-run.sh --auto-commit --project mt-barbershop --env local \
  --check-exit "typecheck:npx tsc --noEmit:$TSC" \
  --check-exit "lint:npm run test:check-ids:$IDS" \
  --check-exit "build:npm run build:$BUILD"

~/Desktop/rubric/tools/flow-event.sh step:complete 6
```

If `npm run build` fails locally, the Vercel deploy WILL fail. Do not push. Fix first.
Report it first: `flow-event.sh step:error 6 "build failed: <first error>"`.

Run the `qa-run.sh` call even when a gate fails — a recorded `fail` against a known commit
is the point. Do not hand-write `--check-exit` values: passing a literal `:0` for a command
you did not run is the free-text QA problem in a structured costume.

For high-stakes changes (touching `/api/**`, auth, payments, queue state machine), optionally run:
```bash
npm run predeploy   # runs scripts/pre-deploy-check.ts
```

### 3. Push

For a feature branch:
```bash
git push -u origin <branch>
```

For `main` (after explicit approval):
```bash
~/Desktop/rubric/tools/flow-event.sh step:start 7 "Pushing to main"
git push origin main
~/Desktop/rubric/tools/flow-event.sh step:complete 7
```

### 4. Watch the Vercel deploy

The pre-push hook fires a background deploy and logs to `/tmp/mt-vercel-autodeploy.log`:

```bash
~/Desktop/rubric/tools/flow-event.sh step:start 8 "Waiting on Vercel deploy"
tail -f /tmp/mt-vercel-autodeploy.log
```

Or briefly:
```bash
sleep 20 && tail -60 /tmp/mt-vercel-autodeploy.log
```

Watch for:
- `Error:` anywhere in the output
- `Build Failed`
- Final `deploy finished (exit 0)` = success
- Final `deploy finished (exit 1)` = FAILURE, production untouched but deployment blocked

On `exit 1`: `flow-event.sh step:error 8 "deploy failed: <reason from log>"`.

### 5. Confirm production

Only after `exit 0` in the deploy log, and only for changes with user-visible impact:
- Open `https://mtbarbershop.com` (or the affected route) and verify the change is live.
- For SW changes, remind the user to hard-refresh (Cmd+Shift+R) on their open tabs.

Then close the run out:

```bash
~/Desktop/rubric/tools/flow-event.sh step:complete 8
~/Desktop/rubric/tools/flow-event.sh workflow:complete
```

---

## Mode: merge

Feature branch → `main`. Only after explicit user approval (branch-workflow.md).

### 1. Sync main first

```bash
git checkout main
git pull origin main
git checkout <feature-branch>
git rebase main    # or merge main if rebase is risky
```

Resolve conflicts by UNDERSTANDING them — never `--theirs` or `--ours` blindly.

### 2. Verify the feature branch builds

```bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
npx tsc --noEmit && npm run build
```

### 3. Merge

```bash
git checkout main
git merge --no-ff <feature-branch>
```

`--no-ff` preserves the branch history (matches observed "Merge branch 'fix/...'" style in the log).

### 4. Push main

Follow `push` mode steps 1-5. This is when the deploy fires.

### 5. After successful deploy, optionally delete the branch

```bash
git branch -d <feature-branch>
git push origin --delete <feature-branch>
```

Only do this with user approval — destructive branch deletion is not auto-authorized.

---

## Mode: rollback

Something broke production. Fastest safe path:

### 1. Identify the bad commit

```bash
git log --oneline -10
```

### 2. Revert (NOT reset — main is shared)

```bash
git revert <bad-sha>            # creates an undo-commit
git push origin main            # triggers auto-deploy with the revert
```

This is what happened for incident 6d4e4ff → ad99107 (MEMORY.md). Revert, do not reset.

### 3. Watch the deploy log

Same as `push` mode step 4. Verify `exit 0`.

### 4. Confirm production is restored

Open the affected route. Check Sentry for new errors.

### 5. Open a new branch for the real fix

Do NOT retry the original change on `main`. Branch off, fix properly, re-open via `merge` mode.

---

## HARD RULES

- NEVER `git add -A` or `git add .` — always stage by path.
- NEVER `--no-verify` or `--no-gpg-sign` — if a hook fails, fix the underlying issue.
- NEVER `--amend` an already-pushed commit.
- NEVER `git reset --hard` on `main` or any pushed branch.
- NEVER force-push `main`. Feature branches can force-push after rebase if the user requested a rebase.
- NEVER commit directly to `main` unless the change is strictly `.claude/`, `CLAUDE.md`, or `MEMORY.md` (branch-workflow.md exception).
- NEVER commit `.env*` files (except `.env.example`), `.auth/**`, `.firecrawl/**`, `* 2.*` macOS iCloud duplicates.
- NEVER commit without reading the staged diff.
- NEVER push to `main` without running `npx tsc --noEmit` and `npm run build` locally first.
- NEVER skip the Vercel deploy log check after pushing to `main`.
- If the commit includes more files than the task required, STOP and ask.
- If the diff touches a mirror page on only one side, STOP and ask about mirroring.
- Stay in scope. A commit does not need cleanup.
