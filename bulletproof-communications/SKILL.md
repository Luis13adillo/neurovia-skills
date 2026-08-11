---
name: bulletproof-communications
description: Audit, diagnose, or scale-check the MT Barbershop communications system (SMS templates, blasts, opt-outs, Twilio inbound/status webhooks, cron-driven feedback / winback / reminder / grace-period SMS). Use when SMS delivery fails, opt-outs leak, duplicate messages fire, templates render wrong, or before adding new SMS automations. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to production DB.
---

# Bulletproof Communications

Every customer interaction with MT outside the shop flows through SMS — queue position alerts, booking reminders, feedback prompts, winback campaigns. A duplicated message, a leaked opt-out, or a webhook signature failure means customers lose trust or MT gets a TCPA complaint.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "System D: Communication Triggers" section, Antigravity automation rule.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — Automation Platform Change (n8n → Antigravity), location data canonical.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.

**ALWAYS run this schema verification first** (column name drift is real — see `bulletproof-queue`'s `punches_count → current_punches` incident):

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('sms_templates', 'sms_blasts', 'sms_logs',
                     'sms_opt_outs', 'owner_alerts', 'communication_settings',
                     'winback_sent')
ORDER BY table_name, ordinal_position;
```

If any of this skill's queries reference a column that isn't in that output, STOP and update the query.

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**. `audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that edits code, and only under the explicit gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (~104 surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration (Twilio, Resend, Antigravity, owner_alerts). Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one file's behavior depends on another that looks unrelated. A PASS on the left without evidence of auditing the right = COUPLING VIOLATION.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| Any outbound sender in `src/lib/twilio/sms.ts` (`sendSMS`, `QueueSMS`, `BookingSMS`, `BarberSMS`) | (a) opt-out check against `sms_opt_outs` + `clients.marketing_opted_out` (`src/lib/db/communications.ts`) BEFORE send, (b) `sms_logs` INSERT after send with `twilio_sid` captured, (c) `owner_alerts` write on delivery failure, (d) rate-limit wrapper | Missing opt-out check = TCPA exposure. Missing log = no delivery audit trail. Missing `twilio_sid` = status callback can't dedupe. |
| `webhooks/twilio/inbound/route.ts` (STOP/HELP handler) | (a) `sms_opt_outs` INSERT with `direction='in'`, (b) `clients.marketing_opted_out` UPDATE by phone, (c) `winback_sent` suppression logic in `cron/winback/route.ts`, (d) `communications/send-blast/route.ts` audience filter excludes opted-out | Opt-out must propagate through EVERY future send path. If winback cron ignores opt-outs, TCPA violation. |
| `webhooks/twilio/status/route.ts` (delivery status callback) | (a) idempotent UPDATE on `sms_logs` keyed by `twilio_sid`, (b) `owner_alerts` write on `failed`/`undelivered`, (c) Twilio signature verification via `validate-signature.ts`, (d) NO state regression (delivered cannot be overwritten by earlier sent) | Missing idempotency = duplicate alerts. Missing signature = spoofable webhook. |
| `cron/feedback/route.ts` | (a) `queue_entries.feedback_sent` / `bookings.feedback_sent` flag UPDATE AFTER Twilio success, (b) `sms_logs` INSERT with `trigger_type='feedback'`, (c) opt-out pre-check, (d) `CRON_SECRET` bearer auth, (e) feedback URL generation bound to `queue_entry_id` / `booking_id` | Flag-before-send = silent duplicate. Flag-never = re-sent every cron tick. Missing booking/entry linkage = feedback orphan. |
| `cron/winback/route.ts` | (a) `winback_sent (client_id, interval_weeks)` UNIQUE dedup, (b) opt-out pre-check, (c) `clients.last_visit_at` window computation, (d) `sms_logs` INSERT with `trigger_type='winback'`, (e) `CRON_SECRET` auth | Unique index prevents double-winback. Without opt-out check, STOP customers keep getting winback. |
| `bookings/reminders/route.ts` (24h + 1h) | (a) `bookings.reminder_sent` / `bookings.one_hour_reminder_sent` flag UPDATE AFTER send, (b) opt-out check, (c) `locationState` passed to email template (Edwardsville PA fix), (d) timezone-aware date filter using `America/New_York`, (e) `CRON_SECRET` auth | Flag ordering bug = duplicate reminders. UTC-vs-ET = reminder fires at wrong hour. Missing `locationState` = "Edwardsville, DE" wrong-state email. |
| `cron/grace-period-notifications/route.ts` | (a) `barbers.grace_period_ends_at` + `barbers.commission_acknowledged_at` read, (b) `owner_alerts` write, (c) `sms_logs` INSERT, (d) `CRON_SECRET` auth, (e) coupled to commission domain's grace period logic | Silent cron failure = barber unaware of grace ending. Coupled to commission — flag for cross-skill audit. |
| `cron/academy-reminders/route.ts` | (a) `academy_sessions.reminder_sent` flag, (b) opt-out check, (c) `sms_logs` INSERT with `trigger_type='academy_reminder'`, (d) `CRON_SECRET` auth | Same flag-after-send pattern as booking reminders. |
| `cron/service-reminder/route.ts` (L1/L2/L3 barber escalation) | (a) L1 → SMS-only, L2 → SMS + owner copy, L3 → owner alert, (b) `sms_logs` for each tier, (c) `owner_alerts` write at L3, (d) parity with push notification counterpart (see bulletproof-push-notifications) | Tier drift = barbers get L3 before L1. Missing push parity = mobile users get SMS-only while web users get both. |
| `communications/send-blast/route.ts` | (a) audience filter excludes opted-out (`sms_opt_outs` + `clients.marketing_opted_out`), (b) `sms_blasts` row created with draft/scheduled/sending state machine, (c) per-recipient `sms_logs` row with `blast_id` FK, (d) recipient_count / sent_count / failed_count aggregates updated, (e) rate-limit to avoid Twilio per-second cap | Blast without opt-out filter = mass TCPA incident. Missing counts = analytics drift. |
| `sms-consent/route.ts` (public POST) | (a) consent record created (consent is NOT automatic opt-in — explicit), (b) phone normalized before storage, (c) downstream senders check opt-in for marketing categories | Without consent record, marketing sends are non-compliant. |
| Template rendering in `src/lib/twilio/templates.ts` | (a) every `{{placeholder}}` resolved before send (fail loudly on missing), (b) `locationState` passed for email footer, (c) no hardcoded addresses/phones/states in template bodies, (d) renderer used by EVERY sender (no inline template strings) | Hardcoded "Wilmington, DE" leaks to Edwardsville PA customers. Unresolved placeholder = "{{client_name}}" literal delivered. |
| `feedback/route.ts` POST (low rating path) | (a) `owner_alerts` INSERT with `type='low_rating'`, (b) NO duplicate alert for same feedback_id, (c) `sms_logs` for any low-rating owner SMS, (d) `feedback.prompted_google_review` flag managed | Duplicate alerts = owner alert fatigue. |
| Any `owner_alerts` INSERT from comms | (a) `type` in known enum (`low_rating`, `delivery_failure`, `opt_out_spike`), (b) `is_read` defaults false, (c) `related_id` set so owner UI can deep-link | Unknown `type` = alert bucket orphan. |
| Antigravity-routed automation | (a) NO direct Twilio SDK usage in new code per CLAUDE.md (route through Antigravity), (b) legacy `N8N_WEBHOOK_URL` references flagged, (c) webhook signature verification on any inbound Antigravity callback | New automations bypassing Antigravity = drift from the documented automation platform. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the communications domain values:

```sql
-- 1. Enumerate communications domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'sms_templates','sms_blasts','sms_logs','sms_opt_outs',
    'winback_sent','owner_alerts','communication_settings','saved_audiences',
    'bookings','queue_entries','clients'
  )
ORDER BY table_name;
-- Expected: 11 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on every comms table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'sms_templates','sms_blasts','sms_logs','sms_opt_outs',
    'winback_sent','owner_alerts','communication_settings','saved_audiences'
  )
ORDER BY tablename, policyname;
-- Expected: at least 8 rows (see SURFACE_INVENTORY.md section 9).
-- Any missing policy or extra-permissive policy = RLS gap; FLAG in coverage report.

-- 3. Triggers on comms-touched tables
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN (
    'sms_templates','sms_blasts','sms_logs','sms_opt_outs',
    'winback_sent','owner_alerts','communication_settings','saved_audiences'
  )
ORDER BY event_object_table, trigger_name;
-- Expected: update_sms_templates_updated_at, update_saved_audiences_updated_at,
--           update_communication_settings_updated_at.

-- 4. RPC functions (no comms-owned RPCs; verify none introduced)
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name ILIKE ANY (ARRAY['%sms%','%blast%','%opt_out%','%winback%']);
-- Expected: 0 rows or explicitly documented additions.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%010%' OR name ILIKE '%communications%'
   OR name ILIKE '%sms%' OR name ILIKE '%opt%out%'
   OR name ILIKE '%015%security%' OR name ILIKE '%pii%'
ORDER BY executed_at;
-- Expected: at least 3 rows (see SURFACE_INVENTORY.md section 10).
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **Twilio webhook signature verification**
   - Files: `src/app/api/webhooks/twilio/inbound/route.ts`, `src/app/api/webhooks/twilio/status/route.ts`
   - Must verify `X-Twilio-Signature` header against `TWILIO_AUTH_TOKEN` before processing.
   - Grep: `grep -rn "X-Twilio-Signature\|validateRequest" src/app/api/webhooks/twilio/`

2. **Opt-out keywords recognized**
   - File: `src/app/api/webhooks/twilio/inbound/route.ts`
   - Must handle STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT (and their lowercase variants).
   - When received, insert into `sms_opt_outs` with `direction='in'`.
   - Future sends to that phone must check opt-out status.

3. **Every SMS send checks opt-out first**
   - Grep: `grep -rn "sms_opt_outs\|checkOptOut\|isOptedOut" src/lib/twilio/ src/app/api/`
   - Every sender function (BookingSMS, QueueSMS, FeedbackSMS, etc.) queries opt-outs before sending.
   - Missing check = TCPA violation risk.

4. **Cron endpoints require `CRON_SECRET`**
   - `/api/cron/feedback/route.ts`, `/api/cron/winback/route.ts`, `/api/cron/academy-reminders/route.ts`, `/api/cron/grace-period-notifications/route.ts`, `/api/cron/service-reminder/route.ts`, `/api/bookings/reminders/route.ts`
   - Each must verify `Authorization: Bearer ${CRON_SECRET}` header or 401.

5. **Reminder flags updated atomically with SMS send**
   - `bookings.reminder_sent`, `bookings.one_hour_reminder_sent`, `winback_sent.sent_at`, `bookings.feedback_sent`
   - Flag UPDATE must happen AFTER Twilio returns success. Otherwise: duplicate sends or silent failures.

6. **Template placeholder rendering**
   - Files: `src/lib/twilio/templates/*`
   - Templates must use variable interpolation (e.g., `{{customer_name}}`, `{{barber_name}}`, `{{location.address}}`).
   - Grep for hardcoded names, addresses, phones in templates.

7. **Status webhook idempotency**
   - `sms_logs.twilio_sid` is the dedup key. Status updates for the same `twilio_sid` must be idempotent (same-state re-applies OK; earlier states must not overwrite later states).

### Data-level invariants

Run `references/audit-queries.sql`. SELECT-only.

### Output template — MANDATORY Coverage Report

Every communications audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Communications Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: X/11 PASS | FAIL (list missing)
- RLS policies found: X (expected ≥8) — list any gaps
- Triggers found: X/3
- RPCs found: X (expected 0 comms-owned)
- Migrations confirmed: X/3

### Findings
[Ranked critical/high/medium/low with file:line anchors]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (61 files from SURFACE_INVENTORY.md sections 1-5) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/communications/templates/route.ts | PASS/FAIL/NOT-RUN | e.g. "templates/route.ts:58 — Zod body schema rejects empty template" |
| 2 | src/app/api/communications/send-blast/route.ts | | |
| ... | [all 61 from §§1-5] | | |

Files audited with proof-of-read: N / 61 (target: 61/61). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (11 tables from SURFACE_INVENTORY.md section 6)
| Table | Row count | Status dist | NULL violations | Verdict |
|---|---|---|---|---|
| sms_templates | | is_active split | | |
| sms_blasts | | draft/scheduled/sending/completed/cancelled | | |
| sms_logs | | queued/sent/delivered/failed/undelivered/skipped_* | | |
| sms_opt_outs | | direction in/out | | |
| winback_sent | | per interval_weeks | | |
| owner_alerts | | by type | | |
| communication_settings | | | | |
| saved_audiences | | | | |
| bookings (reminder flags) | | | | |
| queue_entries (feedback_sent) | | | | |
| clients (marketing_opted_out) | | | | |

Tables audited: N / 11

### Pillar 3 — Queries (14 queries from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 0 | schema_verification | | |
| 1 | opted_out_still_received | | |
| 2 | duplicate_24h_reminders | | |
| 3 | reminder_sent_no_log | | |
| ... | [all queries] | | |

Queries run: N / 14. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (8 comms tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| sms_templates | | 2 | |
| sms_blasts | | 1+ | |
| sms_logs | | 2+ | |
| sms_opt_outs | | 3 (owner, service-role, public-insert) | |
| winback_sent | | 2 | |
| owner_alerts | | 1 | |
| communication_settings | | 2 | |
| saved_audiences | | 1 | |

RLS tables audited: N / 8

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 8, 11, 12)
| Integration | Verdict | Note |
|---|---|---|
| Trigger: update_sms_templates_updated_at | | |
| Trigger: update_saved_audiences_updated_at | | |
| Trigger: update_communication_settings_updated_at | | |
| Twilio: inbound webhook signature | | |
| Twilio: status callback idempotency | | |
| Resend: transactional email | | |
| Antigravity: automations path | | |
| owner_alerts: low_rating / delivery_failure / opt_out_spike | | |
| Cron: feedback (every 30 min) | | |
| Cron: winback (daily) | | |
| Cron: academy-reminders (daily) | | |
| Cron: grace-period-notifications (daily) | | |
| Cron: service-reminder | | |
| Cron: bookings/reminders (hourly) | | |

Integrations audited: N / 14

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| Outbound sender → {opt-out check, sms_logs INSERT, twilio_sid capture, owner_alerts on failure, rate limit} | YES/NO | |
| Inbound STOP → {sms_opt_outs INSERT, clients.marketing_opted_out UPDATE, winback suppression, blast filter} | YES/NO | |
| Status webhook → {idempotent sms_logs UPDATE, owner_alerts on failed, signature verify, no state regression} | YES/NO | |
| cron/feedback → {feedback_sent flag after send, sms_logs, opt-out pre-check, CRON_SECRET, entry/booking linkage} | YES/NO | |
| cron/winback → {winback_sent UNIQUE dedup, opt-out pre-check, last_visit window, sms_logs, CRON_SECRET} | YES/NO | |
| bookings/reminders → {reminder_sent flag after send, opt-out, locationState, TZ filter, CRON_SECRET} | YES/NO | |
| grace-period cron → {grace_period_ends_at read, commission_acknowledged_at, owner_alerts, sms_logs, CRON_SECRET} | YES/NO | |
| academy-reminders → {session reminder_sent flag, opt-out, sms_logs, CRON_SECRET} | YES/NO | |
| service-reminder (L1/L2/L3) → {tier escalation, sms_logs per tier, owner_alerts at L3, push parity} | YES/NO | |
| send-blast → {audience excludes opt-outs, sms_blasts state machine, per-recipient sms_logs, aggregate counts, rate limit} | YES/NO | |
| sms-consent → {consent record, phone normalization, marketing opt-in gating} | YES/NO | |
| Template rendering → {placeholder resolution, locationState, no hardcoded address/phone, single renderer} | YES/NO | |
| feedback low-rating → {owner_alerts type=low_rating, dedup, sms_logs, prompted_google_review flag} | YES/NO | |
| owner_alerts INSERT → {type enum, is_read default, related_id for deep-link} | YES/NO | |
| Antigravity routing → {no direct Twilio in new code, N8N legacy flagged, inbound signature verified} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/waitlist/notify/route.ts] | Writes sms_logs without verifying opt-out path | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Twilio Console delivery dashboard, Antigravity workflow logs, etc.): <list>.

If zero gaps: write "No gaps identified. All 104 surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 104 (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL COMMUNICATIONS AUDIT — N surfaces unaudited, M coupling violations" instead of "Communications Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for symptom. Examples:
   - "Customer got 3 copies of the same reminder SMS"
   - "Customer replied STOP but still got a booking reminder"
   - "Winback cron fired for someone who booked last week"
   - "Delivery status webhook shows failed but SMS appeared to send"
   - "Owner alert for low rating fires twice for the same feedback"
   - "Antigravity automation didn't trigger after a booking was made"

2. Match against `references/incidents.md`.

3. Three-file rule. Two-strike rule. Stay in scope.

---

## Mode: scale-check

1. **SMS volume scaling**
```sql
SELECT DATE_TRUNC('day', created_at) AS day,
       COUNT(*) FILTER (WHERE status = 'sent')      AS sent,
       COUNT(*) FILTER (WHERE status = 'delivered') AS delivered,
       COUNT(*) FILTER (WHERE status = 'failed')    AS failed
FROM sms_logs
WHERE created_at > now() - interval '30 days'
GROUP BY day
ORDER BY day DESC;
```
Flag if daily volume trends sharply upward — Twilio has per-second rate limits.

2. **Opt-out rate** (FCC concern at scale)
```sql
SELECT COUNT(*) AS opt_outs_last_30d
FROM sms_opt_outs
WHERE created_at > now() - interval '30 days';
```
If > 2% of active customer base opted out in 30d, MT has a messaging-strategy problem.

3. **Twilio number capacity**
   - Single TWILIO_PHONE_NUMBER currently serves all locations.
   - At scale, consider location-specific numbers for better deliverability + compliance. Flag for future.

4. **Cron job scale**
   - Feedback cron runs every 30 min; winback daily. All single-threaded.
   - At 10x customer volume, consider batch processing or moving to Antigravity workflows.

5. **Antigravity dependency**
   - MT uses Antigravity for automations (per MEMORY.md). Any new automation path should route through Antigravity, not custom code.
   - Flag any new automation code that bypasses Antigravity.

## Mode: fix

The only mode that writes code. Closes the loop between "audit/diagnose found X" and "X is fixed + verified." Does NOT commit, does NOT push, does NOT touch the production DB. See `references/fix-patterns.md` for the canonical patterns.

### Activation is EXPLICIT

Fix mode fires ONLY when the user types one of:
- `apply pattern N` — N is a pattern number from `references/fix-patterns.md`
- `fix <symptom-phrase>` — natural-language form; the skill maps to a pattern and CONFIRMS before doing anything
- `enter fix mode` followed by a scope

Any other phrasing → audit/diagnose instead. An audit finding NEVER auto-triggers a fix.

### Workflow (strict — every step, no shortcuts)

1. **Scope declaration.** Restate in 1–2 sentences which pattern (number + name), which file(s) will change, any mirror-page impact.
2. **Preflight.** Read the target file. Confirm the "before" block from `fix-patterns.md → Pattern N` still matches current code — imports, function signatures, surrounding context, NOT line numbers (which drift). If drift → STOP and report what differs. Do NOT apply a stale pattern.
3. **Scope audit.** Confirm the fix touches ONLY files named in the pattern's Before/After blocks. If a fix would require touching an unrelated system → STOP and ask for approval before expanding.
4. **Diff proposal.** Show the exact `old_string` / `new_string` the skill will pass to `Edit`. Wait for the user to type `yes` / `apply` / `proceed`. No implicit approval.
5. **Apply.** Single `Edit` call. ONE pattern per fix-mode invocation. Never bundled.
6. **Post-fix verification.** `npx tsc --noEmit` passes. Re-run the pattern's post-fix grep and/or SQL check — must pass. For UI patterns, explicitly tell the user "you must test this in the browser before shipping — I can't verify UI."
7. **Mirror check.** If the fix touches any page in the Cross-Dashboard Code Mirroring map (`.claude/rules/context-awareness.md`), invoke the `mirror-check` skill before handoff.
8. **Handoff to `bulletproof-ship`.** Fix mode DOES NOT commit, stage, or push. Propose a branch name (`fix/<domain>-<pattern-slug>`) and a commit message in MT's conventional format, then tell the user to invoke `bulletproof-ship`.

### Integration with other skills

| Skill | Role |
|---|---|
| `bulletproof-ship` | Final step. Commit + push + deploy safety. Mandatory. |
| `mirror-check` | Cross-dashboard enforcement for any dashboard-touching fix. |
| `safe-query` | If a pattern requires DB writes (rare), route through safe-query. |

---

## HARD RULES

- NEVER write to production DB. No test SMS inserts. No marking opt-outs manually.
- NEVER send a test SMS to a real customer phone during diagnose.
- NEVER bypass opt-out checks to "test" a send — TCPA fines are real.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Stay in scope.
