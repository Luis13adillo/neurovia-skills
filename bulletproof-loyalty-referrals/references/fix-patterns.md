# Loyalty & Referrals — Fix Patterns

Paste-ready diffs for every gap category. When `audit` or `diagnose` mode flags a failure, point to the pattern here and the user gets a concrete change. These patterns are canonical — if you deviate, document why.

All patterns assume:
- `createAdminClient` from `@/lib/supabase/admin` for any server-side path that runs without an authed Supabase session (webhooks, crons)
- `createClient` from `@/lib/supabase/server` for authed API routes (owner/barber context)
- `mcp__supabase-mt__execute_sql` is the ONLY SQL tool — never `mcp__supabase__`
- Loyalty schema uses `current_punches` / `total_punches_earned` — NOT `punches_count` / `rewards_earned` (CLAUDE.md doc drift, see `incidents.md`)
- Gift card schema uses `original_amount` (NOT `initial_balance`) and `transaction_type IN ('purchase','redemption','refund')` (NOT 'redeem')
- Upsell schema uses `base_service_id` / `suggested_addon_id` (NOT `trigger_service_id`/`suggested_service_id`)

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Schema verify** — Run the schema verification query from `SKILL.md` preflight. Confirm live column names match the pattern. If the DB is on `original_amount` but a referenced doc says `initial_balance` → the DOC is stale; trust the DB.
2. **Preflight** — Read the target file. Match the pattern's "Before" block against current code exactly (imports, RPC names, table names, column names). If ANY differs → STOP. Report what differs. Do NOT apply a stale pattern.
3. **Classify** — Run the paired invariant query from `audit-queries.sql` / `invariants.md`. Report live drift (rows returned > 0) vs latent (0 rows, code-only smell). User decides urgency.
4. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`.
5. **Apply** — Single `Edit` call. One pattern per invocation.
6. **Verify** — Run the pattern's post-fix verification (grep + tsc, plus SQL if live drift). Every check must pass.
7. **NO PRODUCTION WRITES during verification.** Reads only. If a live probe requires a write, stop and request explicit approval per Section 9 of `debugging-protocol.md`.
8. **Handoff** — Stop at `bulletproof-ship`. Do not commit.

If any step fails, stop and report. Do not proceed.

---

## Pattern 1 — Replace inline `UPDATE customer_loyalty` with `add_loyalty_punch` RPC

**When:** `grep -rn "from('customer_loyalty').*update\|UPDATE customer_loyalty" src/` returns any hit that increments `current_punches` directly.

**Symptom:** Concurrent service completions for the same client race. Customer has 2 back-to-back services → only 1 punch lands (see `incidents.md` → "Punch Race Condition").

**Before (broken — race-prone):**
```ts
const { data: existing } = await supabase
  .from('customer_loyalty')
  .select('current_punches, total_punches_earned')
  .eq('client_phone', normalizedPhone)
  .maybeSingle()

