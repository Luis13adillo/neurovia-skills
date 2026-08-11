---
name: elis-bulletproof-orders
description: Audit, diagnose, or scale-check the Eli's Dulce Tradicion custom cake order system (5-step Order wizard at src/pages/Order.tsx, order step components under src/components/order/steps/*, create_new_order RPC, transition_order_status RPC, pricing with useOptimizedPricing, sessionStorage persistence of pendingOrder, reference image upload, daily capacity enforcement via business_settings.max_daily_capacity, customer-facing OrderTracking.tsx with get_public_order RPC + order_lookup_rate_limits). Complement to elis-bulletproof-payments (payment capture) and elis-bulletproof-frontdesk (what happens after the order lands). Use when customers can't place orders, orders drop silently, daily capacity is exceeded, order numbers leak via tracking, reference images fail to upload, or before a holiday rush (Mother's Day, Quinceañera season, Valentine's). Read-only SQL via mcp__supabase__execute_sql (project rnszrscxwkdwvvlsihqc). Never writes to production DB — customer order data is revenue-critical.
---

# Eli's Bulletproof Orders

The 5-step custom cake order wizard is the front door to revenue. A crashed wizard = lost customer. A silent submission failure = confused phone call. An uncaptured allergy = potential hospital visit and legal exposure. Every check in this skill exists because of a specific failure mode seen in bakery e-commerce.

This skill covers:
- `src/pages/Order.tsx` — 5-step wizard shell + submit handler
- `src/components/order/steps/DateTimeStep.tsx` — delivery/pickup date + time window
- `src/components/order/steps/SizeStep.tsx` — cake size selection
- `src/components/order/steps/FlavorStep.tsx` — bread type + filling + premium upcharges
- `src/components/order/steps/DetailsStep.tsx` — reference image upload, customer notes
- `src/components/order/steps/ContactStep.tsx` — name, email, phone, address
- `src/components/order/steps/orderStepConstants.ts` — FALLBACK_* constants (hardcoded sizes/fillings/breads)
- `src/lib/api/modules/orders.ts` — `createOrder` (RPC `create_new_order`), `getPublicOrder` (RPC `get_public_order`), `verifyPayment` (RPC `verify_stripe_payment`)
- `src/lib/pricing.ts` + `useOptimizedPricing` hook — price calculation
- `src/pages/OrderTracking.tsx` — no-login customer status page
- `src/components/order/OrderStatusTracker.tsx` — visual status timeline
- `src/components/AddressVerification.tsx` — Google Maps autocomplete
- `src/components/legal/FoodSafetyDisclaimer.tsx` — allergy disclaimer component
- Tables: `orders`, `order_form_options`, `cake_sizes`, `bread_types`, `cake_fillings`, `premium_filling_upcharges`, `order_status_history`, `order_lookup_rate_limits`
- Migrations: `20260402_order_form_options.sql`, `20250206_secure_order_lookup.sql`, `20260206_order_status_transition_rpc.sql`, `20260206171327_add_idempotency_key.sql`

**Not covered here:**
- Stripe payment capture → `elis-bulletproof-payments`
- What happens after order lands in kitchen → `elis-bulletproof-frontdesk`
- Order confirmation email → `elis-bulletproof-emails`
- Customer auth / saved addresses → `elis-bulletproof-auth`
- Menu/product display on `/menu` → `elis-bulletproof-inventory`

---

## Schema Reality Check (verify before assuming)

Real `orders` columns seen in code: `id, order_number, customer_name, customer_email, customer_phone, customer_language, user_id, cake_size, bread_type, filling, premium_fillings (jsonb), custom_message, reference_image_url, pickup_date, pickup_time, delivery_option, delivery_address, delivery_apartment, delivery_zone, delivery_status, subtotal, delivery_fee, tax, total_amount, status, payment_status, stripe_payment_id, idempotency_key, estimated_ready_at, created_at, updated_at`.

Confirm with:
```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema='public' AND table_name='orders'
ORDER BY ordinal_position;
```

