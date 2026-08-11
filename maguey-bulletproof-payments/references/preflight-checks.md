# Preflight Checks — Full Protocol

Run these verifications BEFORE any audit, diagnose, or code change. Each check catches a class of problem that will otherwise waste time or ship broken code. The preflight in `SKILL.md` lists the quick version; this file is the full reference.

## Table of Contents
1. [Schema reality check (SQL)](#1-schema-reality-check)
2. [Base-file parse check (Deno)](#2-base-file-parse-check)
3. [Disk vs. deployed verification](#3-disk-vs-deployed-verification)
4. [Stripe Dashboard endpoint config](#4-stripe-dashboard-endpoint-config)
5. [Test suite sanity](#5-test-suite-sanity)
6. [Scanner status cross-check](#6-scanner-status-cross-check)

---

## 1. Schema reality check

The project's migrations drift from documentation. Before trusting any query, verify the columns exist.

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('webhook_idempotency', 'webhook_events',
                     'revenue_discrepancies', 'saga_executions', 'orders',
                     'tickets', 'vip_reservations', 'email_queue')
ORDER BY table_name, ordinal_position;
```

Cross-reference the result against `invariants.md` → "Schema Reality Check". If a column listed there is now missing, or a new column appears that isn't documented, update `invariants.md` before proceeding. Stale schema notes produce audit findings that look real but aren't.

**Why:** Two sessions in a row, audit queries failed or fix templates used columns that don't exist (`orders.stripe_payment_intent_id`, `orders.refunded_at`, `payment_failures` table). Running this upfront ends that entire class of error.

---

## 2. Base-file parse check

Before proposing ANY edit to `stripe-webhook/index.ts`, verify the file currently parses:

```bash
deno check maguey-pass-lounge/supabase/functions/stripe-webhook/index.ts 2>&1 | tail -10
```

Interpret the result:
- **"source code could not be parsed"** → STOP. The file has a structural error. Fix it (or flag it) before inserting anything new. Proposing additions to broken code produces misleading diffs and deployment failures.
- **Type errors only (`TS1xxx`, `TS2xxx`, `TS18xxx`)** → Proceed. The file parses; these are pre-existing type lints that don't block deploy. Record the count so the post-edit delta can be compared.
- **Clean** → Proceed.

If `deno` is unavailable, fall back to `npx esbuild --loader:.ts=ts <file> --outfile=/tmp/o.js --bundle=false`. Esbuild catches the same structural errors.

**Why:** This session burned a full round trip proposing a `charge.refunded` insertion into a file that had been brace-unbalanced since commit `34d12975` (2026-04-08). The error message ("Expected ',' got 'catch'") looked like my edit caused it, but `git checkout` on the file reproduced it identically. Checking parse before editing turns that 30-minute detour into a 5-second discovery.

---

## 3. Disk vs. deployed verification

The file on disk may not be what's actually serving webhooks. Before concluding that a gap exists in production (or that a fix has landed), confirm which version Supabase is running.

Options, in order of directness:
1. **Supabase CLI:** `supabase functions list --project-ref djbzjasdrwvbsoifxqzd` (shows deployed version id + updated_at)
2. **Git:** `git log --oneline -5 -- maguey-pass-lounge/supabase/functions/stripe-webhook/index.ts` compared against deploy date
3. **Live probe:** `curl https://djbzjasdrwvbsoifxqzd.supabase.co/functions/v1/stripe-webhook -I` — the response headers sometimes expose function version
4. **Stripe Dashboard:** pick a recent webhook delivery and inspect the response body/latency shape; a production handler logs `Webhook signature verified` via structured JSON

When a deploy is stale, every audit finding is suspect — the disk version might have fixes that never shipped, or the live version might behave differently than the code suggests. Flag the mismatch to the user; do not silently infer from disk alone.

**Why:** The charge.refunded discovery conversation assumed disk = prod. If the prod deploy was older (pre-4.6 webhook changes), the "gap" might already be resolved and we'd be patching a file that doesn't run. Always verify.

---

## 4. Stripe Dashboard endpoint config

Code that consumes an event type is useless if Stripe isn't configured to send it. Verify the webhook endpoint subscription list.

```
Stripe Dashboard → Developers → Webhooks → [endpoint URL] → Listening for
```

Required events for the current handler:
- `checkout.session.completed` (GA tickets)
- `payment_intent.succeeded` (VIP + GA fallback)
- `charge.refunded` (once the refund handler ships)
- `charge.dispute.created` (once dispute handling ships — see `disputes.md`)
- `payment_intent.payment_failed` (once customer-notification ships)

If a handler was added to code but the event isn't enabled on the Stripe endpoint, it will never fire. This is a silent failure — logs show nothing because nothing arrives.

**How to check without Dashboard access:** inspect `webhook_events` + `webhook_idempotency` for the event_type. No rows over 30 days = Stripe isn't sending it OR there's no traffic. Q11 in `audit-queries.sql` (event type distribution) is the proxy.

**Why:** Adding a handler is half the work. The config-side half is easy to forget, and the failure mode (silence) is the hardest to debug later.

---

## 5. Test suite sanity

Run the existing tests before and after any change:

```bash
cd maguey-pass-lounge && npm run test -- stripe-webhook 2>&1 | tail -20
```

MEMORY.md claims "86 tests in 2 files (2026-04-07)". Verify the count hasn't drifted. If tests fail **before** an edit, the baseline is broken — surface that first. If tests fail **after** an edit that was clean before, the edit is the cause.

A full suite run also catches the structural parse issue from §2 indirectly: broken imports and parse errors usually break test runs first.

**Why:** Relying on `deno check` alone misses behavior regressions. The 86 tests encode actual expected behavior; running them validates a change hasn't regressed the GA or VIP happy path.

---

## 6. Scanner status cross-check

The webhook writes `tickets.status`. The scanner decides whether to accept a ticket. If they disagree, refunded tickets still scan green.

```bash
grep -nE "ticket\.status|tickets\.status|status.*['\"](active|refunded|cancelled|scanned|valid)['\"]" \
  maguey-gate-scanner/src/lib/simple-scanner.ts \
  maguey-gate-scanner/src/lib/scanner-service.ts
```

Expected: scanner rejects any status other than the "active-equivalent" set (currently only flags `status === 'scanned'` as already-scanned; does NOT reject `refunded` or `cancelled`). This is a **cross-skill concern** — fixing the scanner belongs to `maguey-bulletproof-scanner`, but this skill must VERIFY the contract before writing a status the scanner ignores.

If the scanner only checks a narrow set, either:
- Write a status value the scanner already rejects (e.g., some projects use `is_used=true` + `voided_at` timestamp)
- OR flag as a cross-skill dependency and stop; delegate scanner fix before shipping the refund handler

**Why:** This skill writes `tickets.status = 'refunded'` assuming the scanner rejects it. As of 2026-04-21 the scanner only rejects `status === 'scanned'`. A refunded ticket still scans green at the door, which is exactly the customer-trust failure this skill exists to prevent. Scoping out this check makes the whole refund handler cosmetic.
