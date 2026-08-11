# Commission — Fix Patterns

Paste-ready diffs for commission / fee system bugs. Every pattern maps to a real incident in `incidents.md` or an invariant in `invariants.md`. Commission data is revenue-critical — these patterns are LOCKED to code-level changes only. No pattern in this file writes to the production database. If a fix ever requires a write, the pattern routes it through an explicit user-approval gate per `.claude/rules/debugging-protocol.md` §9.

All patterns assume:
- `createAdminClient` imported from `@/lib/supabase/admin`
- `determinePaymentRouting` imported from `@/lib/stripe/connect-helpers`
- Fee writes go through `determinePaymentRouting()` — NEVER inline `0.30` or `flat_rate` math
- `mcp__supabase-mt__` is the only MCP client used for SELECT verification

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode in `SKILL.md` runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "Before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Run the audit query cited in the pattern. Classify as **live** (real rows affected now — urgent) vs **latent** (no rows yet — preventive). User decides urgency from this.
3. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`. If the fix would modify any row in `walkin_fee_config`, `cash_fee_ledger`, `barber_payouts`, or `service_transactions`, ALSO state the exact row count and IDs — `.claude/rules/debugging-protocol.md` §9 applies.
4. **Apply** — Single `Edit` call. One pattern per invocation.
5. **Verify** — Run the pattern's post-fix verification (grep + tsc, plus SQL if live). Every check must pass. Re-run the audit query — violating row count must be 0 (or ≤ pre-fix count if cleanup is user-driven).
6. **Mirror** — Commission touches both owner and barber dashboards. If the pattern says mirror matters, invoke `mirror-check` before handoff.
7. **Handoff** — Stop at `bulletproof-ship`. Do not commit. Do not deploy.

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Route completion handlers through `determinePaymentRouting()` for Connect split

**When:** A Connect-enabled barber's card/link transaction lands with `fee_settlement_status = 'pending'` instead of `'auto_split'`. Triggered by audit query #17 returning ≥1 row. Cites incident "Connect Routing Never Fires (2026-04-20)" and invariant C7.

**Before (broken — 4 files identical pattern):**
```ts
// src/app/api/queue/entry/[id]/route.ts (~line 400)
// src/app/api/queue/complete/route.ts (~line 170)
// src/app/api/bookings/[id]/route.ts (~line 370)
// src/app/api/bookings/quick-complete/route.ts (~line 150)

const ownerFee = service_amount * feeConfig.owner_percentage / 100
const barberNet = service_amount - ownerFee
const feeStatus = payment_method === 'cash' ? 'cash_owed' : 'pending' // hardcoded
```

**After (correct — delegates to single source of truth):**
```ts
import { determinePaymentRouting } from '@/lib/stripe/connect-helpers'

const routing = await determinePaymentRouting({
  barberId: currentEntry.assigned_barber_id,
  serviceAmount: service_amount,
  paymentMethod: payment_method, // 'cash' | 'card' | 'link'
})

// routing returns { ownerFeeAmount, barberNetAmount, feeSettlementStatus, useConnect, stripeAccountId }
// feeSettlementStatus will be 'auto_split' when barber has Connect + card/link,
// 'cash_owed' for cash, 'pending' for card/link without Connect.

const updates = {
  owner_fee_amount: routing.ownerFeeAmount,
  barber_net_amount: routing.barberNetAmount,
  fee_settlement_status: routing.feeSettlementStatus,
  // ...
}
```

**Post-fix verification:**
- `grep -rn "determinePaymentRouting" src/app/api/ | wc -l` → ≥6 matches (4 completion handlers + checkout + send-link)
- `grep -rn "fee_settlement_status.*===.*cash.*cash_owed.*pending" src/app/api/` → 0 matches (no hardcoded status literals)
- Re-run audit query #17: Connect-enabled barbers with zero `auto_split` → 0 rows (once a new txn has been processed)
- `npx tsc --noEmit` → no new errors
- **Do NOT backfill old rows.** Historical `pending` rows for Connect barbers are the other incident (pre-Connect accruals) — handled via final payout, not SQL UPDATE.

---

## Pattern 2 — Read fee config from DB, never hardcode rates

**When:** Grep finds `0.30`, `30%`, `0.3 *`, or `flatRate = 40` in application code. Cites invariant C6.

**Before (broken):**
```ts
// src/lib/stripe/connect-helpers.ts or any inline math elsewhere
const ownerFee = serviceAmount * 0.30
const flatRate = 40
```

**After (correct — read from single-row config table):**
```ts
const admin = createAdminClient()
const { data: feeConfig, error } = await admin
  .from('walkin_fee_config')
  .select('owner_percentage, flat_rate, apply_to_owner_cuts, is_active')
  .limit(1)
  .single()