if (existing) {
  await supabase
    .from('customer_loyalty')
    .update({
      current_punches: existing.current_punches + 1,
      total_punches_earned: existing.total_punches_earned + 1,
      last_punch_at: new Date().toISOString(),
    })
    .eq('client_phone', normalizedPhone)
} else {
  await supabase.from('customer_loyalty').insert({
    client_phone: normalizedPhone,
    current_punches: 1,
    total_punches_earned: 1,
    last_punch_at: new Date().toISOString(),
  })
}
```

**After (atomic via RPC — serializes via `ON CONFLICT DO UPDATE`):**
```ts
const { data, error } = await supabase.rpc('add_loyalty_punch', {
  p_phone: normalizedPhone,
})
if (error) {
  console.error('Loyalty punch failed (non-blocking):', error)
  // Non-blocking — do not fail the service completion
}
```

**Scope limit:** Replace ONLY the punch-increment block. Do not refactor surrounding service-completion logic. The RPC body is in `supabase/migrations/020_engagement_upsell.sql` lines 140-155 — do NOT alter it.

**Post-fix verification:**
- `grep -rn "from('customer_loyalty').*update\|UPDATE customer_loyalty" src/` → 0 matches outside RPC definition.
- `grep -rn "supabase\.rpc('add_loyalty_punch'" src/` → ≥1 match where the old inline UPDATE lived.
- `npx tsc --noEmit` → no new errors.
- SQL (read-only): re-run invariant 4 (drift check) from `invariants.md`. Drift rows should NOT increase after deploy.

---

## Pattern 2 — Route reward redemption through `redeem_loyalty_reward` RPC

**When:** A handler marks `loyalty_reward_applied = true` and also manually decrements `current_punches` in application code. OR the redemption path skips the decrement entirely (see `incidents.md` → "Reward Redemption Without Punch Decrement").

**Where canonical:** [src/app/api/queue/complete/route.ts:308-310](src/app/api/queue/complete/route.ts) and [src/app/api/bookings/[id]/route.ts:499-502](src/app/api/bookings/[id]/route.ts) already use the RPC. Any new completion path MUST mirror this.

**Before (broken — non-atomic, skips counter):**
```ts
if (loyalty_reward_applied) {
  await supabase
    .from('customer_loyalty')
    .update({ current_punches: 0 })
    .eq('client_phone', normalizedPhone)
  // rewards_redeemed never incremented
}
```

**After:**
```ts
if (loyalty_reward_applied && completedEntry.client_phone) {
  const normalizedPhone = completedEntry.client_phone.replace(/\D/g, '')
  const { error } = await supabase.rpc('redeem_loyalty_reward', {
    p_phone: normalizedPhone,
  })
  if (error) console.error('Redeem failed (non-blocking):', error)
}
```

**Post-fix verification:**
- `grep -rn "redeem_loyalty_reward" src/` → ≥1 match per completion path (queue + bookings + any new surface).
- `grep -rn "current_punches: 0\|current_punches = 0" src/` → 0 matches (the RPC handles decrement).
- SQL: invariant 4 drift check stays flat; customer's `rewards_redeemed` increments by 1 per redeem event.

---

## Pattern 3 — Gift card redemption must be atomic (UPDATE balance + INSERT transaction)

**When:** Any new code path that spends gift card balance. Current `PaymentCollectionModal` sends `gift_card_amount` + `gift_card_id` through to the completion API but the write path must NEVER update `gift_cards.current_balance` without also inserting a `gift_card_transactions` row of type `'redemption'`. See `incidents.md` → "Gift Card Balance Drift".

**Before (broken — UPDATE without transaction row):**
```ts
await supabase
  .from('gift_cards')
  .update({ current_balance: newBalance })
  .eq('id', giftCardId)
```

**After (atomic in one transaction via RPC — add to migration, NOT inline):**

Application code:
```ts
const { data, error } = await supabase.rpc('redeem_gift_card', {
  p_gift_card_id: giftCardId,
  p_amount: amount,
  p_queue_entry_id: queueEntryId ?? null,
  p_booking_id: bookingId ?? null,
})
if (error) throw error  // do NOT silently swallow — this is money
```

RPC (add to a new migration; this RPC does not exist today — flag to user before creating):
```sql
CREATE OR REPLACE FUNCTION redeem_gift_card(
  p_gift_card_id UUID,
  p_amount DECIMAL,
  p_queue_entry_id UUID DEFAULT NULL,
  p_booking_id UUID DEFAULT NULL
) RETURNS gift_cards AS $$
DECLARE
  result gift_cards;
  new_balance DECIMAL;
BEGIN
  SELECT current_balance INTO new_balance
  FROM gift_cards WHERE id = p_gift_card_id FOR UPDATE;

  IF new_balance IS NULL THEN RAISE EXCEPTION 'Gift card not found'; END IF;
  IF new_balance < p_amount THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  UPDATE gift_cards
  SET current_balance = current_balance - p_amount,
      status = CASE WHEN current_balance - p_amount <= 0 THEN 'depleted' ELSE status END,
      updated_at = now()
  WHERE id = p_gift_card_id
  RETURNING * INTO result;

  INSERT INTO gift_card_transactions
    (gift_card_id, transaction_type, amount, balance_after, queue_entry_id, booking_id)
  VALUES
    (p_gift_card_id, 'redemption', p_amount, result.current_balance, p_queue_entry_id, p_booking_id);

  RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Scope limit:** Creating a new RPC + migration requires EXPLICIT user approval (Section 7 of `debugging-protocol.md`). Never apply the migration without approval.

**Post-fix verification:**
- `grep -rn "from('gift_cards').*update" src/` → 0 matches (all redemptions via RPC).
- `grep -rn "transaction_type.*'redeem'" src/` → 0 matches (the string is `'redemption'`, not `'redeem'`).
- SQL invariant 7 (balance math) returns 0 drift rows.
- SQL: `SELECT ... FROM gift_card_transactions WHERE transaction_type = 'redeem'` → 0 (invalid type would fail CHECK anyway, but verify).

---

## Pattern 4 — Referral attribution on conversion (booking/queue completion)

**When:** A booking or queue entry completes with a referral code attached, but `record_referral_event('conversion', ...)` is never called, so `barber_referrals.total_conversions` never increments. See `incidents.md` → "Referral Conversion Not Tracked".

