---
name: bulletproof-loyalty-referrals
description: Audit, diagnose, or scale-check the MT Barbershop loyalty and referral systems (customer_loyalty, loyalty_config, gift_cards, gift_card_transactions, barber_referrals, referral_events, upsell_rules). Use when punches don't record, rewards don't redeem, gift card balances drift, referral credits go missing, or before launching a loyalty campaign. Read-only SQL via mcp__supabase-mt__execute_sql only. Never writes to production DB.
---

# Bulletproof Loyalty & Referrals

Loyalty and referrals drive repeat revenue. A missed punch = a disgruntled customer who never gets their free cut. A bad gift card = a chargeback. A lost referral credit = a barber who stops promoting MT.

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "System H: Referral & Loyalty Program" section.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — Zero Production Data Contamination rule.
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 7, 8, 9.

**CRITICAL: verify schema first. CLAUDE.md has doc drift on the loyalty column names.**

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('customer_loyalty', 'loyalty_config',
                     'gift_cards', 'gift_card_transactions',
                     'barber_referrals', 'referral_events',
                     'upsell_rules')
ORDER BY table_name, ordinal_position;
```

**Known column name note:** `customer_loyalty` uses `current_punches` and `total_punches_earned` — NOT `punches_count` and `rewards_earned` (CLAUDE.md is stale here per bulletproof-queue's earlier audit).

---

## Choose a Mode

- **audit**, **diagnose**, **scale-check**, or **fix**. `audit`, `diagnose`, and `scale-check` are READ-ONLY. `fix` is the only mode that edits code, and only under the explicit gate described in its section.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (55+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy (7 tables × 2+ policies = 14+ policies expected), EVERY trigger (3), EVERY RPC (4 business + 2 maintenance). Stopping after one finding is a half-audit and is explicitly forbidden.
>
> Silence ≠ Pass. Self-declaration ≠ Proof. Every PASS needs a file:line citation.
>
> Obey the Cross-Surface Coupling Rules below. Skipping a coupled surface while passing its partner = coupling violation.
>
> The Coverage Report + Gap Self-Report are MANDATORY. A report missing either is rejected. If NOT-RUN > 0, the header must say "PARTIAL AUDIT".

---

## Cross-Surface Coupling Rules — MUST be followed

When you audit a surface on the left, you MUST also audit all surfaces on the right in the same session. These rules catch the systemic gaps where one file's behavior depends on another that looks unrelated.

| If you audit... | You MUST also audit... | Why |
|---|---|---|
| `api/loyalty/route.ts` action=add_punch | `add_loyalty_punch(p_phone)` RPC body + `customer_loyalty.current_punches` increment + `last_punch_at` update + caller alignment in `queue/complete/route.ts` + `bookings/[id]/route.ts` | The punch write is split across a POST endpoint AND two completion routes. Any one that UPDATEs directly instead of calling the RPC = race condition. |
| `api/loyalty/route.ts` action=redeem_reward | `redeem_loyalty_reward(p_phone)` RPC body + `current_punches` decrement by `loyalty_config.punches_required` + `rewards_redeemed` increment + `queue_entries.loyalty_reward_applied` OR `bookings.loyalty_reward_applied` true + discount math in completion (walkin_discount_percent / booking_discount_percent / waive_fee_on_redemption) | Redemption touches 3 tables + 2 config discount paths. Missing any = customer gets free cut AND still charged, or gets charged and no punches deducted. |
| `api/referrals/track/route.ts` (click events) | `record_referral_event` RPC body + `referral_events` INSERT + `trigger_update_referral_metrics` firing → `barber_referrals.total_referrals` + RLS "Anyone can insert referral events" (public INSERT) still present | If the public INSERT policy is missing, anon click tracking silently 403s. |
| `api/queue/route.ts` check-in with `?ref=CODE` | `referral_events` visit insert + `record_referral_event` called (not direct INSERT) + queue_entries linked via `queue_entry_id` column | Visit must be linked to the queue entry so conversion can match later. Direct INSERT skipping the RPC = missing validation + wrong earnings calc. |
| `api/bookings/route.ts` create with `?ref=CODE` | Same as queue: `referral_events` visit insert + booking_id link + RPC path used | Mirror of queue — breaks independently. |
| `tr_referral_conversion` trigger on `service_transactions` | `handle_referral_conversion()` function body + upstream `visit` event existence (matched by phone) + `record_referral_event(event_type='conversion')` call + `barber_referrals.successful_conversions` + `total_earnings` increment (commission_rate × 1) | Conversion trigger silently no-ops if no prior visit row exists for that phone — customer wasn't tracked. Earnings calc failure = barber never paid. |
| `api/queue/complete/route.ts` loyalty punch | Matches pattern from `/api/bookings/[id]/route.ts` completion + `upsert_client_from_service` RPC (creates customer_loyalty row if new) + `loyalty_reward_applied` column set when reward consumed | Completion must punch AND (if reward applied) flip the column. Drift between queue + booking completion = inconsistent loyalty state depending on entry path. |
| `api/bookings/[id]/route.ts` loyalty punch | Same as queue completion mirror | Must mirror queue's punch pattern exactly. Historically these drifted. |
| Gift card redeem path (any UI → DB write) | `gift_card_transactions` INSERT + `gift_cards.current_balance` decrement + `balance_after` column set + status flip to 'depleted' when balance hits 0 + RLS permits barber/owner write | No RPC exists for this — app code must be atomic. Direct UPDATE of `current_balance` without matching transaction row = audit log gap. |
| `loyalty_config` read | Single-row invariant check + `punches_required` + `reward_type` + `walkin_discount_percent` + `booking_discount_percent` + `waive_fee_on_redemption` columns + migration for extra columns (not in 019/020) | Loyalty math depends on 3 columns that aren't in the documented migration. A missing column causes NaN discounts or NULL pointer. Surface drift must be flagged. |
| `UpsellSuggestionCard.tsx` | `upsell_rules.is_active=true` filter + `base_service_id` FK resolves + `suggested_addon_id` FK resolves + RLS "All staff can view upsell rules" | An inactive or orphan-FK rule surfaced to barber = broken upsell or crash. |
| `ReferralTracker.tsx` mount in `src/app/layout.tsx` | URL `?ref=CODE` read + sessionStorage persistence + POST `/api/referrals/track` on detect + public endpoint accepts anon | If layout.tsx stops mounting it, click tracking is silently dead. |
| `barber_referrals` aggregate columns | `trigger_update_referral_metrics` on `referral_events` AFTER INSERT + `trigger_update_barber_referrals_updated_at` BEFORE UPDATE + per-event-type increment logic in `update_referral_metrics()` | Aggregates drift from events = owner sees wrong conversion rate. Must recompute periodically. |
| `referral_funnel_summary` view | Click→visit ratio + visit→conversion ratio formulas + refreshed-on-read (it's a view, not a matview) + owner analytics endpoint reads it | Stale or broken view = wrong dashboard. |
| Any write to `customer_loyalty` | Only via `add_loyalty_punch` RPC or `upsert_client_from_service` — NO direct UPDATE in app code + RLS "Owner has full access" present | Direct UPDATE bypasses concurrency safety. A single grep hit on `from('customer_loyalty').update(` is a finding. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Cron Surface Must Be Enumerated

Any loyalty/referrals audit MUST run `ls src/app/api/cron/` and `cat vercel.json` and report:
- Any cron route that reads/writes `customer_loyalty`, `barber_referrals`, `gift_cards`, `referral_events`
- Any cron tied to reward expiry, gift-card expiry notifications, or referral-code winback SMS
- Each cron's schedule and last-run evidence (check `owner_alerts` for failures)
- If loyalty/referrals expect NO cron jobs, explicitly state "no loyalty/referral-specific crons found"

This catches systemic gaps where a hidden cron silently wipes punches, expires cards, or fires referral SMS duplicates.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the loyalty+referrals domain values:

```sql
-- 1. Enumerate domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'customer_loyalty','loyalty_config','gift_cards','gift_card_transactions',
    'barber_referrals','referral_events','upsell_rules'
  )
