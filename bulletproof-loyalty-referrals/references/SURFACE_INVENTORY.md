# Loyalty & Referrals Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the loyalty / gift-card / referral / upsell pipeline touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — domain-owning (2 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/loyalty/route.ts` | GET/POST | GET returns loyalty_config row; POST with `action=add_punch` or `action=redeem_reward` calls matching RPC. Authenticated owner/barber only. |
| 2 | `src/app/api/referrals/track/route.ts` | POST | Public — records `click` events ONLY (visits/conversions come from queue+booking code paths). Calls `record_referral_event` RPC. |

## 2. API Routes — analytics readers (2 routes)

| # | Route | Purpose |
|---|---|---|
| 3 | `src/app/api/analytics/referrals/route.ts` | Owner-facing referral funnel analytics; reads `referral_funnel_summary` view or `barber_referrals` aggregate columns |
| 4 | `src/app/api/analytics/retention/route.ts` | Customer retention analytics, reads `customer_loyalty`, `gift_cards` |

## 3. API Routes — loyalty/referral-writing completion paths (4 routes)

These routes WRITE loyalty punches or referral_event rows as part of their normal work. Loyalty + referral integrity depends on these firing reliably.

| # | Route | Write |
|---|---|---|
| 5 | `src/app/api/queue/route.ts` | POST check-in — inserts `referral_events` with event_type=`visit` when `referral_code` is present |
| 6 | `src/app/api/bookings/route.ts` | POST booking create — same `visit` insert pattern |
| 7 | `src/app/api/queue/complete/route.ts` | Alt queue completion — writes `customer_loyalty` punch via direct update or RPC |
| 8 | `src/app/api/bookings/[id]/route.ts` | Booking PATCH complete — writes loyalty punch; also `loyalty_reward_applied` column on `bookings` |

## 4. API Routes — client-facing (2 routes)

| # | Route | Purpose |
|---|---|---|
| 9 | `src/app/api/client/profile/route.ts` | Reads `customer_loyalty` for logged-in client; surfaces punch count + reward availability |
| 10 | `src/app/api/clients/[id]/route.ts` | Client CRM — includes loyalty + referral attribution |

## 5. Library / helpers (3 files)

| # | File | Role |
|---|---|---|
| 11 | `src/lib/hooks/useLoyaltyAnalytics.ts` | Client-side hook for owner analytics dashboard |
| 12 | `src/lib/hooks/useReferralAnalytics.ts` | Same for referrals |
| 13 | `src/lib/hooks/useCustomerRetention.ts` | Ties loyalty + gift card + repeat visits |

## 6. UI components (6 files)

| # | File | Role |
|---|---|---|
| 14 | `src/components/dashboard/LoyaltyPunchCard.tsx` | Rendered inside PaymentCollectionModal — shows current punches / reward availability |
| 15 | `src/components/dashboard/GiftCardBalance.tsx` | Rendered inside PaymentCollectionModal — lookup + apply gift card balance |
| 16 | `src/components/dashboard/UpsellSuggestionCard.tsx` | Rendered inside PaymentCollectionModal — suggests add-ons via `upsell_rules` |
| 17 | `src/components/referrals/ReferralTracker.tsx` | Public-side tracker — fires `click` on referral-code landing |
| 18 | `src/components/dashboard/barber/ReferralCard.tsx` | Barber dashboard widget — shows own code, clicks, conversions, earnings |
| 19 | `src/components/analytics/ReferralAnalytics.tsx`, `ReferralFunnelChart.tsx`, `LoyaltyAnalytics.tsx`, `GiftCardAnalytics.tsx` | Owner analytics dashboards |

## 7. UI pages / entry points (5 files)

| # | File | Role |
|---|---|---|
| 20 | `src/app/(public)/book/page.tsx` | Booking wizard — consumes `?ref=CODE` → fires ReferralTracker |
| 21 | `src/app/(public)/queue/page.tsx` | Walk-in check-in — same ref-code ingestion on queue entry create |
| 22 | `src/app/(public)/profile/page.tsx` | Client-facing profile — shows loyalty status + punches_required from config |
| 23 | `src/app/(dashboard)/dashboard/analytics/retention/page.tsx` | Owner retention dashboard — reads customer_loyalty + gift_cards |
| 24 | `src/app/layout.tsx` | Root layout — ReferralTracker mount point (?ref= URL param handling) |

