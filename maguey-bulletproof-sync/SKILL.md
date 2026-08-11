---
name: maguey-bulletproof-sync
description: Audit, diagnose, or scale-check the Maguey Nightclub cross-site sync system — one shared Supabase events table feeding 3 apps (maguey-nights marketing, maguey-pass-lounge purchase, maguey-gate-scanner dashboard) via realtime subscriptions. Covers useEventsRealtime hook, useEvents hook, event status visibility rules (draft/published/archived), event-images storage bucket, realtime publication coverage, purchase-site URL config. Use when an event created in the dashboard doesn't appear on marketing/purchase, stale event data persists, image updates don't propagate, or before adding a new site or expanding the domain setup. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB.
---

# Maguey Bulletproof Sync

Three apps read the same Supabase. If they go out of sync, customers see different realities: marketing advertises an event that purchase rejects, or dashboard edits that never reach the marketing page. This skill keeps that chain tight.

This skill covers:
- `maguey-nights/src/hooks/useEvents.ts` (marketing — simple realtime subscription)
- `maguey-pass-lounge/src/hooks/useEventsRealtime.ts` (purchase — status-filtered subscription)
- `maguey-pass-lounge/src/pages/Events.tsx` + `EventDetails.tsx`
- `maguey-gate-scanner/src/pages/EventManagement.tsx` (source of truth for event CRUD)
- `maguey-gate-scanner/src/lib/event-image-service.ts` (image upload)
- `maguey-nights/src/lib/purchaseSiteConfig.ts` (cross-site URL config)
- Shared `events` table + realtime publication
- Supabase Storage bucket `event-images`
- Tables: `events`, `sites`, `site_content`, `site_environment_config`, `venues`, `cross_site_sync_log` (if exists)

**Not covered here:**
- Event CRUD edge cases (create/cancel/refund) → `maguey-bulletproof-events`
- Auth per app → `maguey-bulletproof-auth`
- Ticket inventory sync → `maguey-bulletproof-tickets`

---

## Schema Reality Check (verified 2026-04-21 against live DB)

### CRITICAL FINDING — `supabase_realtime` publication is EMPTY

On 2026-04-21 I ran:
```sql
SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime';
-- returns 0 rows
SELECT pubname, puballtables FROM pg_publication;
-- returns: supabase_realtime (puballtables=false), supabase_realtime_messages_publication (false)
```

**The `supabase_realtime` publication exists but has NO tables in it.** That means Postgres-replication-based realtime (`supabase.channel().on('postgres_changes', ...)`) is NOT receiving events for `events`, `orders`, `ticket_types`, `tickets`, or any other table. This is a HUGE deal for sync — the hooks `useEvents` (marketing) and `useEventsRealtime` (purchase) subscribe to `postgres_changes`, which silently gets zero messages.

**What this means in practice:**
- Dashboard creates an event → NO realtime broadcast reaches marketing / purchase sites.
- The UI "mostly works" because the `useEventsRealtime` hook also refetches on tab focus + initial load. But changes made while a tab is open do NOT auto-appear.
- The silent failure is the worst part: no error, just stale data until manual refresh.

**Fix path (requires user approval — WRITE operation):**
```sql
ALTER PUBLICATION supabase_realtime ADD TABLE events;
ALTER PUBLICATION supabase_realtime ADD TABLE ticket_types;
ALTER PUBLICATION supabase_realtime ADD TABLE orders;
ALTER PUBLICATION supabase_realtime ADD TABLE vip_reservations;
ALTER PUBLICATION supabase_realtime ADD TABLE vip_guest_passes;
-- etc. for any table the app subscribes to
```

Verify with `pg_publication_tables` — expect rows after each ALTER. FLAG THIS as GAP #1 on every audit until resolved.

### Verified schema for the sync tables

- **`sites`** columns: `id, site_type, name, url, environment, is_active, description, metadata (jsonb), created_at, updated_at`.
- **`site_content`** columns: `id, site_type, content_type, content_key, title, content, metadata, is_published, published_at, created_at, updated_at`.
- **`site_environment_config`** columns: `id, site_type, environment, config_key, config_value_encrypted, is_secret, description, created_at, updated_at`.
- **`venues`** columns: `id, name, slug, subdomain, custom_domain, organization_id, is_active, settings, created_at, updated_at`.
- **`venue_branding`** columns: `id, venue_id, logo_url, logo_square_url, favicon_url, primary_color, secondary_color, accent_color, font_family, custom_css, theme_preset, settings, created_at, updated_at`.
- **`branding_sync`** columns: `id, site_type, auto_sync, branding_config (jsonb), last_synced_at, synced_by, created_at, updated_at`.
- **`cross_site_sync_log`** columns: `id, sync_type, source_site, target_sites (text array), status, details (jsonb), synced_by, created_at, completed_at`. Older drafts used `entity_type`/`entity_id`/`error_message`/`synced_at` — those don't exist; use `details` jsonb + `status` + `completed_at`.