if (error || !feeConfig || !feeConfig.is_active) {
  // Fail closed — do NOT default to a hardcoded rate
  throw new Error('fee config unavailable')
}

const ownerFee = Math.round(serviceAmount * (feeConfig.owner_percentage / 100) * 100) / 100
```

**Post-fix verification:**
- `grep -rn "0\.30\|\\* 0\.3\\b\|30%\|flat_rate\s*=\s*40\|flatRate\s*=\s*40" src/app/ src/lib/` → 0 matches inside commission code paths
- SELECT config: `SELECT owner_percentage FROM walkin_fee_config LIMIT 1;` → 30 (per MEMORY.md 2026-03-23)
- `npx tsc --noEmit` → no new errors
- Scope note: comments, test fixtures, or unrelated UI constants that just happen to contain "30" are OK — only flag code paths that compute a fee.

---

## Pattern 3 — Honor `apply_to_owner_cuts = false` in `determinePaymentRouting()`

**When:** Data query #12 finds `cash_fee_ledger` rows with `barber_id = 'b0010000-0000-0000-0000-000000000001'` and `status = 'owed'` despite `walkin_fee_config.apply_to_owner_cuts = false`. Cites invariant 12 and the "apply_to_owner_cuts flag" incident surface.

**Before (broken — flag ignored):**
```ts
// src/lib/stripe/connect-helpers.ts
export async function determinePaymentRouting({ barberId, serviceAmount, paymentMethod }) {
  const feeConfig = await loadFeeConfig()
  const ownerFeeAmount = serviceAmount * (feeConfig.owner_percentage / 100)
  // ... rest of function ...
}
```

**After (correct — owner exempt when flag is off):**
```ts
const OWNER_BARBER_ID = 'b0010000-0000-0000-0000-000000000001'

export async function determinePaymentRouting({ barberId, serviceAmount, paymentMethod }) {
  const feeConfig = await loadFeeConfig()

  // Owner exemption — hardcoded ID, honors config flag
  const isOwnerBarber = barberId === OWNER_BARBER_ID
  const exemptByConfig = isOwnerBarber && feeConfig.apply_to_owner_cuts === false

  const ownerFeeAmount = exemptByConfig
    ? 0
    : Math.round(serviceAmount * (feeConfig.owner_percentage / 100) * 100) / 100

  const barberNetAmount = serviceAmount - ownerFeeAmount
  // ... rest unchanged ...
}
```

**Post-fix verification:**
- `grep -rn "OWNER_BARBER_ID\|b0010000-0000-0000-0000-000000000001" src/lib/stripe/` → ≥1 match
- Re-run audit query #12 — expected 0 rows
- `npx tsc --noEmit` → no new errors
- **Do NOT delete existing `cash_fee_ledger` rows for the owner** in the same fix. That's a production write — requires separate §9 approval with exact row IDs and count.

---

## Pattern 4 — Grace period read uses Eastern Time, not UTC

**When:** A new barber within their 30-day window has booking fees applied. Cites incident "Grace Period Shows Expired When It Shouldn't" plus the Booksy Timezone HARD RULE in MEMORY.md.

**Before (broken — `new Date()` compared raw to timestamp):**
```ts
const { data: barber } = await admin
  .from('barbers')
  .select('grace_period_ends_at, employment_type')
  .eq('id', barberId)
  .single()

const graceActive = barber.grace_period_ends_at
  && new Date(barber.grace_period_ends_at) > new Date() // raw UTC compare; OK because both are UTC
  // BUT: if grace was set using local-date math, the END of the grace day may be off
```

**After (correct — explicit Eastern "now" for comparison, matches how UI displays it):**
```ts
import { createAdminClient } from '@/lib/supabase/admin'

