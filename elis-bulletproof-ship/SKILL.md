---
name: elis-bulletproof-ship
description: Safely stage, commit, push, and deploy Eli's Dulce Tradicion changes without breaking production. elisbakery.com is LIVE with real Stripe live-mode payments. Every push to `main` auto-deploys to Vercel. This skill enforces branch workflow, scope audit, pre-commit parity (tsc + lint + build + real-browser smoke for UI), commit message style, pre-push sanity, separate path for Supabase Edge Function deploys (supabase functions deploy <name>) and for migrations (apply manually via Supabase dashboard or `supabase db push`). Use when the user says "commit this", "push it", "ship it", "deploy", "merge this" OR after finishing any code change. Never skips hooks. Never force-pushes main without explicit approval. Never deploys Stripe-related changes without a dry-run against test mode first.
---

# Eli's Bulletproof Ship

**Production status:** elisbakery.com is LIVE. Real customers. Real Stripe live-mode payments against account `CBUpHY3Zt3`. A bad push means a real customer can't order a cake.

This skill is the last line of defense before a deploy. Use it every time. Skipping it is how prod breaks.

---

## The deploy topology

**One app, three deploy surfaces:**

1. **Vercel frontend** — `git push origin main` auto-deploys from GitHub. No separate command.
2. **Supabase Edge Functions** — NOT auto. `supabase functions deploy <name> --project-ref rnszrscxwkdwvvlsihqc`
3. **Supabase migrations** — NOT auto. Apply explicitly via `supabase db push` OR via Supabase Dashboard → SQL editor. Never auto — every migration is a deliberate act.

