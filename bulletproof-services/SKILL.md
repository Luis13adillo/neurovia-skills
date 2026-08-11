---
name: bulletproof-services
description: Audit, diagnose, or scale-check the MT Barbershop three-way services system — walk-in services (global `services` table, owner-controlled), barber booking services (`barber_services` + `barber_custom_services`), and the owner's personal barber services (MT is both owner AND a barber). Covers duration propagation, FK cascade rules, availability API, calendar display, RLS enforcement, and cross-surface consistency (queue, booking, profile, /services, /team, In-Service Mode, reports, upsell rules, SMS/email templates). Use when service changes don't propagate, durations look wrong on the calendar, walk-in vs booking service boundaries blur, or before adding a new location / bulk service change. Read-only SQL via mcp__supabase-mt__execute_sql and codebase greps only. Never writes to the production DB. Never modifies application code without explicit user approval.
---

# Bulletproof Services

The services system is the backbone of every transaction — a customer sees a service on the menu, picks one at the walk-in queue, books one from a barber profile, a barber starts a service, a service triggers a payment, and then it aggregates into daily reports, loyalty punches, and commission ledgers. If service data blurs between the three separation tiers, every downstream surface drifts.

Three independent systems MUST stay isolated:

| Tier | Table | Scope | Managed at |
|---|---|---|---|
| **Walk-in (global)** | `services` | Owner-controlled, uniform across all barbers/locations | `/dashboard/services` |
| **Barber booking** | `barber_services` + `barber_custom_services` | Per-barber, shown on profile + booking flow | `/barber/settings?tab=services`, `/dashboard/my-chair/services` |
| **Owner personal** | Same as "Barber booking" (scoped to owner's `barber_id`) | MT's own bookings — SEPARATE from walk-in prices his location charges | `/dashboard/my-chair/services` |

This skill does NOT replace `CLAUDE.md`, `MEMORY.md`, or the `.claude/rules/*.md` files. It READS them, then runs a structured protocol.

---

## Mandatory Preflight — BEFORE any action

Read in order:
1. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/CLAUDE.md` — "System B: Booking Flow (6 Steps)", "System C" HARD RULE "Walk-In vs Booking Services", "Database Schema" (services + barber_services + barber_custom_services), "Existing Systems Are Sacred" rule.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-MT-Barbershop-Systems/memory/MEMORY.md` — "Service System — HARD RULE", "Unified Service Customization (2026-03-12)", Booksy Timezone Rule (for duration/time edge cases).
3. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/debugging-protocol.md` — Sections 4, 5, 7, 8, 9.
4. `/Users/luismiguel/Desktop/MT-Barbershop-Systems/.claude/rules/context-awareness.md` — Cross-Dashboard Code Mirroring Rule (services UI is mirrored between owner and barber).

After reading, confirm "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** → read-only health check across code + data
- **diagnose** → specific symptom to investigate
- **scale-check** → before adding a new location, rolling out new services, or bulk service changes
- **fix** — apply canonical patterns from `references/fix-patterns.md`. EXPLICIT activation only; audit findings do NOT auto-trigger this mode.

---

## AUDIT RIGOR — read before starting audit mode

This skill enforces the universal Audit Rigor Standard at `~/.claude/skills/_shared/audit-rigor.md` and the domain Surface Inventory at `references/SURFACE_INVENTORY.md`. Read both before you do anything.

**Five Pillars (all mandatory):** codebase, database, queries, RLS, integrations. Missing any pillar = failed audit.

**Proof-of-Read:** every file claimed PASS in the Coverage Report MUST cite a `file.ts:LINE` from that file. No line = NOT-RUN, not PASS. This is enforced by the universal standard.

**Forcing language — copy this into your mental model:**

> Do NOT stop on first pass. You MUST work through EVERY file in SURFACE_INVENTORY.md (55+ surfaces), EVERY query in audit-queries.sql, EVERY RLS policy, EVERY trigger, and EVERY integration. Stopping after one finding is a half-audit and is explicitly forbidden.
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
| DELETE global service (`/dashboard/services`) | `barber_services.service_id` FK CASCADE (junction rows correctly removed) + `bookings.service_id` FK SET NULL (history preserved) + `queue_entries.service_id` FK SET NULL + `service_transactions.service_id` FK SET NULL + `upsell_rules` dangling rows (trigger + suggested) + availability API recompute (no slots for deleted service's duration) + frozen `duration_minutes` / `service_amount` on historic rows still intact | Deleting a service touches 6 downstream surfaces. Regressing SET NULL → CASCADE (pre-fb35208) deletes history — CRITICAL. |
| Edit global service price/duration | `bookings.duration_minutes` / `service_amount` NOT retroactively mutated (frozen at creation is intentional) + `queue_entries` frozen + `service_transactions.service_name` frozen + walk-in queue check-in SWR revalidate + public services page `/services` cache: no-store + public profile reads latest + availability API uses new duration for NEW slots only | Price/duration edit propagates forward to NEW bookings only. Any script that retroactively edits frozen columns = CRITICAL drift. |
| INSERT/UPDATE on `barber_services` | Lockdown triggers `barber_services_block_insert` + `barber_services_block_update` still ENABLED + `/api/barber/services` POST returns 410 + "Shop Services" toggle UI absent from /barber/settings + absent from /dashboard/my-chair/services | MEMORY.md 2026-04-22 deprecation. If the lockdown is disabled, barbers can silently write again. |
| `/api/barber/custom-services` POST/PATCH/DELETE | `barber_custom_services.is_active` + `(supabase as any)` cast (table not in generated types) + public profile displays custom + booking wizard picks up via unified `/api/barber/services` GET + duration/price propagation to `bookings.custom_service_id` | Custom services are barber-owned; if the cast is removed from server components, compilation breaks silently. |
| `/api/barber/services` GET (unified) | Merges `barber_services` (global + `custom_price`) AND `barber_custom_services` + `source` field on response + booking wizard uses it + public profile uses it + owner my-chair uses it | Unified API feeds 3 consumers. Shape change breaks all three. |
| `/api/bookings/route.ts` POST | Routes to `service_id` OR `custom_service_id` based on lookup (never both, never neither) + frozen `duration_minutes` set from source + frozen `service_amount` set + availability recheck after service resolution | Booking must cleanly resolve to ONE service source. Dual-write = orphan on one side. |
| `/api/queue/route.ts` check-in | Reads ONLY global `services` table (`is_active = true`) + NOT `barber_services` / `barber_custom_services` (that boundary is a HARD RULE) + frozen `duration_minutes` + frozen `service_amount` | Walk-in boundary violation = barbers' custom prices bleed into the queue. |
| `/api/queue/entry/[id]/service/route.ts` (change service mid-queue) | `duration_minutes` recompute on change + `service_amount` recompute + overlap check vs other queue entries + In-Service timer reset if in_chair | Mid-entry service change rewrites frozen values. Needs careful audit. |
| `/api/bookings/availability/route.ts` | Reads service duration from query param (not live re-fetch) + includes `in_chair` queue entries as busy + includes `confirmed`+`pending`+`in_progress` bookings + uses Eastern TZ per Booksy rule + `bookings_no_time_overlap` constraint as safety net | Availability's slot size comes from the SERVICE — wrong duration read = overlapping slots. |
| Any writer to `services` (dashboard/services/page) | Owner RLS `is_owner()` enforced on INSERT/UPDATE/DELETE + SWR revalidate on mutation + walk-in queue SWR revalidate + public services page cache: no-store | Only the owner can write. Barber app paths must be blocked at API + RLS. |
| Cross-dashboard services UI mirror | `/dashboard/my-chair/services` matches `/barber/settings?tab=services` — same features, same validation, same category accordions — per Cross-Dashboard Mirroring Rule | Drift between owner/barber service editing = Rule violation. |
| `upsell_rules` runtime lookup in `/api/queue/complete` | `trigger_service_id` references existing `services.id` + `suggested_service_id` references existing + both are `is_active = true` + audit query 13 finds zero dangling references | Dangling upsell rule = silent no-op at completion. |
| SMS/email templates reading service name | Uses stored `service_name` from `service_transactions` OR booking row snapshot (NOT live `services` JOIN) | Live JOIN + deleted service = "undefined" in SMS. |
| Stripe checkout / payment link | Reads frozen `booking.service_amount` / `booking.total_amount` (NOT live service.price re-fetch that could change mid-flow) | Amount drift = refund disputes. |

**A PASS on the left side without evidence of auditing the right side = COUPLING VIOLATION.** Report it in the Gap Self-Report.

---

## Mode: audit

### Step 0 — Universal Audit Preamble (MANDATORY — run first, always)

Run the 5 discovery queries from `~/.claude/skills/_shared/audit-rigor.md` section "Universal Audit Preamble", filled in with the services domain values:

```sql
-- 1. Enumerate services domain tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('services','barber_services','barber_custom_services','upsell_rules')
ORDER BY table_name;
-- Expected: 4 rows. Missing = inventory drift; STOP and ask user.

-- 2. RLS policies on every services table
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('services','barber_services','barber_custom_services')
ORDER BY tablename, policyname;
-- Expected: at least 3 policies per table (public SELECT + owner + barber).

-- 3. Triggers on services-touched tables (lockdown triggers must exist)
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('services','barber_services','barber_custom_services')
ORDER BY event_object_table, trigger_name;
-- Expected: barber_services_block_insert + barber_services_block_update (2026-04-22 deprecation).

-- 4. FK cascade behavior on services consumers
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid IN (
    'public.bookings'::regclass,
    'public.queue_entries'::regclass,
    'public.service_transactions'::regclass
  )
  AND contype = 'f'
  AND conname LIKE '%service%';
-- Expected: ON DELETE SET NULL on all (post fb35208, 2026-04-21).
-- CASCADE on any of these = CRITICAL regression.

-- 5. Migration history
SELECT name, executed_at FROM supabase_migrations.schema_migrations
WHERE name ILIKE '%services%' OR name ILIKE '%custom_services%'
   OR name ILIKE '%barber_services%' OR name ILIKE '%deprecate%'
ORDER BY executed_at;
-- Expected: at least 3 rows (see SURFACE_INVENTORY.md section 9).

-- 6. Upsell rules reference only existing services
SELECT COUNT(*) AS dangling_upsells
FROM upsell_rules ur
WHERE ur.is_active = true
  AND (NOT EXISTS (SELECT 1 FROM services s WHERE s.id = ur.trigger_service_id AND s.is_active)
    OR NOT EXISTS (SELECT 1 FROM services s WHERE s.id = ur.suggested_service_id AND s.is_active));
-- Expected: 0.
```

Attach all 6 result sets to the report under "Universal Preamble". Any drift = stop before domain checks.

### Code-level invariants

1. **Walk-in check-in reads ONLY global `services`**
   - File: `src/app/(public)/queue/page.tsx` → uses `useServices(true)` from `src/lib/hooks/useServices.ts`.
   - Must filter `is_active = true`. Must NOT import or call any `barber_services` / `barber_custom_services` endpoint in the check-in path.

2. **Booking wizard reads barber-scoped services**
   - File: `src/app/(public)/book/page.tsx` → calls `/api/barber/services?barber_id=...`.
   - API: `src/app/api/barber/services/route.ts` GET merges `barber_services` (global + `custom_price` override) AND `barber_custom_services`.
   - Booking POST (`src/app/api/bookings/route.ts`) must route to `service_id` OR `custom_service_id` based on lookup — never both, never neither (except when the service was deleted and SET NULL fired).

3. **Public barber profile merges both sources**
   - File: `src/app/(public)/mtbarbers/[slug]/page.tsx`
   - Must show `barber_services` (joined to `services`, applying `custom_price`) + `barber_custom_services` (filtered `is_active=true`).

4. **Three separate service management UIs write to three different scopes**
   - `/dashboard/services` → `src/lib/hooks/useServices.ts` writes to `services` ONLY (owner RLS enforced by `is_owner()`).
   - `/barber/settings?tab=services` → `/api/barber/services` POST derives `barber_id` from authenticated user; writes to `barber_services` ONLY. Custom services go through `/api/barber/custom-services`.
   - `/dashboard/my-chair/services` → SAME API endpoints scoped to owner's `barber_id` (owner acts as a barber here).
   - Cross-dashboard mirror must match (per `context-awareness.md`).

5. **Duration is frozen at booking/queue-entry creation** (intentional, not a bug)
   - `bookings.duration_minutes` stored at POST from the source service's `duration_minutes`.
   - `queue_entries` stored at check-in time.
   - Editing a service's duration later must NOT retroactively mutate existing rows. If a script is found that does, flag as CRITICAL.

6. **Availability API respects duration + prevents overlap**
   - File: `src/app/api/bookings/availability/route.ts`
   - Reads requested service duration from query param, uses that for slot size.
   - Includes `confirmed` + `pending` + `in_progress` bookings in busy list.
   - Includes `in_chair` queue entries in busy list.
   - DB-level safety net: exclusion constraint `bookings_no_time_overlap` (btree_gist).
   - Must use `timeZone: 'America/New_York'` per Booksy TZ rule.

7. **FK delete rules are uniform SET NULL** (post commit `fb35208`, 2026-04-21)
   - `bookings.service_id`, `bookings.custom_service_id`, `queue_entries.service_id`, `service_transactions.service_id` → all SET NULL.
   - Only `barber_services.service_id` → CASCADE (correct: junction row goes away if service is deleted).
   - Any drift back to CASCADE on the first four is CRITICAL.

8. **In-Service Mode uses stored duration, not live service lookup**
   - File: `src/components/dashboard/InServiceMode.tsx` (shared between owner and barber dashboards).
   - Timer math uses the queue entry's / booking's stored `duration_minutes`.

9. **Cross-dashboard services UI mirror intact**
   - Owner: `src/app/(dashboard)/dashboard/my-chair/services/page.tsx`
   - Barber: `src/app/(dashboard)/barber/settings/page.tsx` Services tab
   - Features, validation, and category accordions must match.

### Data-level invariants

Run queries in `references/audit-queries.sql` via `mcp__supabase-mt__execute_sql`. All SELECT-only. Expected result is 0 rows unless noted.

### Output template — MANDATORY Coverage Report

Every services audit MUST produce this full block. A report without the Coverage Report section is INCOMPLETE and will be rejected.

```markdown
## Services Audit Report — [YYYY-MM-DD]

### Universal Preamble
- Tables enumerated: 4/4 PASS | X/4 FAIL
- RLS policies found: X — list any gaps
- Lockdown triggers on barber_services present: PASS/FAIL
- FK cascades SET NULL on bookings/queue_entries/service_transactions: PASS/FAIL
- Migrations confirmed: X/4
- Dangling upsell_rules rows: N

### Code-level findings
[PASS/FAIL per invariant with file:line anchors]

### Data-level findings
[PASS/FAIL per query with row counts]

---

## Coverage Report (MANDATORY)

### Pillar 1 — Codebase (24 files from SURFACE_INVENTORY.md sections 1-5) — PROOF-OF-READ REQUIRED
| # | File | Verdict | Evidence (file:line — what was checked) |
|---|---|---|---|
| 1 | src/app/api/barber/services/route.ts | PASS/FAIL/NOT-RUN | e.g. "route.ts:28 — POST returns 410 Gone" |
| 2 | src/app/api/barber/custom-services/route.ts | | |
| ... | [all 24] | | |

Files audited with proof-of-read: N / 24 (target: 24/24). Any PASS without a file:line citation = treated as NOT-RUN.

### Pillar 2 — Database (3 services tables + 4 consumer tables, from SURFACE_INVENTORY.md section 6)
| Table | Row count | Is-active dist | NULL violations | Verdict |
|---|---|---|---|---|
| services | | active:X, inactive:X | | |
| barber_services | | | (should be frozen since 2026-04-22) | |
| barber_custom_services | | | | |
| bookings (service_id/custom_service_id nulls) | | | orphan count | |
| queue_entries (service_id nulls) | | | orphan count | |
| service_transactions (service_id nulls) | | | orphan count | |
| upsell_rules | | | dangling count | |

Tables audited: N / 7

### Pillar 3 — Queries (from references/audit-queries.sql)
| # | Query | Verdict | Rows |
|---|---|---|---|
| 1 | no_orphan_bookings_service_id | | |
| ... | [all queries] | | |

Queries run: N / N_total. Skipped: [empty — or list with reason].

### Pillar 4 — RLS (3 service tables)
| Table | Policies found | Expected | Verdict |
|---|---|---|---|
| services | | ≥3 (public select, owner all, barber select) | |
| barber_services | | ≥3 | |
| barber_custom_services | | ≥3 (public select active, owner all, barber all own) | |

RLS tables audited: N / 3

### Pillar 5 — Integrations (SURFACE_INVENTORY.md sections 7, 10, 11)
| Integration | Verdict | Note |
|---|---|---|
| Lockdown trigger: barber_services_block_insert | | |
| Lockdown trigger: barber_services_block_update | | |
| FK SET NULL: bookings.service_id | | |
| FK SET NULL: bookings.custom_service_id | | |
| FK SET NULL: queue_entries.service_id | | |
| FK SET NULL: service_transactions.service_id | | |
| Duration freeze: bookings.duration_minutes at POST | | |
| Duration freeze: queue_entries.duration_minutes at check-in | | |
| service_name copy at service_transactions insert | | |
| SMS templates use stored name (not live) | | |
| Email templates use stored name | | |
| Stripe checkout uses stored service_amount | | |

Integrations audited: N / 12

### Coupling Checks (from Cross-Surface Coupling Rules table)
| Coupling | Both sides audited? | Note |
|---|---|---|
| DELETE service → {barber_services CASCADE, bookings/queue/ST SET NULL, upsell_rules dangling, availability, frozen columns intact} | YES/NO | |
| Edit service price/duration → {frozen rows NOT mutated, consumer SWR revalidate, availability uses new only for new slots} | YES/NO | |
| INSERT/UPDATE on barber_services → {lockdown triggers active, POST returns 410, toggle UI absent} | YES/NO | |
| Custom services CRUD → {is_active, (supabase as any) cast, profile display, wizard pickup, duration/price to bookings} | YES/NO | |
| `/api/barber/services` GET → {merge barber_services + custom, source field, 3 consumers all work} | YES/NO | |
| `/api/bookings/route.ts` POST → {route to service_id OR custom_service_id exclusively, frozen duration/amount, availability recheck} | YES/NO | |
| `/api/queue/route.ts` check-in → {ONLY global services, NOT barber_services/custom, frozen duration/amount} | YES/NO | |
| Change service mid-queue → {duration/amount recompute, overlap check, timer reset} | YES/NO | |
| Availability API → {duration from query, in_chair busy, confirmed+pending+in_progress busy, Eastern TZ, overlap constraint} | YES/NO | |
| Services writers → {is_owner() RLS, SWR revalidate, public cache no-store} | YES/NO | |
| Cross-dashboard services UI mirror (owner/my-chair vs barber/settings) | YES/NO | |
| upsell_rules runtime lookup → {both FKs exist + is_active} | YES/NO | |
| SMS/email templates → {use stored service_name, not live JOIN} | YES/NO | |
| Stripe checkout/link → {stored service_amount, no live re-fetch} | YES/NO | |

Coupling violations: N  **(must be 0 — any NO row is a violation)**

---

## Gap Self-Report (MANDATORY)

| # | Gap | Why it matters | Severity |
|---|---|---|---|
| G1 | [e.g. Did not open src/app/api/queue/entry/[id]/service/route.ts] | Mid-entry service change rewrites frozen columns | Unknown |

Surfaces in SURFACE_INVENTORY.md NOT audited this run: <comma-separated item numbers>.
Questions requiring external verification (Stripe product catalog, SMS template console, etc.): <list>.

If zero gaps: write "No gaps identified. All 55+ surfaces audited with proof-of-read + all coupling checks passed."

---

## Totals

- Surfaces audited with proof-of-read: X / 55+ (XX%)
- FAILs: N
- NOT-RUNs: N  (if > 0, the audit is PARTIAL, not COMPLETE — state this in the header)
- Coupling violations: N (must be 0)

**If NOT-RUNs > 0 OR coupling violations > 0, the report header MUST say "PARTIAL SERVICES AUDIT — N surfaces unaudited, M coupling violations" instead of "Services Audit Report".**
```

Stop only after every row above is filled. "Stop on first fail" is NOT the protocol — complete the full coverage sweep, then report.

---

## Mode: diagnose

1. **Ask for symptom.** Examples:
   - "Owner edited Men's Haircut price but walk-in queue still shows old price"
   - "Customer booked a 60-minute service but calendar shows 30-minute block"
   - "Barber added a custom service but it's not on his public profile"
   - "Deleted a walk-in service and some future bookings disappeared" (pre-2026-04-21 CASCADE regression)
   - "Availability API is returning slots that overlap existing bookings"
   - "Owner's Men's Regular Haircut shows $40 to a booking customer instead of $80"
   - "In-Service timer shows wrong countdown"

2. **Match against `references/incidents.md`.**
   - "Deleted walk-in service → future bookings vanished" → CASCADE regression — verify FK delete rule is SET NULL.
   - "Price / duration edit didn't reflect on existing booking" → expected behavior (frozen at creation). Not a bug unless user expected retroactive.
   - "Custom service missing from profile" → check `is_active=true` AND RLS SELECT policy hit.
   - "Walk-in service leaked into booking flow" → check the component is hitting the correct API endpoint.
   - "Service save returned silent success but empty row set" → delete-then-insert race in `/api/barber/services` POST.
   - "Availability slot overlap" → verify `in_progress` status is included in busy list + TZ is Eastern.

3. **Three-file rule.** Read max 3 files. If no match after 3, STOP and ask for direction.

4. **Two-strike rule.** Second fix must differ in approach from the first.

5. **Stay in scope.** Do not wander into queue, commission, or auth code unless the data chain clearly passes through them.

6. **User reports override queries.** If user says "the queue shows price X" and SQL shows Y, investigate the ACTUAL code path the UI uses — don't argue.

---

## Mode: scale-check

Produce a "must-fix-before-[trigger]" checklist. Triggers:
- Adding a new location
- Launching a bulk service price change or new service menu
- Onboarding a cohort of new barbers who will set custom services

1. **Inactive-services cruft**
   - Query: count `services` where `is_active=false`. If > 10, flag for pruning — these clutter the `/dashboard/services` admin view but don't break anything.
   - Filter out any `services.name` containing `sample`, `test`, `demo`.

2. **Category enum drift**
   - Run query 14 in `audit-queries.sql`.
   - Documented enum: `haircuts`, `beard`, `combos`, `grooming`, `linework`, `specialty`, `color`, `treatments`, `addons`, `hair` (legacy alias of haircuts), `combo` (legacy alias). Anything outside this list means a barber has typed a category that no UI filter handles.

3. **Duration range sanity**
   - Flag any active service with `duration_minutes < 10` OR `> 180`. Short durations cause sub-slot bookings that confuse the calendar; long durations hold a chair hostage.

4. **Uniform walk-in pricing**
   - When adding location #5, confirm walk-in prices still match MT's intent (some chains charge different prices at different locations — MT does NOT per CLAUDE.md HARD RULE).

5. **Custom service duplication**
   - Run query 15. If N barbers all created identical "Kids Haircut" custom services at different prices, consider consolidating into a global service to simplify reports.

6. **Upsell rule reachability**
   - Run query 13. If upsell rules reference services that are now `is_active=false`, they silently never trigger.

7. **SMS/email template service-name coupling**
   - `grep -rn "service_name\|{service}" src/lib/email/ src/lib/twilio/` — verify templates read the service name fresh from the booking row, not hardcoded.

8. **Daily summaries aggregation drift**
   - `daily_summaries` does not FK to services, so it can't break. But cross-check: total cuts = queue_entries completed + bookings completed, and sum(service_amount) should match daily_summaries.total_revenue for the day.

9. **Stripe payment links**
   - Grep `src/app/api/stripe/` and `src/app/api/payment-link/` for `service.price` vs `booking.service_amount` / `booking.total_amount`. Must use the stored booking amount, never a live re-fetch that could change mid-flow.

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

## Downstream Consumers & Propagation

When a service is added / edited / removed, the change MUST propagate correctly everywhere — and NOT propagate where freezing is intentional.

### Consumers (every surface that reads service data)

| Consumer | File / URL | What it reads | Propagation behavior |
|---|---|---|---|
| Walk-in check-in | `src/app/(public)/queue/page.tsx` + `useServices(true)` | `services` where `is_active=true` | Immediate via SWR revalidate |
| Booking wizard | `src/app/(public)/book/page.tsx` + `/api/barber/services` | `barber_services` + `barber_custom_services` | On wizard open |
| Public barber profile | `src/app/(public)/mtbarbers/[slug]/page.tsx` | both sources, server component | Page-load (Next.js cache: no-store required) |
| Public services page | `src/app/(public)/services/page.tsx` | `services` where `is_active=true` | Page-load |
| Team page | `src/app/(public)/team/page.tsx` | barber list, not services directly | N/A |
| Owner admin | `/dashboard/services` | `services` (all, via `useServices(false)`) | SWR revalidate on mutation |
| Barber admin | `/barber/settings?tab=services` | `/api/barber/services` + `/api/barber/custom-services` | SWR revalidate |
| Owner my-chair admin | `/dashboard/my-chair/services` | Same as barber admin, scoped to owner | SWR revalidate |
| Queue entry row | `queue_entries.service_id` + `queue_entries.duration_minutes` | FK + frozen duration | **Frozen at check-in** — later service edits do NOT propagate |
| Booking row | `bookings.service_id` / `custom_service_id` + `duration_minutes` + `service_amount` | FK + frozen snapshot | **Frozen at creation** — later service edits do NOT propagate |
| Calendar | `src/lib/hooks/useCalendarEvents.ts` + `src/components/dashboard/calendar/*` | `bookings.duration_minutes` for block size | Uses stored, not live |
| In-Service Mode | `src/components/dashboard/InServiceMode.tsx` | Stored duration | Uses stored, not live |
| Post-Service Flow | `src/components/dashboard/PostServiceFlow.tsx` | `service_amount` stored on entry | Uses stored, not live |
| Daily summaries | `daily_summaries` table | Aggregated via trigger | Per day aggregate — no service FK |
| Service transactions | `service_transactions` table | `service_id` (SET NULL) + `service_name` copy | Name copied at write; FK is for reference only |
| Upsell rules | `upsell_rules` + `/api/queue/complete` handler | `trigger_service_id` / `suggested_service_id` | Runtime lookup |
| SMS/email templates | `src/lib/twilio/*`, `src/lib/email/*` | `service_name` from booking row | Uses stored name |
| Stripe checkout | `src/app/api/stripe/*` / `src/app/api/payment-link/*` | `booking.service_amount` / `booking.total_amount` | Uses stored amount |

### Propagation invariants

1. **Frozen-at-creation is a feature.** `duration_minutes`, `service_amount`, and the effective service name are stored on the queue/booking row at write time. Editing a service later does NOT mutate in-flight work. Document this clearly to users; don't "fix" it unless explicitly asked.

2. **SET NULL keeps history intact.** When a service is hard-deleted, bookings/queue-entries/service-transactions lose the FK but keep their copy of `duration_minutes`, `service_amount`, and (for `service_transactions`) `service_name`. The row stays valid. This is the post-2026-04-21 safety net.

3. **Next.js Data Cache.** Any server component that reads services (public profile, booking wizard, `/services` page) MUST go through a Supabase client that wraps fetch with `cache: 'no-store'` (see MEMORY.md "Common Pitfalls"). Otherwise stale services leak on Vercel.

4. **SWR revalidate on admin mutation.** Every service CRUD must call `refetch()` / `mutate()` so the admin UI shows the new state without a full reload.

5. **Realtime NOT required on service tables.** Changes are admin-initiated and slow-moving; public consumers can tolerate page-load latency. If this changes (e.g., real-time service toggles on the TV board), add `services` + `barber_custom_services` to the Supabase realtime publication explicitly.

### Diagnose: "Owner changed Men's Haircut price in admin, walk-in queue still shows old price"

1. DB write happened? `SELECT price, updated_at FROM services WHERE name='Men''s Haircut'` — check `updated_at`.
2. `useServices(true)` SWR cache stale? Revalidate by hard refresh.
3. Supabase factory wraps fetch with `cache: 'no-store'`? Read the client factory.
4. If all green but UI stale → Next.js Data Cache defeating the read on a server component. Verify `export const dynamic = 'force-dynamic'` on the consuming route.
5. If user is complaining about an EXISTING booking showing old price → expected behavior (frozen at creation), not a bug.

---

## HARD RULES

- NEVER write to production DB. READ-ONLY via `mcp__supabase-mt__execute_sql`.
- NEVER modify a working system without explicit user approval. Three-way service separation is a LOCKED system — do not "unify" it.
- NEVER expand scope. Service bug = service fix. No "while I'm here" queue/booking/payment touch-ups.
- ALWAYS use `mcp__supabase-mt__`, never `mcp__supabase__`.
- NEVER test on real barbers (use test accounts only: Dev Owner, Luis Barber, Test Barber 3/4).
- Duration is FROZEN at creation by design. Do not "fix" this to be retroactive.
- If a fix breaks walk-in, booking, profile, calendar, or payment — FULL REVERT.
- Branch workflow: any code change on a `fix/…` / `feature/…` branch, not `main`.
- User reports override queries — if user says "I see X", trace the UI code path, don't argue with SQL.
