# Sync — Invariants

## Single Source of Truth
1. One `events` table in one Supabase project (`djbzjasdrwvbsoifxqzd`). All 3 apps connect to it. No replication.
2. Only `EventManagement.tsx` (scanner dashboard) creates/edits events. Marketing and purchase apps are read-only for event data.

## Event Status Lifecycle
3. `events.status` ∈ {`draft`, `published`, `archived`}. CHECK constraint enforces.
4. `draft` — visible only to owner/promoter roles; not purchasable.
5. `published` — public; visible on marketing + purchase.
6. `archived` — past events; visible for historical reference but not purchasable.
7. `cancellation_status = 'cancelled'` — overrides status; event is hidden and refunded.

## Visibility Rules (ACTUAL vs INTENDED)
8. Purchase site filters: `status = 'published'` OR NULL, `event_date >= today`, `cancellation_status != 'cancelled'` (via `useEventsRealtime`).
9. Marketing site filters: `status = 'published'` AND `is_active = true` AND `event_date >= today` (via `fetchActiveEvents` in `maguey-nights/src/services/eventService.ts:206-212`, called by the `useEvents` hook and on every realtime callback). Verified 2026-04-21 — no longer a gap.
10. Scanner dashboard shows all events with filters applied in UI.

## Realtime Propagation
11. Every mutation on `events` broadcasts via `supabase_realtime` publication.
12. All consumer apps subscribe to `postgres_changes` on schema=public, table=events, event=*.
13. Changes propagate within ~500ms under normal conditions.
14. If a tab is hidden during a change, the purchase site refetches on visibility change; marketing does NOT (minor gap).

## URL Configuration
15. Purchase site URL is centralized in `maguey-nights/src/lib/purchaseSiteConfig.ts`.
16. Env var priority: `VITE_PURCHASE_SITE_URL` > `VITE_PURCHASE_WEBSITE_URL` > localhost (dev) > production fallback.
17. No component hardcodes `tickets.magueynightclub.com` except this config file.

## Image Storage
18. Event images uploaded to `event-images` bucket in Supabase Storage.
19. Public read (no auth required). Files at `events/{eventId}/{timestamp}-{random}.ext` or similar.
20. 5MB max upload size (enforced in `event-image-service.ts`).
21. `cacheControl: '3600'` (1h) — image updates propagate after cache TTL.
22. `events.image_url` stores the full public URL.

## CORS
23. Edge Function `_shared/cors.ts` lists production origins (`magueynightclub.com`, `www.magueynightclub.com`, `tickets.magueynightclub.com`, `staff.magueynightclub.com`) + dev localhost.
24. `ALLOWED_ORIGINS` env var overrides.
25. Unknown origin falls back to `PRODUCTION_ORIGINS[0]` (minor risk of CORS error on unexpected domain).

## Connection / Subscriptions
26. Supabase realtime has connection limits per project (Pro tier: 200 concurrent connections).
27. Each open tab consumes 1 connection. 3 apps × active users = total connections.
28. Subscription failure falls back to periodic refetch (visibility-based on purchase side; manual on marketing).
