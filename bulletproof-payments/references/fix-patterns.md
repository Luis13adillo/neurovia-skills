# Payments — Fix Patterns

Paste-ready diffs for every payment gap category. When the audit flags a failure, point to the pattern number here and the user gets a concrete change to apply. These patterns are canonical — if you deviate, document why.

All patterns assume:
- `createAdminClient` imported from `@/lib/supabase/admin` (bypasses RLS — required in the Stripe webhook, which arrives with no Supabase session).
- `getStripe` / `isStripeConfigured` imported from `@/lib/stripe/server`.
- `STRIPE_WEBHOOK_SECRET` and `STRIPE_SECRET_KEY` are environment-separated (test vs. live) and NEVER swapped mid-request.
- Idempotency table is `stripe_webhook_events` with PRIMARY KEY `event_id` (see migration 036). **The column is `event_id`, NOT `stripe_event_id`** — the incidents.md narrative uses `stripe_event_id` loosely; the real column name is `event_id`.
- `service_transactions` is INSERT-only, populated by SECURITY DEFINER triggers on `queue_entries` / `bookings` status → `completed`.

---

## Fix-mode preflight checklist (universal — applies to every pattern)

Fix mode in `SKILL.md` runs this sequence for EVERY pattern before the Edit. Do all steps, in order. Skip none.

1. **Preflight** — Read the target file. Match the pattern's "before" block against current code exactly (imports, function names, variable names, surrounding context — NOT just line numbers, which drift). If ANY of these don't match → STOP. Report what differs. Do NOT apply a stale pattern.
2. **Classify** — Run the relevant invariant from `invariants.md`. Report whether the gap is live (drift detected in DB) or latent (code bug only). User decides urgency from this.
3. **Stripe-mode check** — Confirm the `STRIPE_SECRET_KEY` in the affected env is `sk_live_*` in prod, `sk_test_*` in dev. Mixed modes = incident waiting.
4. **Confirm diff** — Show exact `old_string` / `new_string`. Wait for explicit `yes`.
5. **Apply** — Single `Edit` call. One pattern per invocation.
6. **Verify** — Run the pattern's post-fix verification (grep + tsc, plus SQL if live). Every check must pass.
7. **NEVER test against production Stripe keys.** Webhook retries and real charges are both destructive. Use `sk_test_*` in a local env and Stripe CLI `stripe trigger` for events.
8. **Handoff** — Stop at `bulletproof-ship`. Do not commit.

If any step fails, stop and report. Do not proceed to the next step.

---

## Pattern 1 — Idempotent webhook via atomic insert-or-reject

**When:** `/src/app/api/webhooks/stripe/route.ts` processes the event BEFORE (or without) checking `stripe_webhook_events`. Symptom: duplicate `service_transactions` rows, double-charged customers, refund fired twice.

**Before (broken):**
```ts
event = stripe.webhooks.constructEvent(body, signature, webhookSecret)

// ... handle event immediately ...
switch (event.type) {
  case 'checkout.session.completed': { /* mutates DB */ }
}
```

**After (correct — atomic INSERT on UNIQUE PRIMARY KEY):**
```ts
event = stripe.webhooks.constructEvent(body, signature, webhookSecret)

const supabase = createAdminClient()

// Idempotency: atomic insert-or-reject. Duplicate event_id → 23505 → return 200.
const { error: idempotencyError } = await supabase
  .from('stripe_webhook_events')
  .insert({
    event_id: event.id,          // NOT `stripe_event_id` — migration 036 column is `event_id`
    event_type: event.type,
    status: 'processing',
  })

if (idempotencyError) {
  if (idempotencyError.code === '23505') {
    return NextResponse.json({ received: true, duplicate: true })
  }
  return NextResponse.json({ error: 'Database error' }, { status: 500 })
}

// Only NOW do we process the event
switch (event.type) { /* ... */ }
```