`events.image_url` is public via Supabase Storage `event-images` bucket. Cache-control is set at upload time by `event-image-service.ts`; verify against migration/code.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — 3 domains + shared Supabase rule.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — "maguey-nights has NO supabase directory" rule (no migrations, no edge functions in that app).
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

Confirm "Preflight complete. Running [mode]." Supabase: `mcp__supabase__execute_sql` project `djbzjasdrwvbsoifxqzd`.

---

## Choose a Mode

- **audit** → run weekly + before adding a new site or domain
- **diagnose** → event doesn't appear where expected (or stale data)
- **scale-check** → adding a 4th site, moving domains, or onboarding a second venue

---

## Mode: audit

### Code-level invariants

1. **Single `events` table, no replication**
   - All 3 apps connect to same Supabase (project `djbzjasdrwvbsoifxqzd`).
   - Grep all 3 apps' `.env*` files and `src/integrations/supabase/client.ts` / `src/lib/supabase.ts` — should all point to the same `VITE_SUPABASE_URL`.
   - Command: `grep -rn "VITE_SUPABASE_URL" maguey-nights/src maguey-pass-lounge/src maguey-gate-scanner/src .env*`
   - Fail: any app pointing to a different URL.

2. **Status filter parity (RESOLVED 2026-04-21)**
   - `maguey-nights/src/services/eventService.ts:206-212` (`fetchActiveEvents`) filters `status='published' AND is_active=true AND event_date >= today`. The `useEvents` hook calls this on initial load and re-runs it on every realtime callback + visibility-change.
   - `maguey-pass-lounge/src/hooks/useEventsRealtime.ts` line ~75-78 filters `status='published'` OR NULL (the OR-NULL branch is a legacy allowance for events inserted before the `status` column existed).
   - Marketing and purchase are in parity; draft events cannot leak to customer-facing sites.
   - If the marketing filter is ever removed or the purchase filter drifts, flag as a regression.

3. **Realtime subscription healthy on all 3 apps**
   - Marketing: `useEvents.ts` line ~31-45, subscribes to `postgres_changes` on `events`
   - Purchase: `useEventsRealtime.ts` line ~174-220, subscribes + re-sorts
   - Scanner dashboard: any Event list / OwnerDashboard component should subscribe
   - Grep: `grep -rn "postgres_changes.*events\|.channel.*events" src/`

4. **Visibility change refetch (purchase only)**
   - `useEventsRealtime.ts` line ~206-210 — refetches when tab regains focus
   - Why: if subscription missed an event while tab was hidden, this rescues it.
   - Missing = stale data risk.

5. **Purchase site URL config centralized**
   - File: `maguey-nights/src/lib/purchaseSiteConfig.ts`
   - Priority chain: `VITE_PURCHASE_SITE_URL` → `VITE_PURCHASE_WEBSITE_URL` → localhost dev → production fallback
   - No hardcoded `tickets.magueynightclub.com` in marketing components (except this config).
   - Grep: `grep -rn "tickets.magueynightclub\.com" maguey-nights/src/` — should only match in `purchaseSiteConfig.ts`

6. **Image bucket + URL pattern consistent**
   - Scanner uploads to `event-images` bucket (`event-image-service.ts` lines ~19-87)
   - Public read access (no auth header needed to fetch image)
   - `events.image_url` is populated with the public Supabase URL
   - All 3 apps render `<img src={event.image_url} />` directly

7. **Cache-Control on images**
   - Scanner's image uploader sets `cacheControl: '3600'` (1 hour)
   - Implication: edits take up to 1h to refresh on marketing/purchase sites if cached by CDN
   - Flag if user reports "I updated the event image but it's still showing the old one"

8. **Publication includes `events`**
   - Supabase auto-publishes all public schema tables by default unless explicitly excluded.
   - Query: `SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime' ORDER BY tablename;`
   - Must include: `events`, `ticket_types`, `orders` (for dashboard real-time revenue), and VIP tables.

9. **No duplicate event creation path**
   - Only `EventManagement.tsx` (scanner) creates events.
   - Grep pass-lounge + marketing: `grep -rn "from.*'events'.*insert" maguey-pass-lounge/src maguey-nights/src` → 0 matches

10. **`events.status` valid values only**
    - Migration has CHECK constraint on `status IN ('draft', 'published', 'archived')` (migration `20250303000000_add_event_status.sql`)
    - Never ad-hoc statuses.

### Data-level invariants

Run `references/audit-queries.sql`.

### Audit output template

