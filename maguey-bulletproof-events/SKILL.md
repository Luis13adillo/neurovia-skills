---
name: maguey-bulletproof-events
description: Audit, diagnose, or scale-check the Maguey Nightclub event lifecycle (EventManagement.tsx CRUD, draft/published/archived statuses, VIP auto-setup on event create, ticket_types seeding, image upload to event-images bucket, duplicate event detection, cancellation via cancel-event-with-refunds Edge Function, event reminders cron, age restrictions, AI event description generator, flyer scanning). Complement to maguey-bulletproof-sync (which covers propagation across 3 apps). Use when event creation fails, duplicate events appear, cancellation leaves orphan data, VIP tables don't auto-generate, or before launching a new event series. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB.
---

# Maguey Bulletproof Events

Events are the center of gravity. A botched event creation = confused customers + staff scrambling. A broken cancellation = angry refund requests + legal exposure. Lifecycle bugs surface everywhere downstream: sync, tickets, VIP, scanner, email.

This skill covers:
- `maguey-gate-scanner/src/pages/EventManagement.tsx` (CRUD UI)
- `maguey-gate-scanner/src/lib/event-image-service.ts` (upload to `event-images` bucket)
- `maguey-gate-scanner/supabase/functions/scan-flyer/` (flyer OCR → autofill event fields)
- `maguey-gate-scanner/supabase/functions/generate-event-description/` (AI description)
- `maguey-gate-scanner/supabase/functions/send-event-announcement/`
- `maguey-pass-lounge/supabase/functions/send-event-reminders/` (24h + 2h reminder cron)
- `maguey-pass-lounge/supabase/functions/cancel-event-with-refunds/` (bulk refund)
- Tables: `events`, `ticket_types`, `event_vip_tables`, `event_vip_configs`, `vip_table_templates`, `event_reminder_log`
- Status lifecycle: `draft` → `published` → `archived`; `cancellation_status` = `active` | `cancelled`

**Not covered here:**
- Cross-site event propagation → `maguey-bulletproof-sync`
- GA ticket purchase against the event → `maguey-bulletproof-tickets`
- VIP reservations against the event → `maguey-bulletproof-vip`
- Email delivery of reminders/announcements → `maguey-bulletproof-email`

---

## Schema Reality Check (verified 2026-04-21 against live DB)

**`events` real columns:** `id, name, description, image_url, genre, venue_name, venue_address, city, event_date (date), event_time (time), created_at, updated_at, artist_name, artist_description, event_category, metadata (jsonb), banner_url, is_active (boolean NOT NULL), status (text nullable), published_at, categories (array), tags (array), vip_enabled (boolean), vip_configured_at, vip_configured_by, newsletter_sent_at, newsletter_sent_count, cancellation_status (varchar), cancelled_at, cancelled_by (varchar), cancellation_reason, flyer_url, age_restriction (varchar)`.

- `events.status` is **free-form text** (no CHECK constraint). Values seen in practice: 'draft', 'published', 'archived' — but nothing at the DB level enforces this. Keep code-level discipline.
- `events.is_active` is a separate boolean flag (NOT NULL). Soft-disable an event via `is_active=false`. Status and is_active together form the visibility logic.
- `events.cancellation_status` is varchar, no CHECK constraint; values observed: 'active', 'cancelled'.

**`ticket_types` real columns:** `id, event_id, code, name, price (numeric dollars NOT price_cents), fee (numeric), limit_per_order, total_inventory (NOT capacity), description, created_at, updated_at, tickets_sold`.

- **There is NO `is_active` column on ticket_types.** Availability derives from `total_inventory > 0` + `tickets_sold < total_inventory`.
- **Prices are dollars** (`numeric`), not cents. VIP uses `price_cents`; GA uses `price`. Do not conflate.

**`event_vip_tables` real columns (confirmed):** `id, event_id, table_template_id, table_number, tier, capacity, price_cents (cents), bottles_included, champagne_included, package_description, is_available, display_order, created_at, updated_at, position_x, position_y`.

**`event_vip_configs` real columns:** `id, event_id, vip_enabled, refund_policy_text, disclaimer_text, created_at, updated_at`. That's it — much simpler than older skill drafts claimed. No per-event template references, no minimum_spend, etc.

**`vip_table_templates` real columns:** `id, table_number, default_tier, default_capacity, position_x, position_y, position_row, created_at, updated_at`. **NO `default_price_cents`, NO `default_bottles_included`, NO `default_package_description`**. Templates are layout-only — pricing + packages are set per-event in `event_vip_tables`.

**`event_reminder_log` real columns:** `id, ticket_id, event_id, reminder_type, sent_at, status`. Idempotent by UNIQUE(ticket_id, reminder_type).