const { data: barber } = await admin
  .from('barbers')
  .select('grace_period_ends_at, employment_type, created_at')
  .eq('id', barberId)
  .single()

// grace_period_ends_at is a TIMESTAMPTZ; comparison to now() is safe in SQL.
// If the check happens in JS, compare as Dates (both are UTC under the hood).
// Do NOT rebuild the date using toISOString().split('T')[0] — that returns UTC date, skewing Eastern EOD by up to 4-5 hours.

const now = new Date()
const graceEndsAt = barber.grace_period_ends_at ? new Date(barber.grace_period_ends_at) : null
const graceActive = graceEndsAt !== null && graceEndsAt.getTime() > now.getTime()

if (graceActive && isFirstTimeBookingClient) {
  // No fee during grace
  return { ownerFeeAmount: 0, barberNetAmount: serviceAmount, ... }
}
```

**Post-fix verification:**
- Query specific barber: `SELECT id, grace_period_ends_at, created_at, now() < grace_period_ends_at AS grace_active FROM barbers WHERE id = '<barber-id>'`
- If `grace_period_ends_at IS NULL` for a recently-created barber → separate bug in `src/app/api/auth/create-barber/route.ts` (grace was never set at creation). That's Pattern 5, not this one.
- `grep -rn "toISOString().split('T')\[0\]\|toTimeString().slice" src/lib/stripe/connect-helpers.ts src/app/api/commission/` → 0 matches
- `npx tsc --noEmit` → no new errors

---

## Pattern 5 — Set `grace_period_ends_at` at barber creation

**When:** A newly-created barber has `grace_period_ends_at IS NULL` and their booking clients already incur fees. Cites incident "Grace Period Shows Expired When It Shouldn't".

**Before (broken — grace never set):**
```ts
// src/app/api/auth/create-barber/route.ts
const { data: barber } = await admin.from('barbers').insert({
  profile_id: profile.id,
  chair_number,
  employment_type: 'contractor',
  // grace_period_ends_at never set — NULL
}).select().single()
```

**After (correct — 30-day default grace at creation):**
```ts
const GRACE_PERIOD_DAYS = 30
const graceEndsAt = new Date()
graceEndsAt.setDate(graceEndsAt.getDate() + GRACE_PERIOD_DAYS)

const { data: barber } = await admin.from('barbers').insert({
  profile_id: profile.id,
  chair_number,
  employment_type: 'contractor',
  grace_period_ends_at: graceEndsAt.toISOString(),
}).select().single()
```

**Post-fix verification:**
- `grep -n "grace_period_ends_at" src/app/api/auth/create-barber/route.ts` → ≥1 match in the INSERT
- After creating next test barber, SELECT confirms `grace_period_ends_at` is ~30 days after `created_at`
- `npx tsc --noEmit` → no new errors
- **Do NOT backfill existing barbers via UPDATE.** That's a production write — requires explicit §9 approval with the list of barber IDs to update.

---

## Pattern 6 — Waive endpoint updates all three tables atomically

**When:** Incident "Waive Didn't Propagate" — owner waives a fee, it disappears from one surface but not another. Cites invariant C3.

**Before (broken — only one table updated):**
```ts
// src/app/api/commission/waive/route.ts
await admin
  .from('service_transactions')
  .update({ fee_settlement_status: 'waived', waived_by: user.id, waived_at: new Date().toISOString() })
  .eq('id', transactionId)
// source row + cash_fee_ledger never updated
```

**After (correct — three tables in one logical unit):**
```ts
const waivedAt = new Date().toISOString()

// 1. Update service_transactions
const { error: txErr } = await admin
  .from('service_transactions')
  .update({
    fee_settlement_status: 'waived',
    waived_by: user.id,
    waived_at: waivedAt,
  })
  .eq('id', transactionId)
if (txErr) throw txErr

// 2. Update the source row (queue_entries OR bookings)
if (tx.queue_entry_id) {
  const { error: qErr } = await admin
    .from('queue_entries')
    .update({ fee_settlement_status: 'waived' })
    .eq('id', tx.queue_entry_id)
  if (qErr) throw qErr
} else if (tx.booking_id) {
  const { error: bErr } = await admin
    .from('bookings')
    .update({ fee_settlement_status: 'waived' })
    .eq('id', tx.booking_id)
  if (bErr) throw bErr
}