**Backend (Express, `backend/`):** unclear production role (see `elis-bulletproof-dashboard` invariant #3). Before assuming "the backend is deployed," check. If it's not deployed, do not change things that require its deploy.

---

## Mandatory Preflight — BEFORE any commit/push

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — deploy overview.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-elis-dulce-tradicion/memory/MEMORY.md` — Live-mode reminder; "Always run `npm run build` before pushing".
3. Run:
   ```bash
   git status
   git log --oneline -5
   git branch --show-current
   ```
   Know what state you're in before you do anything.
4. State: "Preflight complete. Running ship checks."

---

## Step 1 — Scope Audit

Before staging anything:

```bash
git status
git diff --stat
git diff        # full diff on modified files
```

### Red flags to check

1. **Files you didn't intend to change.** `dev-dist/sw.js`, `dev-dist/sw.js.map`, stray `CLAUDE.md` edits, `.firecrawl/` artifacts. Reset: `git checkout -- <file>` (confirm first).
2. **Autoformatter noise.** If your editor reformatted an unrelated file, separate commits — don't bundle noise with a real change.
3. **Secrets or `.env`**. `git diff -- .env .env.local backend/.env` — if anything shows, STOP. Verify .gitignore covers these, `git rm --cached` the leak.
4. **Migration files touched alongside unrelated code.** Migrations must ship in their own, intentional commit — never "oh and also this migration."
5. **Edge Function changes bundled with UI changes.** They deploy separately. If both changed, the two deploys must both happen — easy to forget the function.

---

## Step 2 — Pre-commit Parity

Run these and make sure they pass before staging:

```bash
# TypeScript compile check — catches type errors that Vite dev mode hides
npx tsc --noEmit

# Lint
npm run lint

# Production build — catches bundle-time issues
npm run build
```

If any fail, stop. Fix, then re-check.

For UI changes: **spin up the dev server and actually click through the change in a browser.** Tests verify code correctness, not feature correctness. CLAUDE.md user preference: "If you can't test the UI, say so explicitly rather than claiming success."

---

## Step 3 — Stripe safety gate (if Stripe code changed)

If the diff touches any of:
- `supabase/functions/create-payment-intent/index.ts`
- `supabase/functions/stripe-webhook/index.ts`
- `src/pages/PaymentCheckout.tsx`
- `src/components/payment/StripeCheckoutForm.tsx`
- `src/pages/OrderConfirmation.tsx`
- `backend/routes/payments.js` or `backend/routes/webhooks.js`
- Anything using `Stripe` or `pk_*` / `sk_*`

Then:

1. **Confirm `.env` local has `pk_test_*`**, not pk_live. Do not test against live.
2. **Run the flow in local dev** end-to-end: place an order → pay with test card 4242... → confirm webhook arrives (Stripe CLI: `stripe listen --forward-to localhost:...`).
3. **In Stripe Dashboard → Test mode**, verify PaymentIntent shows the expected metadata.
4. **Never** copy a production webhook secret to local.
5. **NEVER** run test charges against the `sk_live_*` key — one typo and you have a real $60 charge to refund.

If any of this is skipped, the change doesn't ship.

---

## Step 4 — Branch workflow

MEMORY.md says `main` auto-deploys. Therefore:

- **Feature / fix work:** a branch. `fix/<scope>-<desc>` or `feature/<scope>-<desc>`. Example: `fix/orders-idempotency-key`, `feature/walkin-calendar-view`.
- **Trivial docs-only:** may go direct to main, but still through a commit — never amend/rebase published commits.
- **NEVER force-push main.** If a bad commit landed, create a revert commit instead.
- **NEVER rebase** a branch that has been pushed.

If the user says "push to main directly," ask once: "This auto-deploys to prod. Confirm?" Proceed only on explicit yes.

---

## Step 5 — Commit message style

Recent commits (`git log --oneline -5`) are the template:

```
feat(front-desk): walk-in orders, calendar view, baker ticket card, auto-confirm settings
feat(dashboards): complete dashboard enhancement plan — Phases A–E
perf(hero): preload video from public/ to eliminate loading gap
feat(emails): brand all emails with Eli's dark luxury theme
feat(testimonials): animated mobile carousel with per-card unique angles
```

Pattern: `<type>(<scope>): <what changed in present tense>`. Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `chore`. Scope: `orders`, `payments`, `front-desk`, `dashboards`, `emails`, `auth`, `inventory`, `hero`, `home`, etc.

Commit message via HEREDOC to preserve formatting:

```bash
git commit -m "$(cat <<'EOF'
fix(payments): add idempotency key to create-payment-intent invocation

Client-side retry on slow network was creating duplicate PaymentIntents.
Pass order_id as the Stripe idempotency key so a retried request returns
the original PaymentIntent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Step 6 — Pre-push sanity

One last check before `git push`:

```bash
git log origin/main..HEAD --oneline   # what are we actually pushing?
git diff origin/main..HEAD --stat     # what's the blast radius?
```

If you see:
- More commits than you remember making → someone else pushed, or you didn't pull. `git fetch`, review, decide.
- Files you didn't intend to push → stop, surgery needed.

---

## Step 7 — Deploying Edge Functions (if any changed)

If the diff touched `supabase/functions/*/index.ts`:

```bash
# Deploy one function
supabase functions deploy stripe-webhook --project-ref rnszrscxwkdwvvlsihqc

# Or deploy multiple
supabase functions deploy create-payment-intent send-order-confirmation --project-ref rnszrscxwkdwvvlsihqc
```

Verify secrets are set BEFORE deploying:
```bash
supabase secrets list --project-ref rnszrscxwkdwvvlsihqc
```

Required secrets (from the email skill + payment skill): `RESEND_API_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `FROM_EMAIL`, `FROM_NAME`, `OWNER_EMAIL`, `FRONTEND_URL`, plus Supabase's automatic `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`.

After deploy, tail logs to confirm:
```bash
supabase functions logs stripe-webhook --project-ref rnszrscxwkdwvvlsihqc
```

Then trigger a real test event (place a test order in local dev pointing at prod webhook? No — use Stripe CLI `trigger`).

---

## Step 8 — Applying migrations (if any changed)

If the diff touched `supabase/migrations/*.sql`:

**DO NOT auto-apply via `git push`.** There is no auto-apply — which is deliberate.

Review the migration SQL. For each, decide:
- Is it additive (CREATE TABLE, ADD COLUMN, CREATE INDEX)? Low risk.
- Is it destructive (DROP COLUMN, DROP TABLE, ALTER TYPE that changes existing values)? HIGH risk — confirm with user before proceeding.
- Does it touch RLS on `orders` / `user_profiles` / `payments`? Revenue-critical — extra review.

Apply explicitly:
```bash
# Via Supabase CLI (recommended if you have the link set up)
supabase db push --project-ref rnszrscxwkdwvvlsihqc

# Or via Supabase Dashboard → SQL Editor → paste the migration text
```

After applying:
```sql
SELECT * FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 5;
```
Confirm the new version shows up.

---

## Step 9 — After deploy verification

For a Vercel-frontend change:
```bash
# Wait ~1 minute for Vercel to finish building
npx vercel ls                # confirm the new deploy is listed
# Open elisbakery.com in a fresh browser tab (clear cache / hard refresh)
# Smoke-test the feature you just shipped
```

For an Edge Function change:
- Trigger the function (via the app flow, not by curl alone — the full path matters).
- `supabase functions logs <name>` — confirm 200s and no errors.

For a migration:
- Run a query that touches the new schema.
- Confirm the UI that depends on it renders.

---

## Integration with other skills

| Trigger | Skill |
|---|---|
| Change touches order wizard | `elis-bulletproof-orders` first (audit before ship) |
| Change touches Stripe | `elis-bulletproof-payments` MUST approve first |
| Change touches front desk kitchen | `elis-bulletproof-frontdesk` smoke test |
| Change touches owner dashboard | `elis-bulletproof-dashboard` smoke test |
| Change touches an Edge Function email | `elis-bulletproof-emails` validation |
| Change touches auth | `elis-bulletproof-auth` audit first |
| Change touches products / ingredients / recipes | `elis-bulletproof-inventory` audit |

If a change crosses two or three of these, route through each before shipping.

---

## HARD RULES

- **NEVER push directly to main without a branch** unless the change is docs-only AND the user explicitly approved.
- **NEVER force-push to main.** Revert commit is the path.
- **NEVER skip hooks** (`--no-verify`) unless the user explicitly asked. If a hook fails, fix the underlying issue.
- **NEVER deploy Stripe-related code** without a test-mode dry run. Live-mode is not a place for experiments.
- **NEVER apply a migration** as a side effect of a push. Migrations are always explicit.
- **NEVER run `seed-admin-users.js` or `seed-frontdesk-user.js` against prod.** They stomp credentials.
- **NEVER commit `.env` / `backend/.env`.** Check every diff.
- **NEVER amend a pushed commit.** Create a new commit instead.
- **NEVER mark a task "shipped" until the post-deploy smoke test passes** on elisbakery.com.
- **If in doubt, stop and ask the user.** One specific question with a proposed next step.