**There is NO structured `allergies` or `dietary_restrictions` column on `orders` as of this writing.** Allergy info (if captured) lives inside `custom_message` free-text. This is a real gap — see audit item #9.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — "What this project IS / IS NOT", Known Issues list.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-elis-dulce-tradicion/memory/MEMORY.md` — Auth lessons, Stripe live-mode note.
3. Confirm Supabase project id `rnszrscxwkdwvvlsihqc`. All SQL: `mcp__supabase__execute_sql` read-only.
4. State: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** — weekly + before any holiday (Mother's Day, Valentine's, Quinceañera season peak)
- **diagnose** — customer reported a specific order failure
- **scale-check** — ramping for a known surge (promotion, press, holiday week)

All modes are **read-only**. Never edit files or run DB writes without explicit user approval.

---

## Mode: audit

### Code-level invariants

1. **Wizard step guard keeps user from skipping ahead.**
   - `Order.tsx` should validate each step before advancing. Grep: `grep -n "canProceedFromStep\|nextStep\|validateStep" src/pages/Order.tsx src/components/order/steps/*.tsx`
   - A user who bypasses DateTimeStep by URL-manipulation should not hit the submit handler.

2. **Reference image upload validates size + type.**
   - `DetailsStep.tsx` should enforce max file size (watch for 5MB default), accepted MIME types (jpeg/png/webp).
   - Grep: `grep -n "file\.size\|MAX_FILE_SIZE\|accept=" src/components/order/steps/DetailsStep.tsx`
   - Oversize uploads crash the Supabase storage call; a crashed upload mid-wizard loses the entire `pendingOrder`.

3. **sessionStorage `pendingOrder` is re-hydrated on refresh.**
   - If a user refreshes mid-wizard, Order.tsx should load `pendingOrder` back from sessionStorage.
   - Grep: `grep -n "pendingOrder\|sessionStorage" src/pages/Order.tsx`
   - Broken re-hydrate = all wizard progress lost on accidental refresh.

4. **`create_new_order` RPC called with idempotency key.**
   - `src/lib/api/modules/orders.ts:67` calls `sb.rpc('create_new_order', { payload })`.
   - Payload should include a client-generated idempotency key (UUID) so a double-submit (user double-clicks Next, or payment retry) does not create two orders.
   - Grep: `grep -n "idempotency_key\|uuid\|crypto\.randomUUID" src/lib/api/modules/orders.ts src/pages/Order.tsx`
   - Migration `20260206171327_add_idempotency_key.sql` added the column — code must actually set it.

5. **Pricing is authoritative server-side.**
   - Any total shown to the customer before submit must be recomputed server-side inside `create_new_order` before charging. Client-side price tampering (DevTools) should not lower the charge.
   - Grep: `grep -n "total_amount\|calculateTotal\|pricing" src/lib/api/modules/orders.ts supabase/migrations/20260206_order_status_transition_rpc.sql supabase/migrations/20260402_order_form_options.sql`
   - **KNOWN GAP:** `orderStepConstants.ts` has FALLBACK_* hardcoded sizes/fillings/breads. If the DB `order_form_options` / `cake_sizes` / `bread_types` / `cake_fillings` tables are empty, customers order against stale prices.

6. **Daily capacity is enforced at submit, not just displayed.**
   - `business_settings.max_daily_capacity` should block new orders for a fully-booked date.
   - Grep: `grep -n "max_daily_capacity\|capacity" src/pages/Order.tsx src/components/order/steps/DateTimeStep.tsx src/lib/api/modules/*.ts`
   - FrontDesk.tsx has a fallback `|| 10` — if business_settings is empty, the limit silently becomes 10 per day.
   - Audit query #4 (below) catches over-capacity days.

7. **Business hours + holiday closures block unavailable dates.**
   - DateTimeStep should read `business_hours` and `holiday_closures`, prevent selecting a closed date.
   - Grep: `grep -n "business_hours\|holiday_closures\|is_open" src/components/order/steps/DateTimeStep.tsx`

