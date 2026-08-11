# Communications Domain — Surface Inventory

**Last verified:** 2026-04-24 against MT Barbershop production.
**Purpose:** Exhaustive list of every surface the SMS / communications system touches. The audit MUST tick through every item here — none skipped.

When an audit finds a surface that isn't listed here, add it to the report's "Surface Drift" section and wait for approval before updating this file.

---

## 1. API Routes — communications-owning (9 routes)

The owner-facing and public SMS management / consent routes.

| # | Route | Methods | Purpose |
|---|---|---|---|
| 1 | `src/app/api/communications/templates/route.ts` | GET/POST/PATCH/DELETE | Template CRUD (`sms_templates`) |
| 2 | `src/app/api/communications/send-blast/route.ts` | POST | Owner blast send → writes `sms_blasts` + enqueues `sms_logs` |
| 3 | `src/app/api/communications/analytics/route.ts` | GET | Delivery analytics (reads `sms_logs`, `sms_blasts`) |
| 4 | `src/app/api/communications/audiences/route.ts` | GET/POST/PATCH/DELETE | `saved_audiences` CRUD |
| 5 | `src/app/api/communications/alerts/route.ts` | GET/PATCH | `owner_alerts` list + mark-read |
| 6 | `src/app/api/communications/opt-out-stats/route.ts` | GET | Aggregated opt-out volume |
| 7 | `src/app/api/communications/settings/[key]/route.ts` | GET/PATCH | Per-key `communication_settings` |
| 8 | `src/app/api/sms-consent/route.ts` | POST | Public SMS consent capture (TCPA consent log) |
| 9 | `src/app/api/analytics/campaigns/route.ts` | GET | Campaign performance (reads `sms_blasts` + `sms_logs`) |

## 2. API Routes — communications-writing (cron + webhook + lifecycle senders) (13 routes)

Every route here WRITES to `sms_logs` or updates reminder flags. All must honor opt-out checks + cron auth + Twilio signature.

| # | Route | Methods | SMS write |
|---|---|---|---|
| 10 | `src/app/api/webhooks/twilio/inbound/route.ts` | POST | Inbound SMS → opt-out parse, STOP/HELP handling, insert `sms_opt_outs` |
| 11 | `src/app/api/webhooks/twilio/status/route.ts` | POST | Twilio status callback → `sms_logs.status` update by `twilio_sid` |
| 12 | `src/app/api/cron/feedback/route.ts` | GET | Post-visit feedback SMS (30-min cron) |
| 13 | `src/app/api/cron/winback/route.ts` | GET | 6/8/12-week winback SMS → writes `winback_sent` |
| 14 | `src/app/api/cron/academy-reminders/route.ts` | GET | Academy session reminder SMS |
| 15 | `src/app/api/cron/grace-period-notifications/route.ts` | GET | Grace-period nudge SMS (commission onboarding) |
| 16 | `src/app/api/cron/service-reminder/route.ts` | GET | Overdue-service barber alert (3-tier L1/L2/L3) |
| 17 | `src/app/api/cron/no-show/route.ts` | GET | No-show advance — may queue SMS |
| 18 | `src/app/api/bookings/reminders/route.ts` | GET | 24h / 1h booking reminders — writes `bookings.reminder_sent` / `one_hour_reminder_sent` |
| 19 | `src/app/api/bookings/send-reminder/route.ts` | POST | Manual resend of booking reminder |
| 20 | `src/app/api/waitlist/notify/route.ts` | POST | Waitlist "open slot" SMS |
| 21 | `src/app/api/waitlist/[id]/route.ts` | PATCH | Waitlist status change (may trigger SMS) |
| 22 | `src/app/api/feedback/route.ts` | POST/PATCH | Feedback submission — may fire low-rating `owner_alerts` |

## 3. API Routes — communications-consumers (SMS fired as side-effect) (14 routes)

These routes aren't owned by the domain but trigger an SMS send. All must check opt-out + use centralized sender.

