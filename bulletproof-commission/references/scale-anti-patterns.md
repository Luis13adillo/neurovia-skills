# Commission Scale Anti-Patterns

Report-only. Run in `scale-check` mode.

---

## 1. Hardcoded rates in app code

```bash
grep -rEn "0\.30|0\.3|30\s*%|flat_rate[[:space:]]*=[[:space:]]*40|owner_percentage[[:space:]]*=[[:space:]]*30" src/
```

Expected: zero matches in fee calculation paths. All rates must come from `walkin_fee_config`.

Safe matches might include:
- Display strings like `"30%"` for UI (acceptable if read from config into a variable elsewhere)
- Test fixtures

Flag any arithmetic that uses a literal percentage or flat_rate in the fee calc.

---

## 2. Owner barber ID hardcoded

```bash
grep -rn "OWNER_BARBER_ID\|b0010000-0000-0000-0000-000000000001" src/
```

Current design hardcodes the owner barber ID in `src/lib/stripe/connect-helpers.ts` for exemption logic. This works for one owner.

If MT Barbershop ever adds a second owner or a franchise model, this becomes a bug. Flag as a future schema-change candidate:
- Move to `barbers.is_owner` column, OR
- Use `profiles.role = 'owner'` and JOIN.

Do NOT implement — suggest and wait.

---

## 3. Fee config is single-row (per-business)

```sql
SELECT COUNT(*) FROM walkin_fee_config;
-- Expected: 1 row
```

Current schema assumes one global config. Per-location fees (e.g., different percentages at different franchises) would require schema change. Flag if conversation turns that direction.

---

## 4. Grace period column exists

```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'grace_period_ends_at';
-- Expected: 1 row
```

If missing, new-barber grace logic fails silently.

---

## 5. Employment type column exists

```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'barbers' AND column_name = 'employment_type';
-- Expected: 1 row (valid values: 'contractor', 'employee')
```

---

## 6. Earnings alert threshold firing correctly

Per MEMORY.md and `walkin_fee_config.earnings_alert_threshold`, threshold is $200. Verify current "owed by shop" balance per non-Connect barber — formula must match `/api/commission/summary` (includes tip, filters `payment_status='paid'`, nets payouts, excludes owner barber):
```sql
WITH earned AS (
  SELECT st.barber_id,
         SUM(st.service_amount - st.owner_fee_amount + COALESCE(st.tip_amount, 0)) AS gross
  FROM service_transactions st
  WHERE st.payment_method IN ('card', 'link')
    AND st.fee_settlement_status IS DISTINCT FROM 'auto_split'
    AND st.payment_status = 'paid'
  GROUP BY st.barber_id
),
paid AS (
  SELECT barber_id, SUM(amount) AS total_paid
  FROM barber_payouts GROUP BY barber_id
)
SELECT b.id, b.slug,
       COALESCE(e.gross, 0) - COALESCE(p.total_paid, 0) AS owed_to_barber
FROM barbers b
LEFT JOIN earned e ON e.barber_id = b.id
LEFT JOIN paid p   ON p.barber_id = b.id
WHERE b.is_active = true
  AND COALESCE(b.stripe_charges_enabled, false) = false
  AND b.id <> 'b0010000-0000-0000-0000-000000000001'
  AND COALESCE(e.gross, 0) - COALESCE(p.total_paid, 0) >= 200
ORDER BY owed_to_barber DESC;
```

If any barber exceeds $200, owner should have a pending payout task and an `owner_alerts` row with `type='payout_due'`.

---

## 7. New-location fee handling

When a new location opens:
- Same fee config applies (1 row table, applies globally)
- New barbers at new location follow same grace period policy
- Stripe Connect onboarding status is per-barber, independent of location

Verify: no code branches `if (location === 'wilmington') applyFeeX else feeY`.

```bash
grep -rEn "location.*wilmington.*(fee|commission|percent)" src/ -i
```

Expected: zero matches.

---

## 8. Payouts with location_id

```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'barber_payouts' AND column_name = 'location_id';
-- Expected: 1 row (optional but useful for multi-location reporting)
```

`barber_payouts.location_id` exists and should be set at payout time for per-location reporting at scale.

---

## 9. cash_fee_ledger.location_id coverage

```sql
SELECT COUNT(*) FILTER (WHERE location_id IS NULL) AS missing_location,
       COUNT(*) AS total
FROM cash_fee_ledger
WHERE created_at > now() - interval '30 days';
```

At scale, per-location commission reporting requires this column to be populated. If many recent rows have NULL, location-based analytics will be off.

---

## 10. Trigger performance at scale

```sql
SELECT tgname, pg_get_triggerdef(oid)
FROM pg_trigger
WHERE tgrelid = 'service_transactions'::regclass
  AND NOT tgisinternal;
```

The trigger fires on every `service_transactions` insert. At N=1000 locations this is fine; at N=100,000 consider async queue. Not a current concern — flag if volume grows 100x.

---

## 11. Completion handlers hardcode `fee_settlement_status` without Connect routing [CRITICAL]

Each of these files hardcodes the fee status without checking `barber.stripe_charges_enabled`:

```bash
grep -nE "fee_settlement_status\s*=\s*(payment_method|'pending'|'cash_owed')" \
  src/app/api/queue/entry/\[id\]/route.ts \
  src/app/api/queue/complete/route.ts \
  src/app/api/bookings/\[id\]/route.ts \
  src/app/api/bookings/quick-complete/route.ts
```

Any match = this anti-pattern. Correct behavior: call `determinePaymentRouting()` to get the real status, then use its `feeSettlementStatus` return value. Without this, Connect barbers' transactions accrue to Ledger B even though they should auto-split via Stripe.

## 12. Tip field not wired end-to-end

The `PaymentCollectionModal` → API → Stripe metadata → webhook → `service_transactions.tip_amount` chain must be intact:

```bash
# All four files must reference tip_amount in both read/write positions:
grep -c "tip_amount" src/components/dashboard/PaymentCollectionModal.tsx \
                    src/app/api/queue/entry/\[id\]/route.ts \
                    src/app/api/bookings/\[id\]/route.ts \
                    src/app/api/payments/checkout/route.ts \
                    src/app/api/payments/send-link/route.ts \
                    src/app/api/webhooks/stripe/route.ts
```

If any file returns 0, the chain is broken there. Then run query #18 to confirm DB impact.

## 13. Cash backlog alert channel missing

`walkin_fee_config.earnings_alert_threshold` triggers alerts for Ledger B (shop owes barber). There is NO parallel alert for Ledger A (barber owes shop) when a barber's `cash_fee_ledger.status='owed'` total grows past the same threshold. At scale (more barbers, more locations), this means the owner has to manually scan for backlogs.

Grep for any owner-facing alert that reads `cash_fee_ledger`:
```bash
grep -rn "cash_fee_ledger" src/app/api/ | grep -i alert
```

If 0 hits, owners only see backlogs by actively opening the commission dashboard. Flag as scale risk.

---

## Output verdict template

```
## Commission Scale Readiness

### Ready
- [green items]

### Must fix / decide before scaling (new location, new owner, new franchise model)
1. [item + reason]

### Recommended (not blocking)
- [suggestions]

### Verdict
[READY / BLOCKED BY N ITEMS]
```

**Remember:** scale-check is report-only. Commission changes NEVER happen from a skill invocation.
