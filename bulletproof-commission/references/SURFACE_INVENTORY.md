# Commission Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the commission/fee system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — commission-owning (5 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/commission/summary/route.ts` | GET | Owner: per-barber owed/paid/waived aggregates |
| 2 | `src/app/api/commission/barber-summary/route.ts` | GET | Barber: own fees, card earnings, payouts |
| 3 | `src/app/api/commission/payout/route.ts` | POST | Owner: record payout to barber |
| 4 | `src/app/api/commission/waive/route.ts` | POST | Owner: waive a single transaction |
| 5 | `src/app/api/barber/cash-fees/route.ts` | GET/POST | GET outstanding fees / POST settle |

## 2. API Routes — commission-writing (9 routes)

Every route here WRITES to `service_transactions`, `cash_fee_ledger`, or the fee columns. All nine MUST pass the invariants.

| # | Route | Commission write |
|---|---|---|
| 6 | `src/app/api/queue/entry/[id]/route.ts` | PATCH completion → fee columns + ledger insert |
| 7 | `src/app/api/queue/complete/route.ts` | Alt queue completion path |
| 8 | `src/app/api/queue/entry/[id]/void/route.ts` | Void → waives fee, reverses ledger |
| 9 | `src/app/api/queue/entry/[id]/reassign-completed/route.ts` | Barber reassign → recomputes fee |
| 10 | `src/app/api/bookings/[id]/route.ts` | PATCH completion → fee columns + ledger insert |
| 11 | `src/app/api/bookings/quick-complete/route.ts` | Quick complete → fee columns + ledger insert |
| 12 | `src/app/api/payments/checkout/route.ts` | Stripe checkout creation → `determinePaymentRouting()` |
| 13 | `src/app/api/payments/send-link/route.ts` | Payment link creation → `determinePaymentRouting()` |
| 14 | `src/app/api/webhooks/stripe/route.ts` | Payment completion → syncs status to service_transactions |

## 3. API Routes — commission-config (3 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 15 | `src/app/api/settings/walkin-fee/route.ts` | GET/POST | Owner: adjust fee config |
| 16 | `src/app/api/barber/stripe/status/route.ts` | GET | Read Connect status |
| 17 | `src/app/api/barber/stripe/callback/route.ts` | GET | Connect OAuth callback |

## 4. Library / helpers (3 files)

| # | File | Role |
|---|---|---|
| 18 | `src/lib/stripe/connect-helpers.ts` | `determinePaymentRouting()` — SINGLE source of truth |
| 19 | `src/lib/commission/audit-logger.ts` | Writes `commission_waiver_audit` rows |
| 20 | `src/lib/types/database.ts` | Generated types — fee columns schema |

## 5. UI surfaces (8 pages)

| # | Page | Displays |
|---|---|---|
| 21 | `src/app/(dashboard)/dashboard/analytics/commissions/page.tsx` | Owner commission dashboard |
| 22 | `src/app/(dashboard)/dashboard/page.tsx` | Owner home — revenue tiles |
| 23 | `src/app/(dashboard)/dashboard/barbers/page.tsx` | Per-barber Connect status + totals |
| 24 | `src/app/(dashboard)/dashboard/my-chair/page.tsx` | Owner as barber — balance card |
| 25 | `src/app/(dashboard)/dashboard/my-chair/reports/page.tsx` | Owner's own earnings |
| 26 | `src/app/(dashboard)/barber/page.tsx` | Barber home — "owed / earned" cards |
| 27 | `src/app/(dashboard)/barber/reports/page.tsx` | Barber earnings history |
| 28 | `src/app/(dashboard)/barber/setup/page.tsx` | Onboarding — commission acknowledgement |

## 6. Database tables (6 tables)

| # | Table | Role |
|---|---|---|
| 29 | `walkin_fee_config` | Single-row config (owner_percentage, flat_rate, threshold) |
| 30 | `cash_fee_ledger` | Ledger A — cash fees barber owes shop |
| 31 | `service_transactions` | Every completed transaction (fee columns) |
| 32 | `barber_payouts` | Ledger B — payouts recorded to barbers |
| 33 | `commission_waiver_audit` | Audit trail of every waive action |
| 34 | `daily_summaries` | Aggregated daily totals (owner_fees, barber_net) |

Parent tables that carry fee columns (NOT commission-owned but MUST be audited):
| 35 | `queue_entries` | `owner_fee_amount`, `barber_net_amount`, `fee_settlement_status`, `waived_by`, `waived_at` |
| 36 | `bookings` | Same 5 columns |
| 37 | `barbers` | `stripe_charges_enabled`, `grace_period_ends_at`, `commission_acknowledged_at`, `employment_type` |

## 7. RPC functions (2 functions)