**Tables that DO exist and are used:** `events, ticket_types, event_vip_tables, event_vip_configs, vip_table_templates, event_reminder_log, newsletter_subscribers, venues, venue_branding`.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — "Event Creation" What Works entry.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — 34 tables inventory, 103+ migrations.
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

Confirm "Preflight complete. Running [mode]." Supabase: `mcp__supabase__execute_sql` project `djbzjasdrwvbsoifxqzd`.

---

## Choose a Mode

- **audit** → weekly + before launching a new event series or season
- **diagnose** → event lifecycle symptom reported (create fails, cancel incomplete, VIP tables missing)
- **scale-check** → seasonal ramp-up (Halloween, NYE, Valentine's) or announcing a full quarter of events

---

## Mode: audit

### Code-level invariants

1. **Status transitions valid**
   - `events.status` CHECK constraint: `IN ('draft', 'published', 'archived')` OR NULL
   - Verify: migration `20250303000000_add_event_status.sql` CHECK intact
   - No code path writes a value outside this set

2. **`cancellation_status` separate from `status`**
   - `active` | `cancelled`; affects refund flow, not visibility toggle
   - A `published` event can be `cancelled` — shows as cancelled but remains in history
   - Grep: `grep -rn "cancellation_status" src/ supabase/`

3. **Event creation seeds ticket types**
   - `EventManagement.tsx` on save — creates `ticket_types` rows per tier defined in UI
   - Without `ticket_types`, event is not purchasable (even if published)
   - Audit query #1 catches bare events

4. **VIP auto-setup on create**
   - If `vip_enabled = true` on event, then `event_vip_tables` should be seeded from `vip_table_templates`
   - Or default set of tables created
   - Grep: `grep -n "vip_enabled\|event_vip_tables.*insert\|seed_vip_tables" src/pages/EventManagement.tsx supabase/migrations/`

5. **Image upload validates file size**
   - `event-image-service.ts` lines ~19-87: max 5MB, accepted formats (jpg, png, webp)
   - Grep: `grep -n "5 \* 1024\|MAX_FILE_SIZE\|file.size" src/lib/event-image-service.ts`

6. **Duplicate event detection**
   - UI should warn or block when creating event with same name + same date
   - Grep: `grep -n "duplicate\|already exists\|name.*event_date" src/pages/EventManagement.tsx`

7. **Event delete protection**
   - Events with sold tickets cannot be deleted (must be cancelled with refunds)
   - Verify: FK from `tickets.event_id` is ON DELETE RESTRICT or similar
   - Or UI check before allowing delete

8. **Reminder cron idempotent**
   - `send-event-reminders/index.ts` uses `event_reminder_log` UNIQUE(ticket_id, reminder_type) to prevent dup sends
   - Grep: `grep -n "event_reminder_log\|INSERT.*event_reminder_log" supabase/functions/send-event-reminders/index.ts`

9. **Cancellation is atomic + traceable**
   - `cancel-event-with-refunds/index.ts` processes orders one at a time with idempotency keys
   - Updates `events.cancellation_status = 'cancelled'`, `cancelled_at`, `cancellation_reason`
   - Marks related `tickets.status = 'refunded'`
   - Enqueues `ticket_cancellation` or similar emails

10. **Age restriction applied consistently**
    - Migration `20260331000000_add_age_restriction_to_events.sql` — `events.age_restriction` column
    - Purchase flow validates user meets age (if user claims age)
    - Scanner flow may require ID verification for flagged events

### Data-level invariants

Run `references/audit-queries.sql`.

### Audit output template

```
## Events Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] status CHECK constraint intact
- [PASS/FAIL] cancellation_status separate from status
- [PASS/FAIL] Event save seeds ticket_types
- [PASS/FAIL] VIP auto-setup when vip_enabled
- [PASS/FAIL] Image upload validates size/format
- [PASS/FAIL] Duplicate detection in UI
- [PASS/FAIL] Delete protection for events with tickets
- [PASS/FAIL] Reminder cron idempotent via event_reminder_log
- [PASS/FAIL] Cancellation atomic + logged
- [PASS/FAIL] Age restriction column + enforcement

### Data-level
- [PASS/FAIL] Every published event has ticket_types (query #1)
- [PASS/FAIL] Every vip_enabled event has event_vip_tables (query #2)
- [PASS/FAIL] No events with past date + status='published' >7d (query #3 — should be archived)
- [PASS/FAIL] No events with NULL event_date (query #4)
- [PASS/FAIL] Cancelled events have cancelled_at + reason (query #5)
- [PASS/FAIL] No duplicate (name, event_date) pairs (query #6)
- [PASS/FAIL] Orphan ticket_types without event (query #7)
- [PASS/FAIL] Orphan event_vip_tables without event (query #8)
- [PASS/FAIL] Reminder log coverage for upcoming events (query #9)

### Failures
[List]
```

---

## Mode: diagnose

### Step 1: Ask
- Which event (id + name)?
- What step of the lifecycle? (create / publish / edit / cancel / archive)
- What error message or unexpected behavior?

### Step 2: Simple checks
```sql
SELECT id, name, event_date, status, cancellation_status, vip_enabled, image_url,
       organizer_id, venue_id, age_restriction, created_at, updated_at
FROM events WHERE id = '<id>';

-- Does it have ticket types?
SELECT id, name, price_cents, capacity, tickets_sold, is_active
FROM ticket_types WHERE event_id = '<id>';

-- VIP tables?
SELECT id, table_number, tier, price_cents, is_available
FROM event_vip_tables WHERE event_id = '<id>';
```

### Step 3: Match against incidents (see `references/incidents.md`)
- Event created but not purchasable → ticket_types missing or status='draft'
- VIP enabled but no tables → auto-setup didn't fire
- Event cancellation partial → cancel-event-with-refunds Edge Function failed mid-iteration
- Image upload fails → bucket permissions or file size
- Flyer scan returned wrong data → scan-flyer Edge Function needs review
- AI description off-topic → generate-event-description prompt needs tweaking

### Step 4-6: 3-file rule, Two-strike, stay in scope.

---

## Mode: scale-check

Before announcing a full quarter's events or a seasonal series:

### 1. Bulk event creation
- Creating 20+ events via UI is tedious. Is there a bulk import? Or does staff manually create each?
- If bulk: audit the importer — does it go through same validation + VIP auto-setup as UI?

### 2. VIP template coverage
- `vip_table_templates` table: are there presets for common layouts (standard Friday, holiday, DJ night)?
- Without templates, staff manually configures each event's VIP → high error rate

### 3. Reminder cron capacity
- `send-event-reminders` runs hourly. For 20 events × 500 tickets × 2 reminders = 20,000 emails/week.
- Email queue can handle if worker running (see `maguey-bulletproof-email`)

### 4. Image storage projection
- Each event image up to 5MB. 20 events × 2 images avg = 100-200MB per season.
- Storage quota (Pro = 100GB) — fine for reasonable timeline.

### 5. Cancellation impact
- If one event is cancelled: bulk refund through Stripe. Verify idempotency, time bound.
- For a 1000-ticket event → ~1000 Stripe refund calls over several minutes.

### 6. Age restriction + ID verification
- If any event is 21+, does the scanner flow enforce ID check?
- `id_verifications` table tracks checks; verify integration.

### Output

```
## Events Scale Readiness — Season: [name], Events: [X]

### Bulk create path: [exists? / manual]
### VIP templates ready: [Y/N]
### Reminder capacity: [X emails projected vs Y capacity]
### Storage projection: [X MB vs Y GB quota]
### Cancellation rehearsal: [done? / documented?]
### Age-restricted events: [count + ID verification flow verified]

### Verdict: [READY / NOT READY]
```

---

## Critical Flow: Event create

1. Owner opens EventManagement → New Event dialog
2. Fills: name, date, time, description (or uses AI-generate), venue, image upload
3. Optionally: upload flyer → scan-flyer extracts details → autofill
4. Defines ticket tiers (e.g. Early Bird, Regular, VIP)
5. Optionally enables VIP (checkbox) → floor plan preset or custom
6. Age restriction dropdown (18+, 21+)
7. Status defaults to `draft`
8. Save → INSERT events row + INSERT ticket_types rows + (if VIP) INSERT event_vip_tables rows
9. Owner reviews draft, flips to `published` → now visible on marketing + purchasable on pass-lounge
10. Realtime propagates to all 3 apps (see `maguey-bulletproof-sync`)

## Critical Flow: Event cancellation

1. Owner clicks "Cancel Event" → confirm dialog, enters reason
2. `cancel-event-with-refunds` Edge Function called:
   - UPDATE events: cancellation_status='cancelled', cancelled_at=now(), cancellation_reason=...
   - Query orders with tickets for this event, status='paid'
   - For each order: Stripe refund (with idempotency_key = 'refund-<order_id>')
   - UPDATE orders: status='refunded', refunded_at=now()
   - UPDATE tickets: status='refunded'
   - Enqueue refund email
3. Scanner stops accepting this event (rejects at door)
4. Marketing + purchase sites update via realtime (event no longer bookable)

---

## HARD RULES

- **NEVER write to prod DB.**
- **NEVER delete an event with sold tickets** — use cancellation flow instead.
- **NEVER skip cancellation email** — customers need proof of refund.
- **NEVER create an event via client code bypassing the scanner dashboard** (only path allowed per CLAUDE.md).
- **Branch workflow:** fix/... or feature/... branches.
- **User reports override queries.** "The event is canceled but still shows on marketing" → trust that, find the broken link.