8. **Minimum lead time + max advance window enforced.**
   - `business_settings.minimum_lead_time_hours` (no same-day rush orders) and `.maximum_advance_days`.
   - Grep: `grep -n "minimum_lead_time\|maximum_advance" src/components/order/steps/DateTimeStep.tsx`

9. **[KNOWN GAP] Allergy/dietary capture is free-text only.**
   - There is no structured `allergies` field on `orders`. Allergy disclosures (if made) live inside `custom_message`.
   - `src/components/legal/FoodSafetyDisclaimer.tsx` exists but is not wired as a blocking step.
   - **Industry best practice** (per FDA Food Code + bakery liability case law): structured allergy field + customer-acknowledged disclaimer before submit.
   - Flag in every audit report until fixed. Do NOT auto-fix — this is a product + legal decision.

10. **OrderTracking.tsx rate limiting is real.**
    - `get_public_order` RPC should check `order_lookup_rate_limits` by IP to prevent order-number enumeration.
    - Migration `20250206_secure_order_lookup.sql` added this — verify the RPC body enforces it, not just the table existing.
    - Grep: `grep -n "order_lookup_rate_limits\|rate_limit" supabase/migrations/20250206_secure_order_lookup.sql src/pages/OrderTracking.tsx`

11. **Order numbers are not sequential/guessable.**
    - `order_number` should be a random-ish token (e.g., ORD-XXXXXX with random chars), not monotonic. Sequential numbers + weak rate limiting = total order database enumeration.
    - Query: `SELECT order_number FROM orders ORDER BY created_at DESC LIMIT 10;` — spot the pattern.