| # | Function | Trigger? | Purpose |
|---|---|---|---|
| 38 | `update_daily_summary(date, barber_id, location_id)` | Called by triggers + routes | Upsert daily totals |
| 39 | `create_service_transaction_from_queue()` | AFTER UPDATE on queue_entries | Insert service_transactions row + propagate waived_by/waived_at |
| 40 | `create_service_transaction_from_booking()` | AFTER UPDATE on bookings | Same for bookings |

## 8. DB triggers (3 triggers)

| # | Trigger | Table | Timing |
|---|---|---|---|
| 41 | `create_service_transaction_from_queue` | `queue_entries` | AFTER UPDATE |
| 42 | `create_service_transaction_from_booking` | `bookings` | AFTER UPDATE |
| 43 | `tr_referral_conversion` (handle_referral_conversion) | `service_transactions` | AFTER INSERT/UPDATE of payment_status |

## 9. RLS policies (8 policies)

Expected policies per table. An audit MUST enumerate actual vs expected.

| # | Table | Expected policies |
|---|---|---|
| 44 | `walkin_fee_config` | "Owner can manage walkin fee config" (all), "Barbers can read walkin fee config" (select) |
| 45 | `cash_fee_ledger` | "Owner can manage cash fee ledger" (all), "Barbers can read own cash fee ledger" (select where barber_id = auth.uid barber record) |
| 46 | `service_transactions` | Owner-all, barber-select-own (via barber_id) |
| 47 | `barber_payouts` | Owner-all, barber-select-own |
| 48 | `commission_waiver_audit` | `waiver_audit_owner_select` — owner select only |
| 49 | `daily_summaries` | Owner-all, barber-select-own |

## 10. Migrations (8 migrations)

| # | Migration | What it did |
|---|---|---|
| 50 | `041_walkin_fee_system.sql` | Core schema: walkin_fee_config + cash_fee_ledger + fee columns on 3 tables + update_daily_summary + create_service_transaction_from_queue trigger |
| 51 | `20260320*_commission_acknowledgement.sql` (if exists) | `commission_acknowledged_at`, `employment_type`, `waived_by`, `waived_at` on service_transactions |
| 52 | `20260320*_barber_payouts.sql` (if exists) | `barber_payouts` table |
| 53 | `20260323*_earnings_alert_threshold.sql` (if exists) | `walkin_fee_config.earnings_alert_threshold` |
| 54 | `20260416000000_owner_alerts_add_payment_skipped.sql` | owner_alerts: `payment_skipped` type |
| 55 | `20260424000000_commission_waiver_audit.sql` | `commission_waiver_audit` table + RLS |
| 56 | `20260424010000_lock_silent_waivers.sql` | `waived_requires_waiver` CHECK constraint on service_transactions |
| 57 | `20260424020000_validate_waiver_constraint_and_queue_index.sql` | Unique partial indexes on cash_fee_ledger (uniq_cash_fee_ledger_owed_booking + uniq_cash_fee_ledger_owed_entry) |
| 58 | `20260424030000_add_waiver_columns_to_parents.sql` | `waived_by` + `waived_at` columns on queue_entries + bookings + updated 2 trigger functions to propagate |

## 11. External integrations (3 integrations)

| # | System | Touch points |
|---|---|---|
| 59 | Stripe (platform) | Checkout sessions, payment intents, payment links, webhooks (`checkout.session.completed`, `payment_intent.succeeded`, `charge.refunded`, `charge.dispute.*`, `transfer.*`) |
| 60 | Stripe Connect (barber accounts) | OAuth callback, `stripe_charges_enabled` sync, auto-split via `application_fee_amount` |
| 61 | `owner_alerts` | Failure notifications for ledger insert errors and earnings threshold |

## 12. Cron / background jobs (1 job)

| # | Route | Schedule | Purpose |
|---|---|---|---|
| 62 | `src/app/api/cron/grace-period-notifications/route.ts` | Daily | Flags barbers approaching grace period end |

## 13. Environment variables

| # | Var | Purpose |
|---|---|---|
| 63 | `STRIPE_SECRET_KEY` | All Stripe API calls |
| 64 | `STRIPE_WEBHOOK_SECRET` | Webhook signature verification |
| 65 | `OWNER_BARBER_ID` (hardcoded `b0010000-…`) | Owner exemption in connect-helpers.ts |
| 66 | `CRON_SECRET` | Grace period cron auth |

---

## Surface Totals

- **API routes:** 17 (5 commission-owning + 9 commission-writing + 3 config)
- **Library files:** 3
- **UI pages:** 8
- **Database tables:** 6 commission-owned + 3 commission-touched = 9 total
- **RPC functions:** 3
- **DB triggers:** 3
- **RLS policies:** 8+ (across 6 tables)
- **Migrations:** 8
- **External integrations:** 3
- **Cron jobs:** 1
- **Environment variables:** 4

**Grand total surfaces to audit:** 63+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