**Canonical paths (already correct):** [src/app/api/bookings/route.ts:515](src/app/api/bookings/route.ts) and [src/app/api/queue/route.ts:574](src/app/api/queue/route.ts) call `record_referral_event`. Any new booking/queue surface MUST mirror.

**Before (broken — silently drops attribution):**
```ts
// Service completed. No referral event fired.
await supabase.from('service_transactions').insert({ ... })
```

**After:**
```ts
// Fire referral conversion BEFORE returning the response
if (referralCode) {
  const { error } = await supabase.rpc('record_referral_event', {
    p_referral_code: referralCode,
    p_event_type: 'conversion',
    p_client_phone: normalizedPhone,
    p_service_amount: serviceAmount,
  })
  if (error) console.error('Referral conversion failed (non-blocking):', error)
}
```

**Scope limit:** Do not alter `record_referral_event` RPC. Do not hand-update `barber_referrals` counters — only the RPC writes to them (invariant C4 in `invariants.md`).

**Post-fix verification:**
- `grep -rn "from('barber_referrals').*update\|UPDATE barber_referrals" src/` → 0 matches.
- `grep -rn "record_referral_event" src/` → ≥3 matches (track click + booking conversion + queue conversion, at minimum).
- SQL invariant 14 (counter math) returns 0 drift rows.
- Manual check: for a test referral code, after a conversion, `referral_events` has a new `conversion` row AND `barber_referrals.total_conversions` increased by 1.

---

## Pattern 5 — Enforce `customer_loyalty.client_phone` uniqueness on upsert

**When:** A code path tries to INSERT a new `customer_loyalty` row without `ON CONFLICT` handling, OR normalizes phone inconsistently across write paths (some strip `+1`, some keep it), producing duplicate rows for the same human.

**Symptom:** Invariant 5 (`UNIQUE(client_phone)`) returns rows — duplicates exist. Happens when one path inserts `"3025551234"` and another inserts `"+13025551234"`.

**Before (broken — inconsistent normalization):**
```ts
// Path A
await supabase.from('customer_loyalty').insert({
  client_phone: phoneInput,  // "+1 (302) 555-1234"
  current_punches: 1,
})

// Path B (different route)
await supabase.from('customer_loyalty').insert({
  client_phone: phoneInput.replace(/\D/g, ''),  // "13025551234"
  current_punches: 1,
})
```

**After (normalize at single helper, use RPC):**
```ts
// Shared helper (create in src/lib/utils/phone.ts if not present)
export function normalizeLoyaltyPhone(input: string): string {
  // Always strip non-digits; the RPC's UNIQUE index matches on this normalized form
  return input.replace(/\D/g, '')
}

// Every write path:
const normalizedPhone = normalizeLoyaltyPhone(rawPhone)
await supabase.rpc('add_loyalty_punch', { p_phone: normalizedPhone })
```

**Scope limit:** If the audit shows existing duplicates in production, DO NOT delete them silently. Report the count and ask the user for a merge strategy. Merging rows is a destructive operation (Section 9 of `debugging-protocol.md`).

**Post-fix verification:**
- `grep -rn "from('customer_loyalty').*insert" src/` → 0 matches (all inserts go through `add_loyalty_punch` RPC which has `ON CONFLICT`).
- `grep -rn "client_phone:" src/app/api/` → every one should be preceded by `normalizeLoyaltyPhone(...)` or inline `.replace(/\D/g, '')`.
- SQL invariant 5 → 0 duplicate rows.

---

## Pattern 6 — Schema drift: `punches_count` → `current_punches`

**When:** Any SQL query (audit, ad-hoc, new hook, analytics route) references `customer_loyalty.punches_count` or `rewards_earned`. These columns DO NOT EXIST. CLAUDE.md has stale doc — the real columns are `current_punches` and `rewards_redeemed` (with `total_punches_earned` for lifetime).

**Symptom:** Query errors with `column "punches_count" does not exist`. OR silent bug if the query is generated dynamically and the missing column is dropped from the SELECT.

**Before (broken):**
```sql
SELECT client_phone, punches_count, rewards_earned
FROM customer_loyalty
WHERE punches_count >= 10;
```

**After:**
```sql
SELECT client_phone, current_punches, rewards_redeemed, total_punches_earned
FROM customer_loyalty
WHERE current_punches >= (SELECT punches_required FROM loyalty_config LIMIT 1);
```

**Scope limit:** Do NOT attempt to "fix" CLAUDE.md from a fix-pattern invocation. That's a separate doc-update task. Just fix the broken query and flag the CLAUDE.md drift in the post-fix report.