| # | Route | Trigger |
|---|---|---|
| 23 | `src/app/api/queue/route.ts` | Queue join confirmation SMS |
| 24 | `src/app/api/queue/entry/[id]/route.ts` | Called / in_chair / completed lifecycle SMS |
| 25 | `src/app/api/queue/[token]/route.ts` | Customer tracker page SMS triggers |
| 26 | `src/app/api/queue/entry/[id]/delay/route.ts` | Delay SMS to queued customer |
| 27 | `src/app/api/queue/override-assign/route.ts` | Owner-override assignment SMS |
| 28 | `src/app/api/bookings/route.ts` | Booking confirmation SMS + email |
| 29 | `src/app/api/bookings/[id]/route.ts` | Booking update SMS |
| 30 | `src/app/api/bookings/[id]/reschedule/route.ts` | Reschedule confirmation SMS |
| 31 | `src/app/api/bookings/manage/[code]/route.ts` | Client self-manage cancel/reschedule SMS |
| 32 | `src/app/api/bookings/quick/route.ts` | Walk-in booking confirmation |
| 33 | `src/app/api/barber/clock/route.ts` | Clock in/out SMS (owner alert paths) |
| 34 | `src/app/api/barber/break/route.ts` | Break alert SMS |
| 35 | `src/app/api/barber/[id]/force-status/route.ts` | Owner forced status — alert SMS |
| 36 | `src/app/api/payments/send-link/route.ts` | Payment link SMS to customer |
| 37 | `src/app/api/auth/resend-invite/route.ts` | Barber invite SMS/email |
| 38 | `src/app/api/auth/create-barber/route.ts` | New barber invite |
| 39 | `src/app/api/auth/admin-reset-password/route.ts` | Password reset SMS/email |

## 4. Library / helpers (9 files)

| # | File | Role |
|---|---|---|
| 40 | `src/lib/twilio/client.ts` | Twilio SDK singleton |
| 41 | `src/lib/twilio/sms.ts` | `sendSMS()` + `QueueSMS` + `BookingSMS` + `BarberSMS` sender objects |
| 42 | `src/lib/twilio/templates.ts` | Template rendering (variable interpolation) |
| 43 | `src/lib/twilio/academy-templates.ts` | Academy-specific SMS templates |
| 44 | `src/lib/twilio/validate-signature.ts` | Twilio `validateRequest()` wrapper |
| 45 | `src/lib/twilio/index.ts` | Public exports |
| 46 | `src/lib/email/client.ts` | Resend SDK singleton (email is redundancy channel) |
| 47 | `src/lib/email/templates.ts` | HTML email templates (must use `locationState`) |
| 48 | `src/lib/db/communications.ts` | DB helpers (opt-out checks, template lookup, log insert) |

## 5. UI surfaces (5 pages + 9 components)

| # | Page | Purpose |
|---|---|---|
| 49 | `src/app/(dashboard)/dashboard/communications/page.tsx` | Home: composer + templates + recent |
| 50 | `src/app/(dashboard)/dashboard/communications/templates/page.tsx` | Template library |
| 51 | `src/app/(dashboard)/dashboard/communications/settings/page.tsx` | Global comm settings UI |
| 52 | `src/app/(dashboard)/dashboard/communications/analytics/page.tsx` | Delivery analytics dashboard |
| 53 | `src/app/(dashboard)/dashboard/analytics/retention/page.tsx` | Retention (reads winback/feedback outcomes) |

| # | Component | Purpose |
|---|---|---|
| 54 | `src/components/dashboard/communications/MessageComposer.tsx` | Blast composition |
| 55 | `src/components/dashboard/communications/LivePreview.tsx` | Template preview with placeholder swap |
| 56 | `src/components/dashboard/communications/TemplatesTab.tsx` | Templates CRUD UI |
| 57 | `src/components/dashboard/communications/AudienceSelector.tsx` | Audience builder |
| 58 | `src/components/dashboard/communications/AlertsPanel.tsx` | `owner_alerts` surface |
| 59 | `src/components/dashboard/communications/SettingsTab.tsx` | Settings editor |
| 60 | `src/components/dashboard/communications/AnalyticsTab.tsx` | Charts + breakdown |
| 61 | `src/components/dashboard/communications/RecentPerformance.tsx` | Recent-blast performance |
| 62 | `src/components/dashboard/communications/CommsFooter.tsx` | Legal/footer copy |

## 6. Database tables (8 tables)

| # | Table | Role |
|---|---|---|
| 63 | `sms_templates` | Reusable template body + placeholders |
| 64 | `sms_blasts` | Blast campaign metadata + aggregate counts |
| 65 | `sms_logs` | Every SMS attempt (trigger_type, status, twilio_sid) |
| 66 | `sms_opt_outs` | STOP/UNSUBSCRIBE capture (direction in/out) |
| 67 | `winback_sent` | Winback dedup `(client_id, interval_weeks)` UNIQUE |
| 68 | `owner_alerts` | Low rating / delivery failure / opt-out spike alerts |
| 69 | `communication_settings` | Key-value settings (JSONB) |
| 70 | `saved_audiences` | Saved audience filter JSON |

Parent tables that carry communication flags (NOT comms-owned but MUST be audited):
| 71 | `bookings` | `reminder_sent`, `one_hour_reminder_sent`, `confirmation_sent`, `feedback_sent` |
| 72 | `queue_entries` | `feedback_sent`, `last_notification_sent`, `notification_position` |
| 73 | `clients` | `marketing_opted_out`, `opted_out_at` |

## 7. RPC functions (0 comms-owned)

No RPC functions are owned by the communications domain. `increment_barber_cuts` and other RPCs fire incidental SMS via the caller.

