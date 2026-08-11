# Common Ship Pitfalls — MT Barbershop

Real issues that have caused commit/push/deploy pain. If any sound familiar, you're in this category.

---

## 1. Committing to `main` by accident

**Symptom:** `git status` shows "On branch main" but you were supposed to be on a feature branch.

**Fix before pushing:**
```bash
# Move your last commit to a new branch
git branch fix/my-change
git reset --hard HEAD~1        # only safe because the commit wasn't pushed yet
git checkout fix/my-change
```

If you already pushed to `main`, do NOT reset. Use `rollback` mode: `git revert <sha>` + re-branch.

---

## 2. `git add .` / `git add -A` pulled in untracked junk

**Symptom:** Commit includes `.env.local.prod`, `.auth/user.json`, `.firecrawl/*`, `*.planning/*  2.md` (macOS iCloud sync duplicates), `*.orig`, or `*.patch`.

**Fix (before commit):**
```bash
git restore --staged <bad-file>
```

**Prevention:** ALWAYS stage by path:
```bash
git add src/app/api/queue/entry/[id]/route.ts src/lib/queue/assign.ts
```

If you have many related files, stage them one group at a time, reviewing `git status` between groups.

---

## 3. macOS iCloud duplicates (`* 2.md`)

**Symptom:** `git status` shows files like `.planning/STATE 2.md`, `.planning/REQUIREMENTS 2.md`, etc.

These are iCloud sync conflicts. They're NOT supposed to be committed. Never stage them.

```bash
# Optional: delete them locally (reversible via iCloud)
find .planning -name '* 2.*' -print   # review first
find .planning -name '* 2.*' -delete  # only if you're sure
```

---

## 4. Pre-commit hook blocks you with `BLOCKED: TypeScript errors`

**Symptom:**
```
Running pre-commit checks...
  [1/2] TypeScript type check...
[lots of TS errors]
BLOCKED: TypeScript errors found. Fix them before committing.
```

**Wrong response:** `git commit --no-verify`. DO NOT do this. You will break production.

**Right response:** Read the errors. Fix them. Re-stage. Commit again.

Most common causes:
- New Zod schema missing a field used elsewhere
- Supabase query selecting a column that doesn't exist in generated types
- Hook return type changed, callers not updated
- Enum value added in one file, not mirrored in dependent type

---

## 5. Pre-commit hook blocks you with `BLOCKED: Real barber IDs`

**Symptom:**
```
FAIL: Real barber ID 'b0010000-...' found in test files:
tests/some-test.ts:42:  barber_id: 'b0010000-0000-0000-0000-000000000001'
```

**Fix:**
```ts
// Wrong
barber_id: 'b0010000-0000-0000-0000-000000000001'

// Right
import { TEST_OWNER_BARBER_ID } from './utils/database'
barber_id: TEST_OWNER_BARBER_ID
```

See `tests/utils/database.ts` for all test ID constants.

---

## 6. Vercel build fails after a push that passed `tsc --noEmit` locally

**Symptom:** `npx tsc --noEmit` passes → you push → Vercel build fails with a type error.

**Root cause:** `tsc --noEmit` uses your dev tsconfig. `next build` uses production config with stricter rules (e.g., checks on JSX types, ESLint rules, production-only import paths).

**Fix:** Always run `npm run build` locally before pushing to `main`.

```bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
npm run build
```

If the build passes locally but fails on Vercel:
- Environment variable missing on Vercel (set in project settings)
- Case-sensitive import path (macOS is case-insensitive, Linux Vercel is not)
- Peer-dep mismatch (different Node version — check `engines` in package.json)

---

## 7. Pushed to main but the change isn't live

**Symptom:** Commit is in `main` on GitHub, but `mtbarbershop.com` doesn't reflect the change.

**Diagnose:**
```bash
# Did the pre-push hook fire?
tail -40 /tmp/mt-vercel-autodeploy.log

# Is the deploy still in progress?
ps aux | grep -i vercel
```

If no log entry for your push: the hook didn't fire. Possible causes:
- You pushed while on a different branch then merged via GitHub (no local pre-push ran)
- Hook got deleted (`ls -la .husky/`)
- Hook file lost exec bit (`chmod +x .husky/pre-push`)

**Manual deploy from your machine:**
```bash
export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
vercel deploy --prod --yes
```

---

## 8. SW cache makes old code linger on users' devices

**Symptom:** You pushed a fix. Deploy succeeded. You test it and it still shows the old behavior.

**Cause:** `public/sw.js` caches aggressively. Users (and you) get the old cached code until the SW cache key changes.

**Fix the code:** Bump the cache key in `public/sw.js` on any deploy that touches a cached route.

**Fix the symptom:** Hard refresh (Cmd+Shift+R on Mac, Ctrl+Shift+R on Windows). Or DevTools → Application → Service Workers → Unregister.

**Commit precedent:** `fix(sw): bump cache key + network-first for dashboard shells` (307421c).

---

## 9. Scope creep caught at commit time

**Symptom:** `git status` shows 30 files changed for what was supposed to be "fix one button color."

**Cause:** Section 7 violation — you drifted from the task and kept making changes.

**Response:** STOP. Do NOT commit the bloat.

Options:
1. **Selective commit:** Stage only the files actually related to the task. Stash or discard the rest.
   ```bash
   git add <the-3-files-that-matter>
   git commit -m "fix(<scope>): <what>"
   git stash -u   # parks the rest for later review
   ```
2. **Split into multiple branches:** If several unrelated fixes are mixed, cherry-pick them into separate branches.
3. **Tell the user:** "I got off-scope. I'll commit just the X change and ask about Y and Z separately."

---

## 10. Force-push fear

**Symptom:** Feature branch has messy commits; you want to clean up before merging.

**Safe path:**
```bash
git checkout <feature-branch>
git rebase -i <base-commit>   # interactive rebase to squash/reword
git push --force-with-lease origin <feature-branch>   # NOT --force
```

`--force-with-lease` refuses to overwrite if someone else pushed in the meantime. Always use it over `--force`.

**NEVER force-push `main`.** Ever.

---

## 11. Merged a broken PR

**Symptom:** Merged feature branch to `main` → Vercel deploy fails → prod is not broken (still on last success) but now `main` contains broken code.

**Fix:**
```bash
git revert -m 1 <merge-commit-sha>  # -m 1 tells revert to pick mainline
git push origin main                 # triggers auto-deploy of the revert
```

Then fix the feature branch properly and re-merge.

---

## 12. Pushed a migration file without applying to production Supabase

**Symptom:** Code deploys successfully, but runtime errors "column X does not exist" or "function Y does not exist."

**Root cause:** Migration file committed + deployed, but nobody ran it against prod Supabase.

**Fix:**
```bash
# For MT Barbershop specifically, migrations live in /supabase/migrations
# Apply via Supabase MCP:
# Use mcp__supabase-mt__apply_migration with the file contents
```

NOTE: Applying migrations requires explicit user approval per HARD RULES. Never auto-apply.

**Prevention:** In `prep` mode, flag any diff that adds files to `supabase/migrations/` and ask the user: "Has this migration been applied to prod?"