ORDER BY table_name;
-- Expected: 7 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on every domain table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'customer_loyalty','loyalty_config','gift_cards','gift_card_transactions',
    'barber_referrals','referral_events','upsell_rules'
  )
ORDER BY tablename, policyname;
-- Expected: at least 14 rows (see SURFACE_INVENTORY.md section 13).
-- Critical: referral_events MUST have "Anyone can insert referral events" (INSERT, authenticated+anon) for public click tracking.
-- Any missing policy = RLS gap; FLAG in coverage report.

-- 3. Triggers on domain tables + service_transactions (cross-domain conversion trigger)
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN (
    'customer_loyalty','loyalty_config','gift_cards','gift_card_transactions',
    'barber_referrals','referral_events','upsell_rules','service_transactions'
  )
ORDER BY event_object_table, trigger_name;
-- Expected: trigger_update_barber_referrals_updated_at (barber_referrals),
-- trigger_update_referral_metrics (referral_events),
-- tr_referral_conversion (service_transactions).

-- 4. RPC functions in domain
SELECT routine_name, routine_definition IS NOT NULL AS has_body
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'add_loyalty_punch','redeem_loyalty_reward',
    'record_referral_event','handle_referral_conversion',
    'update_referral_metrics','update_barber_referrals_updated_at'
  )