## 8. Database tables (7 tables)

| # | Table | Role |
|---|---|---|
| 25 | `customer_loyalty` | Per-phone punch card. Columns: `client_phone` UNIQUE, `current_punches`, `total_punches_earned`, `rewards_redeemed`, `last_punch_at`, `client_id` FK (nullable). NOTE: uses `current_punches` + `total_punches_earned` + `rewards_redeemed` — NOT `punches_count` + `rewards_earned` (CLAUDE.md is stale). |
| 26 | `loyalty_config` | Single-row config. Columns: `punches_required`, `reward_type` (`free_service`/`discount_percent`/`discount_fixed`), `reward_value`, `eligible_services` (UUID[]), `is_active`, PLUS `walkin_discount_percent`, `booking_discount_percent`, `waive_fee_on_redemption` (added later — verified in prod 2026-04-24) |
| 27 | `gift_cards` | Gift card inventory. Columns: `code` UNIQUE, `original_amount`, `current_balance`, purchaser_*, recipient_*, `status` (`active`/`depleted`/`expired`/`cancelled`), `expires_at` |
| 28 | `gift_card_transactions` | History of purchase/redemption/refund. Columns: `gift_card_id` FK, `queue_entry_id` FK, `booking_id` FK, `transaction_type` (`purchase`/`redemption`/`refund`), `amount`, `balance_after`, `notes` |
| 29 | `barber_referrals` | Per-barber referral aggregate. Columns: `barber_id` UNIQUE FK, `referral_code` UNIQUE, `total_referrals`, `successful_conversions`, `total_earnings`, `commission_rate` (default $5.00), `is_active` |
| 30 | `referral_events` | Per-event log: `click`/`visit`/`conversion`. Columns: `barber_referral_id` FK, `referral_code` (denormalized), `event_type`, `client_phone`, `client_name`, `queue_entry_id` FK, `booking_id` FK, `earnings` |
| 31 | `upsell_rules` | Service add-on suggestions. Columns: `base_service_id` FK, `suggested_addon_id` FK, `display_order`, `suggestion_text`, `is_active`, UNIQUE(base_service_id, suggested_addon_id) |

Parent tables that carry loyalty-touched columns (audit both):
| 32 | `queue_entries` | `loyalty_reward_applied` (boolean flag surfaced via PostServiceFlow) |
| 33 | `bookings` | `loyalty_reward_applied` |

## 9. Database views (1 view)

| # | View | Role |
|---|---|---|
| 34 | `referral_funnel_summary` | Pre-aggregated clicks/visits/conversions per barber, with click→visit and visit→conversion rates |

## 10. RPC functions (4 functions)

| # | Function | Called by | Purpose |
|---|---|---|---|
| 35 | `add_loyalty_punch(p_phone TEXT)` | `/api/loyalty` POST action=add_punch | Atomic insert-or-increment on customer_loyalty by phone. SECURITY DEFINER. |
| 36 | `redeem_loyalty_reward(p_phone TEXT)` | `/api/loyalty` POST action=redeem_reward | Decrements punches by `punches_required`, increments rewards_redeemed. Returns NULL if insufficient. SECURITY DEFINER. |
| 37 | `record_referral_event(p_referral_code, p_event_type, p_client_phone?, p_client_name?, p_queue_entry_id?, p_booking_id?)` | `/api/referrals/track`, `handle_referral_conversion` trigger | Validates referral_code, validates event_type, auto-calculates earnings (commission_rate on conversion), inserts row. SECURITY DEFINER. |
| 38 | `handle_referral_conversion()` | tr_referral_conversion trigger | On `service_transactions` INSERT or UPDATE of `payment_status` to 'paid', matches back to the prior `visit` event and calls `record_referral_event` with `conversion`. |

## 11. Trigger functions (2 maintenance helpers)