// 3. Update cash_fee_ledger (if a row exists — only for cash payments)
const { error: ledgerErr } = await admin
  .from('cash_fee_ledger')
  .update({
    status: 'waived',
    settled_by: user.id,
    settled_at: waivedAt,
    notes: reason || 'waived by owner',
  })
  .match({
    barber_id: tx.barber_id,
    ...(tx.queue_entry_id ? { queue_entry_id: tx.queue_entry_id } : { booking_id: tx.booking_id }),
  })
if (ledgerErr) throw ledgerErr
```

**Post-fix verification:**
- Re-run invariants 8 + 9 — every `waived` row has `waived_by` + `waived_at` populated; every `settled`/`waived` ledger row has `settled_by` + `settled_at`
- For a recently-waived transaction, SELECT all three tables with the same ID and confirm `fee_settlement_status = 'waived'` across all three
- `npx tsc --noEmit` → no new errors
- **True atomicity requires a Postgres transaction.** Supabase JS client does not support multi-statement transactions — wrap via RPC (`CREATE FUNCTION waive_commission(...) LANGUAGE plpgsql`) for real atomicity. Propose this as a follow-up; don't create the RPC in this fix without explicit user approval per HARD RULE §7.

---

## Pattern 7 — Payout endpoint rejects overpayment and non-positive amounts

**When:** Invariant 11 (no overpayment per barber) flags rows, OR a test payout succeeds with `amount = 0` or `amount > owed`. Cites invariant C4.

**Before (broken — no validation):**
```ts
// src/app/api/commission/payout/route.ts
const { amount, barberId, payoutMethod } = await req.json()
const { error } = await admin.from('barber_payouts').insert({
  barber_id: barberId,
  amount,
  payout_method: payoutMethod,
  created_by: user.id,
})
```

**After (correct — validates against live owed balance):**
```ts
const { amount, barberId, payoutMethod, notes } = await req.json()

// Validate amount
if (typeof amount !== 'number' || amount <= 0) {
  return NextResponse.json({ error: 'amount must be > 0' }, { status: 400 })
}
if (!['venmo', 'zelle', 'cash', 'bank_transfer', 'other'].includes(payoutMethod)) {
  return NextResponse.json({ error: 'invalid payout_method' }, { status: 400 })
}

// Compute live owed — must match invariant 11 formula exactly
const { data: earnedRows } = await admin
  .from('service_transactions')
  .select('service_amount, owner_fee_amount, tip_amount')
  .eq('barber_id', barberId)
  .in('payment_method', ['card', 'link'])
  .neq('fee_settlement_status', 'auto_split')
  .eq('payment_status', 'paid')

const gross = (earnedRows || []).reduce(
  (sum, r) => sum + (r.service_amount - r.owner_fee_amount + (r.tip_amount ?? 0)),
  0
)

const { data: paidRows } = await admin
  .from('barber_payouts')
  .select('amount')
  .eq('barber_id', barberId)

const alreadyPaid = (paidRows || []).reduce((sum, r) => sum + r.amount, 0)
const owed = gross - alreadyPaid

// Small floating-point tolerance
if (amount > owed + 0.01) {
  return NextResponse.json({ error: `overpayment: owed $${owed.toFixed(2)}` }, { status: 400 })
}