12. **`transition_order_status` RPC prevents illegal transitions.**
    - Migration `20260206_order_status_transition_rpc.sql` should enforce the state machine (e.g., can't go from `cancelled` back to `in_progress`).
    - This matters because the kitchen UI and admin dashboard both call it. A bug here lets a cancelled order re-enter the queue.

### Data-level invariants

Run these as read-only queries (`mcp__supabase__execute_sql`, project `rnszrscxwkdwvvlsihqc`):

```sql
-- Q1. Orders submitted in the last 7 days with NULL critical fields
SELECT id, order_number, created_at, status, payment_status,
       cake_size IS NULL AS missing_size,
       bread_type IS NULL AS missing_bread,
       filling IS NULL AS missing_filling,
       total_amount IS NULL AS missing_total,
       customer_email IS NULL AS missing_email
FROM orders
WHERE created_at > now() - interval '7 days'
  AND (cake_size IS NULL OR bread_type IS NULL OR filling IS NULL
       OR total_amount IS NULL OR customer_email IS NULL);

-- Q2. Paid but still pending (Stripe webhook didn't flip status)
SELECT id, order_number, created_at, status, payment_status, stripe_payment_id
FROM orders
WHERE payment_status = 'paid'
  AND status = 'pending'
  AND created_at < now() - interval '15 minutes';

-- Q3. Duplicate idempotency keys (would indicate a constraint gap)
SELECT idempotency_key, COUNT(*) n
FROM orders
WHERE idempotency_key IS NOT NULL
GROUP BY idempotency_key
HAVING COUNT(*) > 1;

-- Q4. Days over max_daily_capacity (capacity breach)
WITH cap AS (SELECT max_daily_capacity FROM business_settings LIMIT 1)
SELECT pickup_date, COUNT(*) AS booked, (SELECT max_daily_capacity FROM cap) AS cap
FROM orders
WHERE pickup_date >= CURRENT_DATE
  AND status NOT IN ('cancelled')
GROUP BY pickup_date
HAVING COUNT(*) > (SELECT max_daily_capacity FROM cap);

-- Q5. Orders with a pickup_date in the past but status != delivered/completed/cancelled
SELECT id, order_number, pickup_date, pickup_time, status
FROM orders
WHERE pickup_date < CURRENT_DATE - interval '1 day'
  AND status NOT IN ('delivered', 'completed', 'cancelled');

-- Q6. Reference image URLs that 404 (sample check — pick 10, try them)
SELECT id, order_number, reference_image_url
FROM orders
WHERE reference_image_url IS NOT NULL
ORDER BY created_at DESC
LIMIT 10;

-- Q7. Order number format consistency (pattern check)
SELECT order_number
FROM orders
ORDER BY created_at DESC
LIMIT 20;

-- Q8. Rate-limit hits in last 24h (signals enumeration attempts if >100/IP)
SELECT ip_address, COUNT(*) n
FROM order_lookup_rate_limits
WHERE created_at > now() - interval '24 hours'
GROUP BY ip_address
HAVING COUNT(*) > 20
ORDER BY n DESC
LIMIT 10;

-- Q9. Delivery fee distribution (catches $15 hardcode drift)
SELECT delivery_fee, COUNT(*) n
FROM orders
WHERE delivery_option = 'delivery' AND created_at > now() - interval '30 days'
GROUP BY delivery_fee
ORDER BY n DESC;
```

### Audit output template

```
## Orders Audit — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Step guard prevents skipping
- [PASS/FAIL] Image upload validates size + type
- [PASS/FAIL] sessionStorage re-hydrate on refresh
- [PASS/FAIL] create_new_order called with idempotency key
- [PASS/FAIL] Pricing re-computed server-side
- [PASS/FAIL] Daily capacity enforced at submit
- [PASS/FAIL] Business hours + closures block dates
- [PASS/FAIL] Lead time + advance window enforced
- [FAIL — KNOWN GAP] Structured allergy field missing
- [PASS/FAIL] Rate limiting real in get_public_order
- [PASS/FAIL] Order numbers non-sequential
- [PASS/FAIL] transition_order_status guards state machine

### Data-level (last 7d unless noted)
- Q1 orders with NULL critical fields: X
- Q2 paid-but-pending gap: X (target: 0)
- Q3 duplicate idempotency keys: X (target: 0)
- Q4 capacity-breach days: X (target: 0)
- Q5 stale-past-pickup orders: X
- Q6 image sample: X/10 reachable
- Q7 order number pattern: [describe]
- Q8 enumeration signals: X IPs >20 lookups/24h
- Q9 delivery fee drift: [list distinct values]

### Red flags
[Anything above zero on Q2/Q3/Q4]

### Known gaps (report but do not auto-fix)
- Allergy field missing (see item #9)
- Delivery fee hardcoded $15 in PaymentCheckout.tsx (see elis-bulletproof-payments)
- Pricing hardcoded fallbacks in orderStepConstants.ts
```

---

## Mode: diagnose

### Step 1 — Ask
- Which order (number OR customer email + pickup_date)?
- What did the customer report? (can't submit / card declined / no confirmation / wrong total / etc.)
- When — exact timestamp if possible.
- Which device / browser / language?

### Step 2 — First queries
```sql
SELECT id, order_number, status, payment_status, stripe_payment_id,
       idempotency_key, total_amount, delivery_fee,
       cake_size, bread_type, filling, pickup_date, pickup_time,
       created_at, updated_at
FROM orders WHERE order_number = '<order>' OR customer_email = '<email>';

SELECT * FROM order_status_history
WHERE order_id = '<id>' ORDER BY created_at ASC;
```

### Step 3 — Match the symptom

| Symptom | Likely cause | Next step |
|---|---|---|
| "I submitted but got no confirmation" | payment_status != 'paid' OR email never fired | Check Q2 above; also `elis-bulletproof-payments` + `elis-bulletproof-emails` |
| "Two charges for one order" | Idempotency key missing on client → Stripe retry created second PaymentIntent | Grep idempotency in orders.ts, Order.tsx submit |
| "Total on receipt doesn't match what I saw" | Server-side recompute off OR delivery fee drifted | Compare subtotal/delivery_fee/tax on row vs. `useOptimizedPricing` logic |
| "Can't select my date" | business_hours closed for that day OR holiday_closures hit OR capacity full | Read business_hours / holiday_closures / Q4 |
| "Image upload failed" | File too big OR storage bucket misconfigured OR offline | Check bucket policies, file.size validation in DetailsStep |
| "Can't find my order on tracking page" | Rate limit tripped OR order number guessed wrong OR RLS blocks RPC | Q8; confirm get_public_order returns for known order_number |
| "Wizard lost my data on refresh" | sessionStorage key mismatch OR SSR hydration clobbers it | Grep `pendingOrder` read vs. write key |

### Step 4 — Three-file rule
Read the three files most likely to hold the bug. Do NOT open more unless the first three are clean. Stay in scope.

### Step 5 — Report, do not fix
This skill is read-only by default. Produce a root-cause report. User explicitly approves before code change.

---

## Mode: scale-check

Before a holiday week (Mother's Day, Valentine's, Quinceañera-heavy weekend), verify:

1. **Capacity headroom** — Q4 projected: count pre-orders already booked on peak day. If booked ≥ 70% of `max_daily_capacity`, either raise capacity or close the date proactively.
2. **Supabase Realtime budget** — the wizard itself doesn't subscribe to realtime, but every logged-in customer session on the site counts. Check elis-bulletproof-frontdesk for the kitchen side.
3. **Storage quota** — reference_image_url uploads to Supabase storage. Each ~2-5MB. For a 200-order week: ~1GB. Confirm bucket quota.
4. **Edge Function cold starts** — `create-payment-intent` is on the critical path. First call after an idle period is slow; surge hour exposes it.
5. **RPC concurrency** — `create_new_order` likely uses a SELECT FOR UPDATE pattern on capacity. Under concurrent submits, make sure the RPC actually serializes — not just the client.
6. **Order number collisions** — If the generation scheme is random 6-char, birthday paradox hits around ~1000 orders. If total orders > 10k, check for collisions: `SELECT order_number, COUNT(*) FROM orders GROUP BY order_number HAVING COUNT(*)>1;`
7. **Email queue backlog** — see `elis-bulletproof-emails`.
8. **Rate-limit table bloat** — `order_lookup_rate_limits` should have a TTL / cleanup job. Otherwise it grows forever.

### Output
```
## Orders Scale Readiness — Event: [name], Window: [dates]

- Booked vs capacity: X / Y per day
- Storage projection: X GB / Y GB quota
- Order number collisions: [none / N found]
- Rate-limit table rows: N (cleanup: [exists / missing])
- Idempotency coverage verified: Y/N
- Stripe keys confirmed LIVE (pk_live_*, sk_live_*): Y/N

Verdict: [READY / NOT READY — blocker list]
```

---

## Critical Flow: customer places an order

1. Landing → `/order`
2. Step 1 DateTime → read business_hours + holiday_closures + capacity → validate → store to wizard state
3. Step 2 Size → pulled from `cake_sizes` (or FALLBACK_SIZES if empty)
4. Step 3 Flavor → `bread_types` + `cake_fillings` + `premium_filling_upcharges`
5. Step 4 Details → reference image upload to Supabase storage → sessionStorage checkpoint
6. Step 5 Contact → name / email / phone / address (Google Maps) → FoodSafetyDisclaimer shown
7. Client calls `api.createOrder({...payload, idempotency_key})` → RPC `create_new_order` → returns order id + order_number
8. Redirect to `/checkout?orderId=...` → Stripe PaymentIntent → `elis-bulletproof-payments`
9. Webhook flips payment_status to 'paid' → order becomes visible in FrontDesk
10. Customer redirected to `/order-confirmation?orderId=...` → shows order number → `elis-bulletproof-emails` sends receipt

---

## HARD RULES

- **NEVER write to the production DB.** Read-only is the default. Any write requires explicit user approval AND is handled through a separate commit, not this skill.
- **NEVER auto-fix the allergy gap.** It's a product + legal decision — flag it and stop.
- **NEVER test `create_new_order` against production** by submitting a real order. Use local dev with `pk_test_*`.
- **NEVER disable `order_lookup_rate_limits`** — it's the only thing standing between us and order-number enumeration attacks.
- **NEVER loosen RLS on `orders`** to make a query "work" — if a query fails, it's probably correct.
- **Assume pricing can be tampered with client-side.** Server authoritative, always.
- **Scope:** if a fix would touch payments, emails, or frontdesk, hand off to the matching skill instead of widening this one.