```
## Sync Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] All 3 apps point to same Supabase URL
- [PASS/FAIL] Marketing filters published events (eventService.ts fetchActiveEvents)
- [PASS/FAIL] Realtime subscription on events in each app
- [PASS/FAIL] Tab-focus refetch on purchase
- [PASS/FAIL] Purchase URL config centralized
- [PASS/FAIL] Image bucket + URL pattern
- [NOTE] Image cache 1h — updates may delay
- [PASS/FAIL] Realtime publication includes events
- [PASS/FAIL] Only scanner dashboard creates events
- [PASS/FAIL] events.status CHECK constraint present

### Data-level
- [PASS/FAIL] No events with invalid status (query #1)
- [PASS/FAIL] No events with future date but past cancellation (query #2)
- [PASS/FAIL] No events with NULL image_url in 'published' state (query #3 — may be acceptable)
- [PASS/FAIL] cross_site_sync_log no drift errors (query #4 — if table exists)
- [PASS/FAIL] No orphan sites rows (query #5)
- [PASS/FAIL] Events consistent between publications and subscriptions (query #6)

### Failures
[List]
```

---

## Mode: diagnose

### Step 1: Ask
- Which site is showing wrong data? marketing / purchase / scanner dashboard?
- Which specific event?
- What's expected vs shown?
- When was the event last edited? (correlate with user's last edit time)

### Step 2: Simple checks
- `SELECT id, name, status, event_date, image_url, updated_at FROM events WHERE id = '<id>';` — this is the truth
- Compare against what user reports seeing on each site
- Browser hard refresh (Cmd+Shift+R) on the site showing wrong data — forces non-cached fetch

### Step 3: Match against incidents (see `references/incidents.md`)
- Marketing shows draft event → status filter missing (known gap)
- Purchase site doesn't show new event → realtime subscription missed; user needs to refresh
- Image not updating → CDN cache (1h TTL) or cacheControl set too long
- Dashboard edit not reaching marketing → subscription broken on marketing side
- All 3 sites stale → Supabase realtime itself is down (check status.supabase.com)

### Step 4-6: 3-file rule, Two-strike rule, stay in scope.

---

## Mode: scale-check

Before adding a new site, domain, or venue:

### 1. Env var propagation
- `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` in Vercel for all 3 projects — still match?
- `VITE_PURCHASE_SITE_URL` on marketing — points to new purchase domain if changed?
- `VITE_PURCHASE_SITE_URL` on scanner (for dashboard links) — same?

### 2. ALLOWED_ORIGINS on Edge Functions
- `_shared/cors.ts` — hardcoded production origins list must include any new domain
- Env var `ALLOWED_ORIGINS` override — can be set per environment

### 3. Subscription capacity
- Supabase realtime has per-project connection limits.
- 3 apps × avg 50 concurrent users each = 150 connections. Should be well under limit.
- Flag if expected concurrent users > 1000 combined.

### 4. Image storage quota
- Supabase Storage quota (Pro tier = 100GB). Current usage:
```sql
SELECT SUM(metadata->>'size')::bigint / 1024 / 1024 AS total_mb
FROM storage.objects WHERE bucket_id = 'event-images';
```

### 5. Additional venue support
- If adding a second venue: `venues` table already exists. Does the `events` table have a `venue_id` FK? Check schema.
- Without `venue_id`, events implicitly belong to Maguey Delaware only.

### Output

```
## Sync Scale Readiness

### Env vars aligned: [YES/NO]
### ALLOWED_ORIGINS includes new domain: [YES/NO]
### Realtime connection headroom: [current vs limit]
### Storage quota: [X GB of Y]
### Multi-venue schema ready: [YES/NO]

### Verdict: [READY / NOT READY]
```

---

## Critical Flow: Create event in dashboard → appears on marketing + purchase

1. Owner creates event in `EventManagement.tsx` → INSERT `events` row (status='draft' or 'published')
2. Supabase realtime broadcasts change
3. Marketing's `useEvents` subscription receives it → state updates → render
4. Purchase's `useEventsRealtime` subscription receives it → if status='published', inserts into sorted state → render
5. Scanner dashboard's realtime also sees it → event list refreshes

**Typical latency:** ~100-500ms for realtime delivery. User refreshing within 1s sees new event.

**Common breakpoints:**
- Event stays draft → never reaches published; purchase site won't show
- Realtime down → all 3 apps show stale until next manual refresh
- Marketing subscribed with filter that excludes → design bug
- RLS on events blocks anon → realtime delivered but row filtered out for anon users (check policy)

---

## HARD RULES

- **NEVER write to prod DB.**
- **NEVER create events from any app other than the scanner dashboard.**
- **NEVER hardcode a domain in app code.** Always via env var or `purchaseSiteConfig`.
- **NEVER add a new realtime subscription without load-test considering connection count.**
- **Branch workflow:** fix/... or feature/... branches.
- **User reports override queries.** "It's showing draft on marketing" — trust that, even if code "should" filter.