ORDER BY routine_name;
-- Expected: 6 rows, all has_body=true.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%019%' OR name ILIKE '%020%'
   OR name ILIKE '%referral%' OR name ILIKE '%loyalty%' OR name ILIKE '%gift_card%'
   OR name ILIKE '%engagement%' OR name ILIKE '%upsell%'
ORDER BY executed_at;
-- Expected: at least 3 rows — 019_referral_tracking, 020_engagement_upsell,
-- 20260302212315_referral_conversion_trigger.
-- NOTE: loyalty_config has extra columns (walkin_discount_percent, booking_discount_percent,
-- waive_fee_on_redemption) that are NOT in those 3 migrations. Find the migration that added
-- them — if missing from history, flag as schema drift.
```

Attach all 5 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **Loyalty punches go through atomic RPC**
   - Grep: `grep -rn "add_loyalty_punch\|\.from('customer_loyalty')" src/`
   - All punch increments should route through `add_loyalty_punch(phone)` RPC for atomicity.
   - Direct `UPDATE customer_loyalty SET current_punches = current_punches + 1` calls are a race-condition risk — flag.

2. **Reward redemption is atomic**
   - `redeem_loyalty_reward(phone)` RPC handles: check punches_required met, decrement punches, increment rewards_redeemed.
   - All redemptions go through this RPC.

3. **Gift card redemption creates a `gift_card_transactions` row**
   - Each redeem must INSERT a `gift_card_transactions` row AND decrement `gift_cards.current_balance`.
   - Must be atomic (RPC or transaction block).

4. **Referral events chain correctly**
   - click → visit → conversion
   - `record_referral_event(code, event_type, ...)` RPC is the single path.
   - Each event updates `barber_referrals` aggregate counters (total_clicks, total_visits, total_conversions, total_revenue).

5. **Upsell rules check `is_active`**
   - Any code that surfaces upsell suggestions (in booking flow, PaymentCollectionModal, etc.) must filter `upsell_rules.is_active = true`.

6. **Loyalty config is single-row**
   - `loyalty_config` table always has exactly 1 row (punches_required, reward_description).
   - Code reads config on-demand, not from a cached constant.

### Data-level invariants

Run `references/audit-queries.sql`. SELECT-only.

### Output template — MANDATORY Coverage Report

Every loyalty/referrals audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Loyalty & Referrals Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 7/7 PASS | X/7 FAIL (list missing)
- RLS policies found: X (expected ≥14) — list any gaps
- Triggers found: X/3 (expected: trigger_update_barber_referrals_updated_at, trigger_update_referral_metrics, tr_referral_conversion)
- RPCs found: X/6
- Migrations confirmed: X/3 (+1 drift-investigation for loyalty_config extra columns)

### Production config
- loyalty_config row count: [X] (expected: exactly 1)
- punches_required: [X] (expected: 10 — owner-changeable but flag surprises)
- reward_type: [X] (expected: discount_percent OR free_service)
- walkin_discount_percent / booking_discount_percent / waive_fee_on_redemption: [X] / [X] / [X]

### Findings
[Ranked critical/high/medium/low with file:line anchors and customer-impact]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (24 files from SURFACE_INVENTORY.md sections 1-7) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/loyalty/route.ts | PASS/FAIL/NOT-RUN | e.g. "loyalty/route.ts:62 — action=add_punch calls add_loyalty_punch RPC" |
| 2 | src/app/api/referrals/track/route.ts | | |
| 3 | src/app/api/analytics/referrals/route.ts | | |
| 4 | src/app/api/analytics/retention/route.ts | | |
| 5 | src/app/api/queue/route.ts (referral visit write) | | |
| 6 | src/app/api/bookings/route.ts (referral visit write) | | |
| 7 | src/app/api/queue/complete/route.ts (loyalty punch) | | |
| 8 | src/app/api/bookings/[id]/route.ts (loyalty punch) | | |
| 9 | src/app/api/client/profile/route.ts | | |
| 10 | src/app/api/clients/[id]/route.ts | | |
| 11 | src/lib/hooks/useLoyaltyAnalytics.ts | | |
| 12 | src/lib/hooks/useReferralAnalytics.ts | | |
| 13 | src/lib/hooks/useCustomerRetention.ts | | |
| 14 | src/components/dashboard/LoyaltyPunchCard.tsx | | |
| 15 | src/components/dashboard/GiftCardBalance.tsx | | |
| 16 | src/components/dashboard/UpsellSuggestionCard.tsx | | |
| 17 | src/components/referrals/ReferralTracker.tsx | | |
| 18 | src/components/dashboard/barber/ReferralCard.tsx | | |
| 19 | src/components/analytics/ReferralAnalytics.tsx | | |
| 20 | src/app/(public)/book/page.tsx | | |
| 21 | src/app/(public)/queue/page.tsx | | |
| 22 | src/app/(public)/profile/page.tsx | | |
| 23 | src/app/(dashboard)/dashboard/analytics/retention/page.tsx | | |
| 24 | src/app/layout.tsx (ReferralTracker mount) | | |

Files audited with proof-of-read: N / 24 (target: 24/24). Every PASS MUST have a file:line citation. Any PASS without evidence = treated as NOT-RUN.

### Pillar 2 — Database (7 domain tables + 2 touched parents from SURFACE_INVENTORY.md section 8)
| Table | Row count | Status dist / key stat | NULL / FK violations | Verdict |
|---|---|---|---|---|
| customer_loyalty | | avg/max punches | client_id NULLs | |
| loyalty_config | | is_active=true count (expected 1) | — | |
| gift_cards | | status dist | balance > original flag | |
| gift_card_transactions | | type dist | balance_after mismatch | |
| barber_referrals | | active count | aggregates vs events drift | |
| referral_events | | event_type dist | orphan barber_referral_id | |
| upsell_rules | | active count | base=suggested self-ref | |
| queue_entries (loyalty_reward_applied) | | true count | | |
| bookings (loyalty_reward_applied) | | true count | | |

Tables audited: N / 9

### Pillar 3 — Queries (all in references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | [name] | | |
| ... | [all] | | |

Queries run: N / total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (7 tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| customer_loyalty | | 2 | |
| loyalty_config | | 2 | |
| gift_cards | | 2 | |
| gift_card_transactions | | 2 | |
| barber_referrals | | 2 | |
| referral_events | | 3 (incl. public INSERT) | |
| upsell_rules | | 2 | |

RLS tables audited: N / 7

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 10-12, 15)
| Integration | Verdict | Note |
|---|---|---|
| RPC: add_loyalty_punch (atomic) | | |
| RPC: redeem_loyalty_reward (atomic) | | |
| RPC: record_referral_event (earnings calc) | | |
| Trigger fn: handle_referral_conversion (visit→conversion match) | | |
| Trigger fn: update_referral_metrics (aggregate sync) | | |
| Trigger fn: update_barber_referrals_updated_at | | |
| Trigger: tr_referral_conversion on service_transactions | | |
| Trigger: trigger_update_referral_metrics on referral_events | | |
| Trigger: trigger_update_barber_referrals_updated_at on barber_referrals | | |
| View: referral_funnel_summary | | |
| Twilio: referral-code template substitution (if present) | | |

Integrations audited: N / 11

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| /api/loyalty add_punch → {add_loyalty_punch RPC body, customer_loyalty.current_punches + last_punch_at, queue/complete + bookings/[id] callers} | YES/NO | |
| /api/loyalty redeem_reward → {redeem_loyalty_reward RPC, punches decrement, rewards_redeemed, loyalty_reward_applied column on parent, 3 discount config paths} | YES/NO | |
| /api/referrals/track → {record_referral_event RPC, referral_events INSERT, trigger_update_referral_metrics → barber_referrals aggregates, public INSERT RLS policy} | YES/NO | |
| queue check-in with ref → {referral_events visit insert via RPC, queue_entry_id link} | YES/NO | |
| booking create with ref → {referral_events visit insert via RPC, booking_id link} | YES/NO | |
| tr_referral_conversion on service_transactions → {handle_referral_conversion body, prior visit event exists, conversion row + earnings calc, barber_referrals aggregate increment} | YES/NO | |
| queue/complete loyalty punch → {mirror parity with bookings/[id] + upsert_client_from_service + loyalty_reward_applied flip} | YES/NO | |
| bookings/[id] loyalty punch → {mirror parity with queue/complete} | YES/NO | |
| Gift card redeem path → {gift_card_transactions INSERT + gift_cards.current_balance decrement + balance_after + status flip to depleted + RLS write permit} | YES/NO | |
| loyalty_config read → {single-row invariant, punches_required, reward_type, 3 extra discount columns, migration trail for extras} | YES/NO | |
| UpsellSuggestionCard → {is_active filter, base_service_id FK intact, suggested_addon_id FK intact, RLS read} | YES/NO | |
| ReferralTracker mount in src/app/layout.tsx → {?ref= URL read, sessionStorage, POST /api/referrals/track, anon accepted} | YES/NO | |
| barber_referrals aggregates → {trigger_update_referral_metrics + trigger_update_barber_referrals_updated_at + update_referral_metrics per-event-type logic} | YES/NO | |
| referral_funnel_summary view → {formulas accurate, view still exists, owner analytics reads it} | YES/NO | |
| customer_loyalty writes → {only via add_loyalty_punch or upsert_client_from_service — no direct UPDATE greps} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/components/dashboard/GiftCardBalance.tsx] | Gift card redeem UI — atomicity risk if write logic is inline | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Twilio template preview, Supabase advisors, etc.): <list>.

If zero gaps: write "No gaps identified. All 55 surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 55 (XX%)
- FAILs: N
- NOT-RUNs: N
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL LOYALTY & REFERRALS AUDIT — N surfaces unaudited, M coupling violations" instead of "Loyalty & Referrals Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. Ask for symptom:
   - "Customer says they've had 8 cuts but their punch card shows 5"
   - "Customer redeemed reward but punches weren't reset"
   - "Gift card balance shows $40 but customer says they've only used $20"
   - "Barber's referral code shows clicks but no conversions despite known bookings"
   - "Upsell suggestion popped up for the wrong service"
   - "Customer got free cut via reward but transaction also charged them"

2. Match against `references/incidents.md`.

3. Three-file rule. Two-strike rule. Stay in scope.

---

## Mode: scale-check

1. **Punch rate trend**
```sql
SELECT DATE_TRUNC('month', last_punch_at) AS month,
       COUNT(*) AS customers_with_punches,
       SUM(current_punches) AS total_punches,
       SUM(total_punches_earned) AS lifetime_punches