| # | Function | Trigger | Purpose |
|---|---|---|---|
| 39 | `update_barber_referrals_updated_at()` | `trigger_update_barber_referrals_updated_at` BEFORE UPDATE on `barber_referrals` | Keep updated_at fresh |
| 40 | `update_referral_metrics()` | `trigger_update_referral_metrics` AFTER INSERT on `referral_events` | Increments barber_referrals.total_referrals/successful_conversions/total_earnings based on event_type |

## 12. DB triggers (3 triggers)

| # | Trigger | Table | Timing |
|---|---|---|---|
| 41 | `trigger_update_barber_referrals_updated_at` | `barber_referrals` | BEFORE UPDATE |
| 42 | `trigger_update_referral_metrics` | `referral_events` | AFTER INSERT |
| 43 | `tr_referral_conversion` | `service_transactions` | AFTER INSERT OR UPDATE OF payment_status |

## 13. RLS policies (expected per table)

| # | Table | Expected policies |
|---|---|---|
| 44 | `customer_loyalty` | "Barbers can view customer loyalty" (SELECT, owner+barber), "Owner has full access to customer loyalty" (ALL) |
| 45 | `loyalty_config` | "Barbers can view loyalty config" (SELECT), "Owner has full access to loyalty config" (ALL) |
| 46 | `gift_cards` | "Barbers can view gift cards" (SELECT), "Owner has full access to gift cards" (ALL) |
| 47 | `gift_card_transactions` | "Barbers can view gift card transactions" (SELECT), "Owner has full access to gift card transactions" (ALL) |
| 48 | `barber_referrals` | "Barbers can view their own referral data" (SELECT), "Owner full access to barber_referrals" (ALL) |
| 49 | `referral_events` | "Anyone can insert referral events" (INSERT, authenticated+anon — public click tracking), "Barbers can view their own referral events" (SELECT), "Owner full access to referral_events" (ALL) |
| 50 | `upsell_rules` | "All staff can view upsell rules" (SELECT owner+barber), "Owner has full access to upsell rules" (ALL) |

## 14. Migrations (3 migrations)

| # | Migration | What it did |
|---|---|---|
| 51 | `019_referral_tracking.sql` | Core schema: `barber_referrals`, `referral_events`, indexes, RLS, `update_barber_referrals_updated_at` + `update_referral_metrics` triggers, `record_referral_event` RPC, `referral_funnel_summary` view |
| 52 | `020_engagement_upsell.sql` | Core schema: `customer_loyalty`, `loyalty_config`, `gift_cards`, `gift_card_transactions`, `upsell_rules`, indexes, RLS, `add_loyalty_punch` + `redeem_loyalty_reward` RPCs, default loyalty_config row (punches_required=10) |
| 53 | `20260302212315_referral_conversion_trigger.sql` | `handle_referral_conversion()` trigger fn + `tr_referral_conversion` trigger on `service_transactions` |
| 54 | (Not yet enumerated — verify) | Migration(s) that added `walkin_discount_percent`, `booking_discount_percent`, `waive_fee_on_redemption` to `loyalty_config` — columns exist in prod but original migration under `019`/`020` did NOT include them. Surface drift to investigate. |

## 15. External integrations (1 integration)

| # | System | Touch point |
|---|---|---|
| 55 | Twilio | Referral-code SMS templates (if any winback/referral blast uses referral codes — audit `sms_templates.body` for `{{referral_code}}`) |

## 16. Environment variables

| # | Var | Purpose |
|---|---|---|
| 56 | `NEXT_PUBLIC_APP_URL` | Shareable referral link base (`{APP_URL}/?ref=CODE`) |

---

## Surface Totals

- **API routes:** 10 (2 domain-owning + 2 analytics + 4 writing + 2 client-facing)
- **Library hooks:** 3
- **UI files:** 11 (6 components + 5 pages/entry points)
- **Database tables:** 7 domain-owned + 2 touched parents = 9 total
- **Database views:** 1
- **RPC functions:** 4
- **Trigger functions:** 2 maintenance
- **DB triggers:** 3
- **RLS policies:** 7 tables (expected 14+ policies)
- **Migrations:** 3 known + 1 drift to investigate
- **External integrations:** 1
- **Environment variables:** 1

**Grand total surfaces to audit:** 55+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