// OK — record the payout (accounting only; does NOT move money)
const { error } = await admin.from('barber_payouts').insert({
  barber_id: barberId,
  amount,
  payout_method: payoutMethod,
  notes: notes ?? null,
  created_by: user.id,
})
```

**Post-fix verification:**
- Re-run invariant 11 — 0 overpaid rows
- `grep -n "amount\s*<=\s*0\|overpayment" src/app/api/commission/payout/route.ts` → ≥2 matches
- Test via curl (READ-ONLY preview — do NOT insert): POST with `amount: -5` → 400; `amount: 999999` → 400 if no barber is actually owed that much
- `npx tsc --noEmit` → no new errors

---

## Pattern 8 — Cash fee insert paths wrap ledger INSERT in try/catch + owner_alert

**When:** Audit query #1 finds cash `service_transactions` rows with no matching `cash_fee_ledger` row. Cites invariant C5 and the Ledger A bullet list.

**Before (broken — silent failure swallows the missing row):**
```ts
// src/app/api/queue/entry/[id]/route.ts (~line 407) and 3 sibling files
await admin.from('cash_fee_ledger').insert({
  barber_id: currentEntry.assigned_barber_id,
  queue_entry_id: currentEntry.id,
  fee_amount: routing.ownerFeeAmount,
  status: 'owed',
  notes: 'walk-in cash completion',
})
// No error handling — if this throws, the completion still succeeds and the ledger row is missing forever
```

**After (correct — insert is attempted, failure is alerted, completion never blocks):**
```ts
try {
  const { error: ledgerErr } = await admin.from('cash_fee_ledger').insert({
    barber_id: currentEntry.assigned_barber_id,
    queue_entry_id: currentEntry.id,
    fee_amount: routing.ownerFeeAmount,
    status: 'owed',
    notes: 'walk-in cash completion',
  })
  if (ledgerErr) throw ledgerErr
} catch (err) {
  // Do not block the service completion — but surface the drift
  await admin.from('owner_alerts').insert({
    type: 'commission_ledger_insert_failed',
    title: 'Cash ledger row missing',
    message: `Completion for queue_entry ${currentEntry.id} succeeded but cash_fee_ledger insert failed: ${(err as Error).message}`,
    related_id: currentEntry.id,
  })
  console.error('[commission] cash_fee_ledger insert failed', err)
}
```

**Post-fix verification:**
- Re-run audit query #1 — 0 rows (for transactions completed AFTER the fix; historical misses require separate cleanup)
- `grep -rn "from('cash_fee_ledger').insert" src/app/api/` → 4 matches (all 4 completion handlers)
- `grep -rn "commission_ledger_insert_failed" src/app/api/` → 4 matches (one per handler)
- `npx tsc --noEmit` → no new errors
- **Do NOT INSERT missing historical rows via SQL.** That's a production write on revenue data — explicit §9 approval required with exact (barber, transaction, amount) list.

---

## Pattern 9 — Stripe webhook idempotency check before processing

**When:** A Stripe event is processed twice (duplicate `barber_payouts` row, double-charge, duplicate service_transactions). Cites invariant C2.

**Before (broken — no dedup):**
```ts
// src/app/api/webhooks/stripe/route.ts
export async function POST(req: NextRequest) {
  const sig = req.headers.get('stripe-signature')!
  const rawBody = await req.text()
  const event = stripe.webhooks.constructEvent(rawBody, sig, process.env.STRIPE_WEBHOOK_SECRET!)

  // Process event directly — no check for prior processing
  if (event.type === 'checkout.session.completed') {
    await handleCheckoutCompleted(event.data.object)
  }
  // ...
}
```

**After (correct — check + record via `stripe_webhook_events`):**
```ts
const admin = createAdminClient()

// Idempotency guard
const { data: prior } = await admin
  .from('stripe_webhook_events')
  .select('id')
  .eq('stripe_event_id', event.id)
  .maybeSingle()

if (prior) {
  // Already processed — return 200 so Stripe stops retrying
  return NextResponse.json({ received: true, duplicate: true })
}

// Record BEFORE processing so a crash mid-handler doesn't allow reprocessing
const { error: recordErr } = await admin.from('stripe_webhook_events').insert({
  stripe_event_id: event.id,
  event_type: event.type,
  processed_at: new Date().toISOString(),
})
if (recordErr) {
  // A unique-constraint violation = another concurrent request just took this event; exit cleanly
  if (recordErr.code === '23505') {
    return NextResponse.json({ received: true, duplicate: true })
  }
  throw recordErr
}