**Why atomic INSERT, not SELECT-then-INSERT:** Two concurrent webhook retries can both pass a SELECT (no row yet) and both INSERT → duplicate processing until the second INSERT fails. INSERT-first uses the UNIQUE constraint as the lock. See `incidents.md § Stripe Webhook Idempotency`.

**Post-fix verification:**
- `grep -n "stripe_webhook_events" src/app/api/webhooks/stripe/route.ts` → ≥1 match, ABOVE the `switch (event.type)` line.
- `grep -n "23505\|duplicate.*true" src/app/api/webhooks/stripe/route.ts` → ≥1 match.
- SQL (invariant #1 from `invariants.md`): `SELECT event_id, COUNT(*) FROM stripe_webhook_events GROUP BY event_id HAVING COUNT(*) > 1` → 0 rows (PK guarantees this, but re-run to confirm the table exists).
- `npx tsc --noEmit` → no new errors.

---

## Pattern 2 — Stripe signature verification with raw body

**When:** Webhook returns 400 "Invalid signature" for legitimate events, OR the route accepts ANY body (no signature check). Next.js App Router gotcha: `await request.json()` consumes the body and breaks `constructEvent`.

**Before (broken):**
```ts
const body = await request.json()                      // body is now an object, not raw bytes
const signature = request.headers.get('stripe-signature')
event = stripe.webhooks.constructEvent(JSON.stringify(body), signature, webhookSecret)
// ^ re-stringified body does NOT match what Stripe signed → always fails
```

**After (correct — raw text body + next/headers):**
```ts
import { headers } from 'next/headers'

export const runtime = 'nodejs'                        // required — Edge runtime lacks Buffer
export const dynamic = 'force-dynamic'

const body = await request.text()                      // RAW text, not parsed
const headersList = await headers()
const signature = headersList.get('stripe-signature')

if (!signature) {
  return NextResponse.json({ error: 'Missing signature' }, { status: 400 })
}

try {
  event = stripe.webhooks.constructEvent(body, signature, webhookSecret)
} catch (err) {
  console.error('Webhook signature verification failed:', err)
  return NextResponse.json({ error: 'Invalid signature' }, { status: 400 })
}
```

**Why `request.text()`, not `request.json()`:** Stripe signs the exact byte string. Parsing and re-serializing reorders keys, changes whitespace → signature mismatch. See `incidents.md § Webhook Signature Verification Failure`.

**Post-fix verification:**
- `grep -n "request.text()" src/app/api/webhooks/stripe/route.ts` → ≥1 match.
- `grep -n "request.json()\|await req.json" src/app/api/webhooks/stripe/route.ts` → 0 matches.
- `grep -n "runtime.*nodejs" src/app/api/webhooks/stripe/route.ts` → 1 match.
- Live probe (staging): `stripe listen --forward-to localhost:3010/api/webhooks/stripe` + `stripe trigger checkout.session.completed` → 200, no "Invalid signature" error.

---

## Pattern 3 — Checkout session metadata carries source IDs

**When:** Stripe dashboard shows a completed charge but DB has no matching `service_transactions` / `queue_entries.payment_status = 'paid'` update. The webhook handler can't trace the charge back to the source row because metadata is missing.

**Where:** `src/app/api/payments/checkout/route.ts` (in-person card payments) and `src/app/api/checkout/route.ts` (Academy). Also wherever `stripe.checkout.sessions.create(...)` or `stripe.paymentLinks.create(...)` is called.

**Before (broken):**
```ts
const session = await stripe.checkout.sessions.create({
  mode: 'payment',
  line_items: [...],
  success_url: `${origin}/queue/success`,
  // NO metadata → webhook has no way to know which queue_entry/booking this is
})
```

**After (correct):**
```ts
const session = await stripe.checkout.sessions.create({
  mode: 'payment',
  line_items: [...],
  success_url: `${origin}/queue/success`,
  metadata: {
    source_type: queue_entry_id ? 'queue_entry' : 'booking',
    queue_entry_id: queue_entry_id || '',
    booking_id: booking_id || '',
    barber_id: assigned_barber_id || '',
    location_id: location_id || '',
    service_amount: service_amount.toString(),
    tip_amount: tip_amount.toString(),
  },
  payment_intent_data: {
    // Forward metadata to the PaymentIntent too — charge.refunded fires on PI, not session
    metadata: {
      source_type: queue_entry_id ? 'queue_entry' : 'booking',
      queue_entry_id: queue_entry_id || '',
      booking_id: booking_id || '',
    },
  },
})
```

**Webhook reads it back:**
```ts
case 'checkout.session.completed': {
  const session = event.data.object as Stripe.Checkout.Session
  const queueEntryId = session.metadata?.queue_entry_id || null
  const bookingId    = session.metadata?.booking_id || null
  // Use these to UPDATE queue_entries / bookings payment_status
}
```

**Why forward to `payment_intent_data.metadata`:** `charge.refunded` webhook fires on the Charge → PaymentIntent, not on the Session. Without PI metadata, refund handler can't trace back. See `incidents.md § Refund Without Commission Reversal`.

**Post-fix verification:**
- `grep -n "metadata:" src/app/api/payments/checkout/route.ts` → ≥2 matches (session + payment_intent_data).
- `grep -n "queue_entry_id\|booking_id" src/app/api/payments/checkout/route.ts` → matches inside the metadata block.
- SQL (invariant #9): `SELECT COUNT(*) FROM service_transactions WHERE payment_method IN ('card','link') AND payment_status = 'paid' AND stripe_payment_id IS NULL AND service_completed_at > now() - interval '30 days'` → 0.

---

## Pattern 4 — Tip propagation from PaymentCollectionModal to service_transactions

**When:** Customer adds a tip on the modal, but `service_transactions.tip_amount = 0` after completion. Tip is getting lost in one of three places: (1) modal doesn't submit it, (2) API doesn't persist it on `queue_entries` / `bookings`, (3) the `service_transactions` trigger doesn't copy it.

**Where:** `src/components/dashboard/PaymentCollectionModal.tsx` → `/api/queue/entry/[id]/route.ts` PATCH (or `/api/bookings/[id]/route.ts`) → DB trigger on status='completed'.

**Diagnostic before writing code:**
```sql
-- Does queue_entries.tip_amount get set?
SELECT id, tip_amount, total_amount, status, payment_status
FROM queue_entries
WHERE id = '<suspect-entry-id>';

-- Does service_transactions.tip_amount match?
SELECT queue_entry_id, tip_amount, total_amount, service_amount
FROM service_transactions
WHERE queue_entry_id = '<suspect-entry-id>';
```

If `queue_entries.tip_amount > 0` but `service_transactions.tip_amount = 0` → trigger bug (rare; trigger is SECURITY DEFINER and in migration 024). If both are 0 → API or modal dropped it.

**Fix — modal side:** verify `PaymentData` payload includes `tip_amount` and is sent, NOT dropped:
```ts
// PaymentCollectionModal.tsx — inside handleConfirm
const data: PaymentData = {
  payment_method: selectedPaymentMethod,
  service_amount: servicePrice,
  tip_amount: tipAmount,                // must NOT be undefined
  total_amount: servicePrice + tipAmount,
  payment_status: selectedPaymentMethod === 'cash' ? 'paid' : 'pending',
}
onComplete(data)
```

**Fix — API side:** the PATCH that marks `status: 'completed'` must write tip_amount to the row. Never trust the trigger to compute tip — it only COPIES.

**Post-fix verification:**
- SQL invariant #7: `SELECT id FROM service_transactions WHERE ABS(total_amount - (service_amount + COALESCE(tip_amount, 0))) > 0.01` → 0 rows.
- SQL invariant #6: `SELECT id FROM service_transactions WHERE tip_amount < 0 OR tip_amount > (service_amount * 2)` → 0 rows (flag for manual review if nonzero).

---

## Pattern 5 — Refund fanout to source row + daily_summaries + cash_fee_ledger

**When:** Owner issues a refund via Stripe dashboard. `service_transactions.payment_status` stays `paid`. `daily_summaries.total_revenue` stays inflated. Commission ledger still shows `owed`. See `incidents.md § Refund Without Commission Reversal`.

**Where:** `src/app/api/webhooks/stripe/route.ts` — the `charge.refunded` case. Likely NOT fully implemented — flag to user if diagnose reveals a gap.

**Fix (full fanout):**
```ts
case 'charge.refunded': {
  const charge = event.data.object as Stripe.Charge
  const pi = charge.payment_intent as string

  // 1. Find the service_transaction
  const { data: tx } = await supabase
    .from('service_transactions')
    .select('id, queue_entry_id, booking_id, barber_id, location_id, service_completed_at, total_amount')
    .eq('stripe_payment_id', pi)
    .single()

  if (!tx) {
    console.error('Refund webhook: no matching service_transaction for PI', pi)
    break // idempotency row already inserted; DO NOT retry
  }

  // 2. Flip payment_status on service_transactions
  await supabase
    .from('service_transactions')
    .update({ payment_status: 'refunded' })
    .eq('id', tx.id)

  // 3. Flip payment_status on source row
  if (tx.queue_entry_id) {
    await supabase.from('queue_entries').update({ payment_status: 'refunded' }).eq('id', tx.queue_entry_id)
  } else if (tx.booking_id) {
    await supabase.from('bookings').update({ payment_status: 'refunded' }).eq('id', tx.booking_id)
  }

  // 4. Reverse commission via cash_fee_ledger (see bulletproof-commission Pattern X)
  //    Either delete or set status='waived' with note 'refund'.
  await supabase
    .from('cash_fee_ledger')
    .update({ status: 'waived', notes: `refund ${charge.id}` })
    .or(`queue_entry_id.eq.${tx.queue_entry_id || 'null'},booking_id.eq.${tx.booking_id || 'null'}`)
    .eq('status', 'owed')

  // 5. Recompute daily_summary for (date, barber, location)
  //    Call RPC update_daily_summary from migration 011
  const dateStr = new Date(tx.service_completed_at).toLocaleDateString('en-CA', { timeZone: 'America/New_York' })
  await supabase.rpc('update_daily_summary', {
    p_date: dateStr,
    p_barber_id: tx.barber_id,
    p_location_id: tx.location_id,
  })

  break
}
```

**Post-fix verification:**
- SQL invariant #8: `SELECT st.id FROM service_transactions st LEFT JOIN cash_fee_ledger cfl ON (cfl.queue_entry_id = st.queue_entry_id OR cfl.booking_id = st.booking_id) WHERE st.payment_status = 'refunded' AND cfl.status = 'owed'` → 0 rows.
- Date formatting uses `toLocaleDateString('en-CA', { timeZone: 'America/New_York' })` — enforces the Booksy Timezone HARD RULE (MEMORY.md). Never `toISOString().split('T')[0]`.

---

## Pattern 6 — Payment method enum enforcement (Cash / Card / Link)

**When:** Invariant #3 shows `payment_method` values outside `('cash', 'card', 'link')` on any of `queue_entries`, `bookings`, `service_transactions`. Usually comes from a typo or a new code path that bypasses the Zod schema.

**Fix (Zod at API boundary):**
```ts
// src/lib/validations/schemas.ts
export const paymentMethodSchema = z.enum(['cash', 'card', 'link'])

// Any API that accepts payment_method:
const bodySchema = z.object({
  payment_method: paymentMethodSchema,
  // ...
})
```

**Fix (DB CHECK constraint — permanent):** If invariant #3 ever fails, add a CHECK to prevent future drift. This is a schema change and requires explicit user approval before applying.

```sql
-- Apply only with user approval
ALTER TABLE queue_entries
  ADD CONSTRAINT queue_entries_payment_method_check
  CHECK (payment_method IS NULL OR payment_method IN ('cash', 'card', 'link'));
-- Repeat for bookings, service_transactions
```

**Post-fix verification:**
- Re-run invariant #3 on all three tables → 0 rows.
- Invariant #11: `SELECT id FROM service_transactions WHERE payment_method = 'cash' AND stripe_payment_id IS NOT NULL` → 0 rows (cash never has Stripe IDs).

---

## Pattern 7 — Payment link expiry + mode mismatch

**When:** Customer reports "This payment link has expired or is invalid" when clicking the SMS link. Root cause is almost always one of: (a) link was stored but never actually sent, (b) Stripe test/live mode mismatch, (c) link's `expires_at` elapsed. See `incidents.md § Send Link 404`.

**Fix (prevent mode mismatch):**
```ts
// src/app/api/payments/send-link/route.ts — near the top of POST handler
const stripe = getStripe()
if (!stripe) return NextResponse.json({ error: 'Stripe not configured' }, { status: 503 })

// Guard: key mode must match expected env
if (process.env.NODE_ENV === 'production' && !process.env.STRIPE_SECRET_KEY?.startsWith('sk_live_')) {
  console.error('Production environment with non-live Stripe key')
  return NextResponse.json({ error: 'Payment system misconfigured' }, { status: 500 })
}
```

**Fix (explicit expiry on Payment Link):**
```ts
const paymentLink = await stripe.paymentLinks.create({
  line_items: [...],
  metadata: { /* see Pattern 3 */ },
  after_completion: { type: 'hosted_confirmation' },
  // Note: Stripe Payment Links don't expose expires_at directly on the create API.
  // If you need a hard expiry, use checkout.sessions.create with expires_at instead.
})
```

**Diagnostic SQL:**
```sql
-- Invariant #10: link transactions must have stripe_payment_link
SELECT id, service_completed_at, payment_method, stripe_payment_link
FROM service_transactions
WHERE payment_method = 'link'
  AND stripe_payment_link IS NULL
  AND service_completed_at > now() - interval '30 days';
-- Expected: 0 rows
```

**Post-fix verification:**
- Invariant #10 → 0 rows.
- `grep -n "sk_live_\|NODE_ENV" src/app/api/payments/send-link/route.ts` → match on the guard.
- Copy a recent `stripe_payment_link` URL, paste into a browser → Stripe page loads, NOT a 404.

---

## Pattern 8 — PaymentCollectionModal polling fallback

**When:** Barber selects Card → Stripe redirect → customer pays → modal stuck on "Processing..." indefinitely. Either the webhook didn't fire or the polling logic is broken. See `incidents.md § PaymentCollectionModal Stuck State`.

**Fix (polling with timeout + manual-mark fallback):**
```tsx
// src/components/dashboard/PaymentCollectionModal.tsx
// After Stripe redirect returns (e.g., customer came back to /queue/success), poll:

useEffect(() => {
  if (!isProcessing || selectedPaymentMethod !== 'card') return

  let attempts = 0
  const maxAttempts = 20            // 60s at 3s interval
  const intervalId = setInterval(async () => {
    attempts++
    const res = await fetch(`/api/queue/entry/${entryId}`)
    const entry = await res.json()
    if (entry.payment_status === 'paid') {
      clearInterval(intervalId)
      onComplete({ /* ... paid data ... */ })
      return
    }
    if (attempts >= maxAttempts) {
      clearInterval(intervalId)
      setIsProcessing(false)
      setPaymentError('Payment confirmation is taking longer than expected. You can mark as paid manually, or retry.')
    }
  }, 3000)

  return () => clearInterval(intervalId)
}, [isProcessing, selectedPaymentMethod, entryId, onComplete])
```

**Always show a "Mark as Paid Manually" override** so a missed webhook doesn't block the barber from closing the service. The override still records `payment_status = 'paid'` on `queue_entries`; the Stripe reconciliation happens off-band.

**Post-fix verification:**
- Manual test: start card payment, kill Stripe webhook forwarder mid-flow → modal times out at ~60s and shows the manual fallback.
- `grep -n "Mark.*Paid\|mark_paid\|manual" src/components/dashboard/PaymentCollectionModal.tsx` → ≥1 match.

---

## Pattern 9 — Cron recomputes stuck pending transactions

**When:** Invariant #5 flags `service_transactions` rows where `payment_status = 'pending'` and `service_completed_at < now() - interval '24 hours'`. These are almost always missed webhooks or test/live mode mismatches.

**Fix — do NOT auto-resolve.** Instead, surface them on the owner alerts dashboard for manual reconciliation. Auto-flipping to `paid` without Stripe confirmation creates revenue fiction.

```ts
// New cron: src/app/api/cron/stripe-reconcile/route.ts (requires CRON_SECRET)
export async function GET(request: NextRequest) {
  const auth = request.headers.get('authorization')
  if (auth !== `Bearer ${process.env.CRON_SECRET}`) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }
  const supabase = createAdminClient()

  const { data: stuck } = await supabase
    .from('service_transactions')
    .select('id, stripe_payment_id, total_amount, service_completed_at')
    .eq('payment_status', 'pending')
    .lt('service_completed_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
    .limit(50)

  if (!stuck?.length) return NextResponse.json({ pending: 0 })

  // Insert an owner_alert — manual reconciliation required
  await supabase.from('owner_alerts').insert({
    type: 'payment_reconciliation',
    title: `${stuck.length} stuck pending transactions`,
    message: `Transactions over 24h old still pending — likely missed webhooks.`,
    is_read: false,
  })

  return NextResponse.json({ pending: stuck.length, alerted: true })
}
```

**Post-fix verification:**
- Invariant #5 count stabilizes or drops week-over-week.
- New rows appear in `owner_alerts` with `type = 'payment_reconciliation'` when drift exists.

---

## Cross-pattern rules

1. **ALWAYS use `createAdminClient` in the Stripe webhook.** Stripe arrives with no Supabase session. The user client = anon → RLS blocks everything silently. See bulletproof-push-notifications Pattern 1 for the same lesson in a different context.
2. **ALWAYS use raw `request.text()` for the webhook body.** `request.json()` invalidates the signature.
3. **ALWAYS forward metadata to `payment_intent_data.metadata`.** `charge.refunded` fires on the PI, not the Session.
4. **NEVER process events before the idempotency INSERT succeeds.** INSERT is the lock.
5. **NEVER assume the trigger copies tip_amount.** Write it explicitly on the source row before flipping status to `completed`.
6. **NEVER auto-resolve stuck pending payments.** Surface them for manual reconciliation.
7. **NEVER run test charges against production Stripe keys.** Use `stripe trigger` with test keys.
8. **NEVER modify `stripe_webhook_events` rows.** Corrupting idempotency state causes double-processing next time Stripe retries.

---

## When adding a NEW payment surface

Checklist:
1. Does it create a Stripe object? (Session / Payment Link / PaymentIntent) → attach metadata (Pattern 3).
2. Does it forward metadata to the PaymentIntent? (Pattern 3)
3. Is the webhook handler updated to handle the new event type?
4. Does it write to `queue_entries` or `bookings` before relying on `service_transactions`? (Pattern 4)
5. Does it handle the Cash / Card / Link enum correctly? (Pattern 6)
6. Does PaymentCollectionModal polling handle the new path? (Pattern 8)
7. Is there a reconciliation path if the webhook is missed? (Pattern 9)
8. Is mode separation (test vs. live) guarded? (Pattern 7)

If any of these is "no," stop and fix before shipping.