**Post-fix verification:**
- `grep -rn "punches_count\|rewards_earned" src/ supabase/` → 0 matches.
- Query runs without error against the live DB.
- Invariants 3, 4, 5 all execute cleanly.

---

## Pattern 7 — Upsell query must filter `is_active = true` AND use correct column names

**When:** A component or API fetches upsell suggestions without the `is_active` filter, OR uses wrong column names (see `incidents.md` → "Upsell Suggestion Wrong Service").

**Schema reality:** `upsell_rules` columns are `base_service_id` and `suggested_addon_id` — NOT `trigger_service_id` / `suggested_service_id` as some older docs/invariants state.

**Before (broken — no active filter, or wrong columns):**
```ts
const { data } = await supabase
  .from('upsell_rules')
  .select('*')
  .eq('trigger_service_id', serviceId)  // wrong column
```

**After:**
```ts
const { data } = await supabase
  .from('upsell_rules')
  .select('id, base_service_id, suggested_addon_id, suggestion_text, display_order')
  .eq('base_service_id', serviceId)
  .eq('is_active', true)
  .order('display_order', { ascending: true })
```

**Post-fix verification:**
- `grep -rn "from('upsell_rules')" src/` → every hit has `.eq('is_active', true)`.
- `grep -rn "trigger_service_id\|suggested_service_id" src/` → 0 matches (old names).
- SQL invariant 17 (active rules reference valid services) returns 0 rows.

---

## Pattern 8 — `PaymentCollectionModal` must skip Stripe charge when `loyalty_reward_applied = true`

**When:** Customer redeems free-cut reward → service completes → `loyalty_reward_applied = true` on the queue entry — but the payment flow still runs a Stripe charge. See `incidents.md` → "Double-Billed Reward Redemption".

**Where:** [src/components/dashboard/PaymentCollectionModal.tsx](src/components/dashboard/PaymentCollectionModal.tsx) and the downstream `/api/queue/complete` / `/api/bookings/[id]` handlers. The completion handler already respects the flag (see `queue/complete/route.ts:225` and `bookings/[id]/route.ts:156`). UI must also guard before calling Stripe.

**Before (broken — charge fires regardless):**
```tsx
const handleCardPayment = async () => {
  await createStripeCheckout({ amount: serviceAmount, ... })
}
```

**After:**
```tsx
const handleCardPayment = async () => {
  if (loyaltyRewardApplied) {
    // Comped — record completion with payment_status='paid' and $0, skip Stripe
    await markCompletedAsComp({ serviceAmount, giftCardCredit })
    return
  }
  await createStripeCheckout({ amount: serviceAmount, ... })
}
```

**Scope limit:** Do not add new UI elements. Do not alter tip buttons. Only gate the Stripe call.

**Post-fix verification:**
- SQL: `SELECT id FROM queue_entries WHERE loyalty_reward_applied = true AND stripe_payment_id IS NOT NULL LIMIT 10` → 0 rows (any hit is a live double-bill).
- SQL: same check against `bookings` → 0 rows.
- Manual: in Stripe dashboard, confirm no charge was created for a test comp.

---

## Cross-pattern rules

1. **NEVER write to production DB from a fix-mode verification step.** All verification is READ-ONLY SQL or grep/tsc. Live probes that require writes need explicit user approval.
2. **ALWAYS normalize phone via `.replace(/\D/g, '')` before RPC calls.** The DB's UNIQUE index is on the normalized form.
3. **NEVER touch `barber_referrals` or `gift_cards` counters directly** — always via RPC or atomic transaction. Invariants C3 and C4.
4. **NEVER add `loyalty_config` rows.** It is a single-row table. If the owner wants to change `punches_required`, warn them it affects all in-flight customers (SKILL.md scale-check section 4).
5. **Silent swallow only for loyalty/referral non-blocking calls.** Gift card balance errors MUST surface — it's money.
6. **One pattern per fix invocation.** If a fix touches 3 files, do 3 invocations.

---

## When adding a NEW loyalty/referral write path

Checklist:
1. Phone normalized via `.replace(/\D/g, '')` before RPC?
2. Loyalty increment via `add_loyalty_punch` (never inline UPDATE)?
3. Loyalty redemption via `redeem_loyalty_reward` (never inline decrement)?
4. Gift card redemption atomic (UPDATE + INSERT in one txn or RPC)?
5. Referral event via `record_referral_event` (never inline counter update)?
6. Upsell query filtered by `is_active = true` with correct column names?
7. Payment path respects `loyalty_reward_applied` flag?
8. Error paths non-blocking for loyalty/referral, loud for gift cards?

If any answer is "no," stop and fix before shipping.