// Now process
if (event.type === 'checkout.session.completed') {
  await handleCheckoutCompleted(event.data.object)
}
```

**Post-fix verification:**
- `grep -n "stripe_webhook_events" src/app/api/webhooks/stripe/route.ts` → ≥2 matches (SELECT + INSERT)
- SELECT for duplicates: `SELECT stripe_event_id, COUNT(*) FROM stripe_webhook_events GROUP BY stripe_event_id HAVING COUNT(*) > 1` → 0 rows
- `npx tsc --noEmit` → no new errors
- Migration 036 must be applied (creates the table + unique index on `stripe_event_id`).

---

## Pattern 10 — `/api/barber/cash-fees` POST settle path requires owner role

**When:** Any non-owner can mark a cash fee as settled, short-circuiting the reconciliation flow. Cites HARD RULE §9 (write protection on commission tables) and the Ledger A bullet list.

**Before (broken — any authenticated user):**
```ts
// src/app/api/barber/cash-fees/route.ts
export async function POST(req: NextRequest) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

  const { ledgerId } = await req.json()
  await admin.from('cash_fee_ledger').update({ status: 'settled', settled_at: new Date().toISOString(), settled_by: user.id }).eq('id', ledgerId)
}
```

**After (correct — owner-only):**
```ts
const supabase = await createClient()
const { data: { user } } = await supabase.auth.getUser()
if (!user) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

const { data: profile } = await supabase
  .from('profiles')
  .select('role')
  .eq('id', user.id)
  .single()

if (profile?.role !== 'owner') {
  return NextResponse.json({ error: 'Forbidden' }, { status: 403 })
}

const { ledgerId } = await req.json()
if (!ledgerId) return NextResponse.json({ error: 'ledgerId required' }, { status: 400 })

const admin = createAdminClient()
const { error } = await admin
  .from('cash_fee_ledger')
  .update({
    status: 'settled',
    settled_at: new Date().toISOString(),
    settled_by: user.id,
  })
  .eq('id', ledgerId)
  .eq('status', 'owed') // defensive — don't re-settle a waived row
if (error) throw error
```

**Post-fix verification:**
- `grep -n "role.*===.*owner\|profile\.role !== 'owner'" src/app/api/barber/cash-fees/route.ts` → ≥1 match
- Test as a barber: POST to endpoint → 403
- Test as owner: POST with valid ledgerId → 200
- Re-run invariant 8 — settled rows all have `settled_by` + `settled_at`
- `npx tsc --noEmit` → no new errors

---

## Cross-pattern rules

1. **Never write to production commission tables in a fix.** `walkin_fee_config`, `cash_fee_ledger`, `barber_payouts`, `service_transactions`, `daily_summaries` are all revenue-critical. Code changes only. If a fix requires a data cleanup, route through §9 explicit approval.
2. **Never hardcode fee rates.** Always read from `walkin_fee_config`.
3. **`determinePaymentRouting()` is the single source of truth** for fee math. Every fee-writing code path must call it.
4. **Connect-enabled barbers should see `auto_split` on card/link.** Anything else means Pattern 1 is needed.
5. **Owner barber exempt only when `apply_to_owner_cuts = false`.** Hardcoded ID `b0010000-0000-0000-0000-000000000001` — not the dev owner.
6. **Eastern Time everywhere.** Grace periods, daily_summaries aggregation windows, fee config `updated_at` display. UTC is the storage, Eastern is the business day.
7. **Stripe webhook events are idempotent** via `stripe_webhook_events.stripe_event_id`.
8. **Commission fixes NEVER mirror blindly.** Owner dashboard and barber dashboard read commission data from the SAME endpoints — the fix is in the API, not in both UIs. Only invoke `mirror-check` if the fix adds a new UI element.

---

## When adding a NEW commission code path

Checklist:
1. Does it touch fee math? → Must call `determinePaymentRouting()`.
2. Does it touch `cash_fee_ledger`? → Wrap in try/catch + `owner_alerts` on failure (Pattern 8).
3. Does it touch `service_transactions.fee_settlement_status`? → Use the enum values (`'pending' | 'cash_owed' | 'auto_split' | 'settled' | 'waived'`), never a raw string.
4. Is it a waive path? → Three-table atomic update (Pattern 6).
5. Is it a payout path? → Validate amount > 0 and ≤ live owed (Pattern 7).
6. Is it a Stripe webhook handler? → Idempotency check first (Pattern 9).
7. Is it a settlement mutator? → Owner-role gate (Pattern 10).
8. Does it add a new fee-related column? → Add matching invariant in `invariants.md` and audit query in `audit-queries.sql`.

If any of these is "no," stop and confirm with the user before shipping.
