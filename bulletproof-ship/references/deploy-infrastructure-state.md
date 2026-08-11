# Deploy Infrastructure State

Captured 2026-04-20. Update this file when any of the three paths changes state.

---

## The three deploy paths

### 1. Vercel GitHub App integration — BROKEN

Uninstalled on 2026-04-17. Reason unknown. No plan to reinstall right now.

### 2. GitHub Actions `vercel-deploy.yml` — BLOCKED at account level

The workflow is correctly configured:
- File: `.github/workflows/vercel-deploy.yml` committed in `f55dae2` (2026-04-19)
- Triggers: `push.branches: [main]` + `workflow_dispatch`
- Required secrets: `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID` — all set on repo
- Repo-level Actions permission: `enabled: true`
- Workflow registered and active in the Actions API

BUT: `gh workflow run vercel-deploy.yml --ref main` returns:
```
HTTP 422: Actions has been disabled for this user.
```

AND: total workflow runs for the entire repo = 0 (even the February `e2e.yml` has never fired).

This is an account-level lock, not a repo-level issue.

### 3. `.husky/pre-push` local hook — WORKING, only path

Files:
- `.husky/pre-push` — triggers on push to `origin/main`, fires a detached background script
- `.husky/vercel-deploy.sh` — runs `vercel deploy --prod --yes`, logs to `/tmp/mt-vercel-autodeploy.log`
- Both are LOCAL-ONLY (listed in `.git/info/exclude`, not shipped to other clones)

---

## How to diagnose Actions state

```bash
# Check repo-level Actions permission
gh api 'repos/LuisMiguel13ad/MT-Barbershop-Systems/actions/permissions'
# Want: "enabled": true

# Check workflow is registered and active
gh api 'repos/LuisMiguel13ad/MT-Barbershop-Systems/actions/workflows'
# Want: vercel-deploy.yml listed with "state": "active"

# Check secrets exist
gh secret list
# Want: VERCEL_TOKEN, VERCEL_ORG_ID, VERCEL_PROJECT_ID

# Check run history
gh api 'repos/LuisMiguel13ad/MT-Barbershop-Systems/actions/runs' --jq '.total_count'
# If 0 after pushes to main → Actions is not firing

# Test account-level block directly (the smoking gun)
gh workflow run vercel-deploy.yml --ref main
# If "Actions has been disabled for this user." → account-level block
```

---

## How to unblock Actions (when the user is ready)

User must do these — not Claude:

1. **Spending limit:** Visit `https://github.com/settings/billing/spending_limit`. If Actions spend limit is $0, raise it (public repos are free but the limit can still block).
2. **Account Actions toggle:** Visit `https://github.com/settings/actions`. Look for any toggle disabling Actions. Enable it.
3. **Policy flag:** If both above look fine and the 422 error persists, contact GitHub Support. "Actions has been disabled for this user" with a correctly configured repo typically means an admin flag was set on the account (abuse detection false positive, TOS dispute, etc.). Only GitHub can remove it.

After unblocking, verify by:
```bash
gh workflow run vercel-deploy.yml --ref main
# Should succeed with no error
gh run list --workflow=vercel-deploy.yml --limit 3
# Should show the run queued / in_progress / completed
```

---

## Once Actions is working: what changes

When `vercel-deploy.yml` can actually run:

1. **Husky hook becomes redundant.** Two deploys would fire on every push (one from GH Actions, one from the laptop). Remove the husky side:
   - Delete `.husky/pre-push` and `.husky/vercel-deploy.sh`
   - Remove entries from `.git/info/exclude`
   - Commit as `chore(ci): remove local husky deploy hook now that GH Actions deploys main`
2. **Source of truth for deploy logs shifts.** Stop tailing `/tmp/mt-vercel-autodeploy.log`. Use instead:
   ```bash
   gh run list --workflow=vercel-deploy.yml --limit 5
   gh run view <run-id> --log
   ```
3. **Deploys no longer depend on Luis's laptop.** GitHub UI merges, PRs, reverts via web — all auto-deploy.
4. **Update `SKILL.md` § "Deploy Infrastructure State"** to reflect the new state.

---

## Until then: what the skill enforces

While Actions is blocked:

- `push` mode assumes the husky hook is the deploy path
- Post-push monitoring = tail `/tmp/mt-vercel-autodeploy.log`
- If a push to `main` doesn't show up in the log within ~30 seconds, something is wrong with the hook:
  ```bash
  # Diagnose
  ls -la .husky/pre-push .husky/vercel-deploy.sh
  # Both should exist and have -x (exec) bits

  cat .git/info/exclude
  # Should list both files

  which vercel
  # Should resolve via nvm
  ```
- If the hook is broken and can't be fixed quickly, fall back to manual deploy:
  ```bash
  export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh"
  vercel deploy --prod --yes
  ```

---

## Never do this

- NEVER delete `.husky/pre-push` or `.husky/vercel-deploy.sh` while GH Actions is still blocked — production loses its only deploy path.
- NEVER assume a push to main deployed without confirming via the log (or `mtbarbershop.com` check).
- NEVER try to "fix" the Actions 422 error from the Claude side. Only the user can resolve account-level locks via GitHub's UI or support.
