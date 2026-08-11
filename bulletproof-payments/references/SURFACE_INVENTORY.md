# Payments Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the payment collection / Stripe webhook pipeline touches. The audit MUST tick through every item here — none skipped.

Scope boundary reminder: this skill covers the PAYMENT UX and webhook processing. The fee-ledger side (commission math, cash_fee_ledger, barber_payouts, commission_waiver_audit) lives in `bulletproof-commission`. A complete review of a payment-related incident usually spans BOTH skills.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — payment-owning (2 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/payments/checkout/route.ts` | POST | Creates Stripe Checkout Session for in-person card payments (walk-in and booking). Calls `determinePaymentRouting()`, writes metadata (`queue_entry_id` / `booking_id`, `barber_id`, `tip_amount`, fee fields). |
| 2 | `src/app/api/payments/send-link/route.ts` | POST | Creates payment link, SMSes + emails it to client. Same metadata contract as checkout. |

## 2. API Routes — webhook processing (1 route)

| # | Route | Purpose |
|---|---|---|
| 3 | `src/app/api/webhooks/stripe/route.ts` | Single Stripe webhook endpoint. Handles: `checkout.session.completed`, `checkout.session.expired`, `customer.subscription.created`, `invoice.payment_succeeded`, `invoice.payment_failed`, `customer.subscription.deleted`, `charge.refunded`, `payment_intent.payment_failed`, `payout.paid/failed/updated`, `account.updated`. Idempotency via `stripe_webhook_events` atomic INSERT; service_role via `createAdminClient()`. |

## 3. API Routes — completion handlers that write payment fields (4 routes)

These routes receive `payment_method` / `tip_amount` / `service_amount` from `PaymentCollectionModal` and persist them. Complement to commission skill — same routes also write fee columns.

| # | Route | Payment write |
|---|---|---|
| 4 | `src/app/api/queue/entry/[id]/route.ts` | PATCH completion → sets `payment_method`, `service_amount`, `tip_amount`, `total_amount`, `payment_status`, `stripe_payment_id` on `queue_entries` |
| 5 | `src/app/api/queue/complete/route.ts` | Alt completion path → same fields |
| 6 | `src/app/api/bookings/[id]/route.ts` | PATCH completion → same fields on `bookings` |
| 7 | `src/app/api/bookings/quick-complete/route.ts` | Quick complete → same fields on `bookings` |

## 4. API Routes — Stripe Connect (4 routes)

Connect affects payment ROUTING (direct-to-barber vs platform-plus-transfer). Fee math lives in commission skill, but the OAuth + status surface is payments-side.

| # | Route | Methods | Purpose |
|---|---|---|---|
| 8 | `src/app/api/barber/stripe/connect/route.ts` | POST | Initiate Connect OAuth — generates account link |
| 9 | `src/app/api/barber/stripe/callback/route.ts` | GET | Connect OAuth callback — stores `stripe_account_id`, sets `stripe_charges_enabled` |
| 10 | `src/app/api/barber/stripe/status/route.ts` | GET | Read barber Connect status |
| 11 | `src/app/api/barber/stripe/dashboard/route.ts` | GET | Returns Stripe Express dashboard login link |

## 5. API Routes — other payment-touching (3 routes)

| # | Route | Methods | Purpose |
|---|---|---|---|
| 12 | `src/app/api/checkout/route.ts` | POST | Generic checkout entry (older path; verify whether still wired) |
| 13 | `src/app/api/academy/checkout/route.ts` | POST | Academy enrollment checkout — creates subscription / one-time charge. Feeds into academy webhook branches. |
| 14 | `src/app/api/academy/verify-payment/route.ts` | POST | Verifies academy checkout session status |

## 6. Library / helpers (4 files)

| # | File | Role |
|---|---|---|
| 15 | `src/lib/stripe/server.ts` | `getStripe()`, `isStripeConfigured()`, `getStripeKeyMode()`, `verifyWebhookSignature()`. Lazy singleton. Warns on live/test key mismatch with `NODE_ENV`. |
| 16 | `src/lib/stripe/client.ts` | Browser-side Stripe.js loader |
| 17 | `src/lib/stripe/connect-helpers.ts` | `determinePaymentRouting()` — computes `fee_settlement_status`, `owner_fee_amount`, `barber_net_amount`, `application_fee_amount`, whether to use Connect destination charge. Single source of truth for fee/routing math. |
| 18 | `src/lib/stripe/index.ts` | Barrel export |

## 7. UI surfaces (9 files)

| # | File | Role |
|---|---|---|
| 19 | `src/components/dashboard/PaymentCollectionModal.tsx` | The modal — Cash / Card / Send Link buttons, tip quick-picks + custom, loyalty + gift card + upsell integration, Stripe redirect callback. Surfaces `PaymentData` to caller. |
| 20 | `src/components/dashboard/PostServiceFlow.tsx` | Wraps PaymentCollectionModal + loyalty punch + rebook prompt + smart routing. Called after service completion in barber + owner My Chair views. |
| 21 | `src/components/barber/TipBreakdownCard.tsx` | Barber view of tip totals |
| 22 | `src/app/(dashboard)/dashboard/my-chair/page.tsx` | Owner-as-barber My Chair — invokes PaymentCollectionModal on "Complete Service" |
| 23 | `src/app/(dashboard)/dashboard/my-chair/queue/page.tsx` | Owner's personal queue — payment collection entrypoint |
| 24 | `src/app/(dashboard)/dashboard/my-chair/calendar/page.tsx` | Owner calendar — payment collection on booking complete (dynamic import) |
| 25 | `src/app/(dashboard)/dashboard/calendar/page.tsx` | Owner all-bookings calendar — payment collection |
| 26 | `src/app/(dashboard)/dashboard/bookings/page.tsx` | Owner bookings table — payment collection |
| 27 | `src/app/(dashboard)/barber/walk-ins/page.tsx` | Barber My Chair — payment collection entrypoint |
| 28 | `src/app/(dashboard)/barber/calendar/page.tsx` | Barber calendar — payment collection (dynamic import) |

## 8. Database tables (3 tables)

Payments-owned tables. Parent tables (`queue_entries`, `bookings`, `service_transactions`) have fee columns but are CO-OWNED with commission skill — audit both sides.

| # | Table | Role |
|---|---|---|
| 29 | `stripe_webhook_events` | Idempotency ledger. PK on `event_id`. Columns: `event_type`, `status` (`processing`/`processed`/`failed`), `processed_at`. |
| 30 | `queue_entries` (payment columns) | `payment_method` (`cash`/`card`/`link`), `payment_status`, `service_amount`, `tip_amount`, `total_amount`, `stripe_payment_id` |
| 31 | `bookings` (payment columns) | Same 6 columns as queue_entries |
| 32 | `service_transactions` (payment columns) | `payment_method`, `payment_status`, `service_amount`, `tip_amount`, `total_amount`, `stripe_payment_id`, `stripe_payment_link`, `payment_completed_at` — single-source-of-truth for post-completion revenue reads |

## 9. DB triggers touching payment state (2 triggers)

Commission skill owns the fee-writing triggers. Payment skill must still verify these fire correctly because they gate `service_transactions` creation.

| # | Trigger | Table | Timing | Payment relevance |
|---|---|---|---|---|
| 33 | `create_service_transaction_from_queue` | `queue_entries` | AFTER UPDATE | When payment_status transitions, this is the trigger that creates the `service_transactions` row the webhook later updates |
| 34 | `create_service_transaction_from_booking` | `bookings` | AFTER UPDATE | Same for bookings |

(Full trigger audit lives in commission skill; here we just verify they exist.)

## 10. RLS policies (1 payment-owned table)

| # | Table | Expected policies |
|---|---|---|
| 35 | `stripe_webhook_events` | "Service role only" (ALL) — NO other role should access. Verify no anon / authenticated / public policies exist. |

Parent tables (`queue_entries`, `bookings`, `service_transactions`) have their own RLS patterns audited in other skills (`bulletproof-queue`, `bulletproof-bookings`, `bulletproof-commission`).

## 11. Migrations (3 migrations)

| # | Migration | What it did |
|---|---|---|
| 36 | `008_add_stripe_connect.sql` | Added `stripe_account_id`, `stripe_charges_enabled` on `barbers` |
| 37 | `024_service_transactions_audit.sql` | `service_transactions` table — includes stripe_payment_id + stripe_payment_link + payment_method enum |
| 38 | `036_webhook_idempotency.sql` | `stripe_webhook_events` table + "Service role only" RLS |

## 12. External integrations (4 integrations)

| # | System | Touch points |
|---|---|---|
| 39 | Stripe (platform) | Checkout Sessions, Payment Intents, Payment Links, Charges, Refunds. Key detection via `getStripeKeyMode()` (`sk_live_*` / `sk_test_*`). |
| 40 | Stripe Connect | OAuth account link creation, `account.updated` webhook syncs `stripe_charges_enabled`. Destination charges via `application_fee_amount`. |
| 41 | Twilio | `QueueSMS.sendPaymentLinkSms` (payment link delivery) via `/api/payments/send-link` |
| 42 | Resend / Email | `sendPaymentLinkEmail()` via `/api/payments/send-link` — payment link email template |

## 13. Environment variables

| # | Var | Purpose |
|---|---|---|
| 43 | `STRIPE_SECRET_KEY` | `sk_live_*` in prod, `sk_test_*` in dev. Controls ALL Stripe SDK calls. |
| 44 | `STRIPE_WEBHOOK_SECRET` | HMAC verification for incoming webhooks. MUST exist or webhook endpoint returns 500. |
| 45 | `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` | Browser-side Stripe.js |
| 46 | `NEXT_PUBLIC_APP_URL` | Returned as Stripe `success_url` / `cancel_url` |
| 47 | `RESEND_API_KEY` + `RESEND_FROM_EMAIL` | Payment link email delivery |
| 48 | `TWILIO_ACCOUNT_SID` + `TWILIO_AUTH_TOKEN` + `TWILIO_PHONE_NUMBER` | Payment link SMS delivery |

## 14. Webhook event handlers (event-type coverage)

Each event type is a surface. An audit must confirm the handler exists and the DB write is correct.

| # | Event | Handler location (route.ts case) | DB writes |
|---|---|---|---|
| 49 | `checkout.session.completed` (academy) | academy_enrollment branch | `academy_enrollments.payment_status/amount_paid/status/enrolled_at` + welcome SMS/email |
| 50 | `checkout.session.completed` (walk_in_payment / barber_checkout) | walk-in branch | `queue_entries` payment fields + `service_transactions` sync |
| 51 | `checkout.session.completed` (booking_payment / booking_checkout) | booking branch | `bookings` payment fields + `service_transactions` sync |
| 52 | `checkout.session.expired` (academy / walk-in / booking) | three branches | mark status=cancelled/payment_status=failed (with `.neq('payment_status','paid')` guard) |
| 53 | `customer.subscription.created` | academy branch | `academy_enrollments.stripe_subscription_id` |
| 54 | `invoice.payment_succeeded` | academy subscription branch | `academy_enrollments.amount_paid` + payment confirmation SMS |
| 55 | `invoice.payment_failed` | academy subscription branch | `payment_status=overdue` + payment failed SMS/email |
| 56 | `customer.subscription.deleted` | academy branch | `payment_status=cancelled` when not paid in full |
| 57 | `charge.refunded` | refund branch | `queue_entries`/`bookings` `payment_status=refunded` + `cash_fee_ledger.status=waived` + `service_transactions.payment_status=refunded` |
| 58 | `payment_intent.payment_failed` | log-only | no DB write — retry handled in same session |
| 59 | `payout.paid` / `payout.failed` / `payout.updated` | log-only | audit log only |
| 60 | `account.updated` | Connect branch | `barbers.stripe_charges_enabled` |

---

## Surface Totals

- **API routes:** 14 (2 payment-owning + 1 webhook + 4 completion handlers + 4 Connect + 3 other)
- **Library files:** 4
- **UI files:** 10
- **Database tables:** 1 payment-owned (`stripe_webhook_events`) + 3 payment-touched parents (`queue_entries`, `bookings`, `service_transactions`) = 4 total
- **DB triggers:** 2 (payment-relevant subset of commission triggers)
- **RLS policies:** 1 table (`stripe_webhook_events`) — service_role only
- **Migrations:** 3
- **External integrations:** 4 (Stripe, Stripe Connect, Twilio, Resend)
- **Environment variables:** 6
- **Webhook event handlers:** 12 distinct event cases (some multi-branch)

**Grand total surfaces to audit:** 60+ discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