## 8. DB triggers (domain touches)

| # | Trigger | Table | Timing |
|---|---|---|---|
| 74 | `update_sms_templates_updated_at` | `sms_templates` | BEFORE UPDATE |
| 75 | `update_saved_audiences_updated_at` | `saved_audiences` | BEFORE UPDATE |
| 76 | `update_communication_settings_updated_at` | `communication_settings` | BEFORE UPDATE |

## 9. RLS policies (expected coverage)

Expected policies per table. An audit MUST enumerate actual vs expected. (See `audit-rigor.md` Universal Preamble query #2.)

| # | Table | Expected policies |
|---|---|---|
| 77 | `sms_templates` | owner-all, barber-select-if-active |
| 78 | `sms_blasts` | owner-all (blasts are owner-initiated) |
| 79 | `sms_logs` | owner-select-all, service-role-write, barber-read-own (optional) |
| 80 | `sms_opt_outs` | owner-all, service-role-write (webhook), public-insert (opt-out must work without auth) |
| 81 | `winback_sent` | owner-all, service-role-write |
| 82 | `owner_alerts` | owner-all |
| 83 | `communication_settings` | owner-all, authenticated-select |
| 84 | `saved_audiences` | owner-all |

## 10. Migrations (3 migrations)

| # | Migration | What it did |
|---|---|---|
| 85 | `010_communications_system.sql` | Core schema: all 8 SMS tables, indexes, `update_*_updated_at` triggers, seed templates, seed communication_settings |
| 86 | `015_security_audit.sql` | Added `owner_alerts` consumers (low rating detection) |
| 87 | `037_restrict_pii_select_policies.sql` | Restricts PII on profiles/clients that comms reads |

## 11. External integrations (4 integrations)

| # | System | Touch points |
|---|---|---|
| 88 | Twilio | `sendSMS()`, `validateRequest()` (signature check), inbound webhook, status callback |
| 89 | Resend (email) | Transactional email as SMS redundancy channel |
| 90 | Antigravity | MT's automation platform — CLAUDE.md mandates new automations route here, NOT direct Twilio |
| 91 | `owner_alerts` | Internal pseudo-integration for low-rating + delivery-failure + opt-out-spike |

## 12. Cron / background jobs (6 jobs)

| # | Route | Schedule | Purpose |
|---|---|---|---|
| 92 | `src/app/api/cron/feedback/route.ts` | every 30 min | Post-visit feedback SMS |
| 93 | `src/app/api/cron/winback/route.ts` | daily | 6/8/12-week winback |
| 94 | `src/app/api/cron/academy-reminders/route.ts` | daily | Academy session reminders |
| 95 | `src/app/api/cron/grace-period-notifications/route.ts` | daily | Commission grace-period nudge |
| 96 | `src/app/api/cron/service-reminder/route.ts` | every N min | Overdue-service SMS to barbers |
| 97 | `src/app/api/bookings/reminders/route.ts` | hourly | 24h + 1h booking reminders |

## 13. Environment variables

| # | Var | Purpose |
|---|---|---|
| 98 | `TWILIO_ACCOUNT_SID` | Twilio SDK auth |
| 99 | `TWILIO_AUTH_TOKEN` | Signature verification + SDK auth |
| 100 | `TWILIO_PHONE_NUMBER` | Sender number (single per CLAUDE.md; scale plan calls for per-location) |
| 101 | `RESEND_API_KEY` | Email sending |
| 102 | `RESEND_FROM_EMAIL` | Sender identity |
| 103 | `CRON_SECRET` | Bearer token for cron endpoints |
| 104 | `N8N_WEBHOOK_URL` / `N8N_WEBHOOK_SECRET` | Legacy (Antigravity now) — flag usage if still referenced |

---

## Surface Totals

- **API routes:** 9 owning + 13 writing + 17 consumers = 39 total (counting 23–39 = 17 consumers)
- **Library files:** 9
- **UI pages:** 5 + 9 components = 14
- **Database tables:** 8 comms-owned + 3 comms-touched = 11 total
- **RPC functions:** 0
- **DB triggers:** 3
- **RLS policies:** 8+ (across 8 tables)
- **Migrations:** 3
- **External integrations:** 4
- **Cron jobs:** 6
- **Environment variables:** 7

**Grand total surfaces to audit:** ~104 discrete items.

**Any audit that touches fewer than ~90% of these surfaces is INCOMPLETE.**

---

## How to Use This Inventory

1. At the start of audit mode, copy the Surface Totals into the scratchpad.
2. As each surface is checked, mark PASS / FAIL / NOT-RUN against it.
3. At the end, the Coverage Report MUST account for every single numbered item above.
4. A NOT-RUN row must include a reason (e.g., "could not open — file not found" — which is itself a FAIL for that surface).
