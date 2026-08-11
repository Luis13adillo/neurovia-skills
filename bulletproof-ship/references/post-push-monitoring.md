# Post-Push Monitoring

Every push to `origin/main` triggers an automatic Vercel production deploy via `.husky/pre-push` → `.husky/vercel-deploy.sh`. The deploy runs in the background. The log is at `/tmp/mt-vercel-autodeploy.log`.

**This means: your push is not "done" when git returns. It's done when the deploy succeeds.**

---

## 1. Watch the deploy log

### Option A — follow live

```bash
tail -f /tmp/mt-vercel-autodeploy.log
```

Press Ctrl-C when you see `deploy finished (exit 0)` or `exit 1`.

### Option B — check after a delay

```bash
sleep 60 && tail -80 /tmp/mt-vercel-autodeploy.log
```

A typical Vercel build for this repo takes 2-4 minutes.

---

## 2. What success looks like

```
[Thu ... 2026] push abc1234 to origin/main — starting Vercel deploy
Vercel CLI 32.x.x
🔍  Inspect: https://vercel.com/<team>/<project>/<deployment-id>
✅  Production: https://mtbarbershop.com [...]
[Thu ... 2026] deploy finished (exit 0)
```

Key signals:
- `exit 0` at the end = success
- `Production:` line includes the live URL
- No `Error:` or `Build Failed` lines above

---

## 3. What failure looks like

```
Error: Command "npm run build" exited with 1
...
error during build:
  Type error: ...
[Thu ... 2026] deploy finished (exit 1)
```

Common causes:
- TypeScript error that slipped past `tsc --noEmit` (e.g., it only errors in production mode with `NODE_ENV=production`)
- Missing env var on Vercel (set locally but not in project settings)
- Import of a dev-only dependency
- Route handler missing `export const dynamic = 'force-dynamic'`
- Circular import only triggered by production build

**IMPORTANT:** A failed deploy leaves production ON THE LAST SUCCESSFUL DEPLOY. It does NOT break prod immediately. But it does mean your change isn't live — and the next successful push will include it.

---

## 4. Post-deploy verification

After `exit 0`:

### 4.1 Hit the affected route
```bash
curl -sI https://mtbarbershop.com/<affected-path> | head -5
```
Look for `200 OK` or appropriate status.

### 4.2 Check Sentry
Open `https://sentry.io/organizations/<org>/issues/?project=<project>`. Look for any NEW issues in the last 5 minutes that reference code you just changed.

### 4.3 Remind user about caching
If your change touched a PWA-relevant file (service worker, manifest, any page under `/dashboard/` or `/barber/`):
- Tell the user to hard-refresh (Cmd+Shift+R) any open tabs.
- Tell the user if SW cache key was bumped, the new SW will activate on next page load.

### 4.4 For high-stakes changes
Routes worth a manual browser check:
- `/api/queue/entry/[id]` → trigger a walk-in assignment in owner dashboard
- `/api/bookings/availability` → open `/book` and pick a date
- `/api/push/subscribe` → confirm barber notification still arrives
- Any auth-adjacent route → try login with dev owner account

---

## 5. If the deploy fails

1. Read the error in the log.
2. Branch back from `main` if you already pushed to main:
   ```bash
   git checkout -b fix/<what-broke>
   ```
3. Fix locally. Run `npm run build` to confirm it now passes.
4. Commit with a `fix:` prefix.
5. Merge back to main (`merge` mode) and push.

Do NOT retry the original push — you need a new commit with the fix.

---

## 6. If the deploy succeeded but production is broken

Different from a failed deploy. Here: Vercel says success, but the live site misbehaves.

This is usually:
- A runtime error the build didn't catch (e.g., env var read at request-time is missing)
- A database column/RPC the build assumed exists but doesn't in prod
- A stale CDN cache

Immediate action:
1. Check Sentry for new errors.
2. Check the Vercel Functions log for the affected route.
3. If the problem is clearly caused by the latest deploy, use `rollback` mode.

Do NOT silently retry or "try a different fix." Revert first, investigate second.

---

## 7. Rollback command summary

```bash
# Revert the bad commit (safe — creates a new commit)
git revert <bad-sha>

# Push the revert (triggers auto-deploy of the previous state)
git push origin main

# Watch the revert deploy
tail -f /tmp/mt-vercel-autodeploy.log
```

Recorded precedent: commit 6d4e4ff (2026-03-20) was reverted via `git revert` → ad99107.