FROM customer_loyalty
WHERE last_punch_at > now() - interval '12 months'
GROUP BY month
ORDER BY month DESC;
```

2. **Gift card liability**
```sql
SELECT COUNT(*) AS active_cards,
       SUM(current_balance) AS outstanding_liability,
       SUM(initial_balance) - SUM(current_balance) AS total_redeemed
FROM gift_cards
WHERE status = 'active';
```
Active balance = liability on MT's books. At scale this is real money owed.

3. **Referral program effectiveness**
```sql
SELECT SUM(total_clicks) AS clicks,
       SUM(total_visits) AS visits,
       SUM(total_conversions) AS conversions,
       ROUND(100.0 * SUM(total_visits) / NULLIF(SUM(total_clicks), 0), 1) AS visit_pct,
       ROUND(100.0 * SUM(total_conversions) / NULLIF(SUM(total_visits), 0), 1) AS conv_pct
FROM barber_referrals
WHERE is_active = true;
```

4. **Loyalty config stability**
Changing `punches_required` mid-campaign is disruptive. If the owner wants to change it, flag that it affects customers who are already partway through a card.

5. **Per-barber referral scale**
   - Each barber gets a referral code. At 100 barbers, code collisions become theoretical (migration enforces UNIQUE).
   - Verify: the code is short enough to share but long enough for uniqueness at scale.

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

- NEVER write to production DB.
- NEVER test punch/redemption/gift-card flows against real customer phones.
- NEVER adjust `loyalty_config` mid-campaign without explicit approval (affects all customers).
- NEVER manually alter `gift_cards.current_balance` — always via `gift_card_transactions`.
- NEVER manually update `barber_referrals` counters — always via `record_referral_event` RPC.
- ALWAYS use `mcp__supabase-mt__`.
- Branch workflow. Stay in scope.
