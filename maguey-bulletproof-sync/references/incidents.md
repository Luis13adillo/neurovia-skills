# Sync — Known Incidents & Fix Patterns

---

## Incident: Draft event visible on marketing site
**Symptom:** Owner sets event to status='draft', but it still appears on magueynightclub.com.
**Root cause:** `maguey-nights/src/hooks/useEvents.ts` does not filter by `status`. Fetches all events.
**Fix (requires approval):**
```typescript
// In useEvents.ts, filter the fetched list:
const { data } = await supabase.from('events')
  .select('*')
  .eq('status', 'published')
  .gte('event_date', new Date().toISOString().split('T')[0])
  .neq('cancellation_status', 'cancelled')
  .order('event_date', { ascending: true });
```
And mirror in the realtime handler — on INSERT/UPDATE, only keep rows meeting the same filter.

---

## Incident: Event created in dashboard but missing from purchase site
**Symptom:** Owner creates event (status='published'), marketing shows it, but purchase does not.
**Root cause options:**
1. Purchase realtime subscription is disconnected (tab hidden too long, subscription dropped)
2. RLS policy on events blocks anon role — but published events should be readable
3. Event missing `event_date` or date is in the past

**Debug:**
```sql
SELECT id, name, status, event_date, cancellation_status, updated_at
FROM events WHERE id = '<id>';
```
**Fix:** user hard-refreshes purchase site (Cmd+Shift+R). If persistent, verify subscription status in Supabase Dashboard → Realtime.

---

## Incident: Event image updated but old image still shown
**Symptom:** Owner uploads new flyer, `events.image_url` is new, but all 3 sites still show old image.
**Root cause:** browser/CDN caching on `cacheControl: 3600`. Old URL cached for up to 1 hour.
**Fix:**
1. Upload image with a new path (e.g. include timestamp) so the URL itself changes → bypasses cache
2. OR reduce `cacheControl` to 60 seconds at upload (trade-off: more egress)
3. OR Supabase Storage → Transformation → use on-the-fly resizing which accepts query params to bust cache

---

## Incident: All 3 sites showing stale data simultaneously
**Symptom:** Owner edits event, nothing updates anywhere for several minutes.
**Root cause options:**
1. Supabase realtime service outage — check https://status.supabase.com
2. Connection cap hit — too many concurrent subscribers
3. Publication misconfigured (events no longer in `supabase_realtime`)

**Debug:**
```sql
SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime';
```
If `events` is missing, restore: `ALTER PUBLICATION supabase_realtime ADD TABLE events;` (WRITE — requires approval).

---

## Incident: Purchase site "sold out" but scanner dashboard shows availability
**Symptom:** Customer tries to buy, site says sold out. Owner checks dashboard, sees 50 tickets available.
**Root cause:** `ticket_types.tickets_sold` cached counter drifted from actual `tickets` count.
**Escalate to:** `maguey-bulletproof-tickets` — this is a tickets-domain integrity issue, not a sync issue per se.

---

## Incident: Link from marketing to purchase site broken
**Symptom:** Clicking "Buy Tickets" on marketing leads to 404 or wrong URL.
**Root cause:** `VITE_PURCHASE_SITE_URL` mis-set on Vercel for marketing site.
**Debug:** check Vercel env vars for `maguey-nights` project — does the prod env have the right URL?
**Fix:** update env var in Vercel Dashboard, redeploy marketing.

---

## Incident: Adding a new custom domain breaks things
**Symptom:** DNS configured for e.g. `events.magueynightclub.com`, but API calls return CORS error.
**Root cause:** `ALLOWED_ORIGINS` env var on Edge Functions doesn't include new domain; `_shared/cors.ts` fallback is to production[0].
**Fix:** update Supabase Dashboard → Edge Function secrets → `ALLOWED_ORIGINS` to include new domain (comma-separated). Redeploy functions.

---

## Incident: OwnerDashboard revenue counter doesn't update in real time
**Symptom:** Order completes but dashboard's revenue tile stays stale until reload.
**Root cause options:**
1. `orders` table not in realtime publication
2. Subscription in OwnerDashboard not filtering correctly
3. RLS on orders blocks owner role from seeing all orders (unlikely but possible)

**Fix:** verify `orders` in `pg_publication_tables`, verify OwnerDashboard subscribes to `postgres_changes` on `orders` with appropriate filter, verify RLS policy for owner role.

---

## Incident: Dashboard edit propagates, but marketing misses it
**Symptom:** Owner changes event name, purchase site updates, marketing site doesn't.
**Root cause:** marketing's subscription handler doesn't re-hydrate on UPDATE event — only on INSERT.
**Fix:** `useEvents.ts` subscription callback should handle INSERT, UPDATE, and DELETE events. Check switch/if on payload.eventType.

---

## Pattern: Multi-venue expansion
If Maguey adds a second venue (e.g. Philly location):
1. Add row to `venues` table
2. Add `venue_id` FK column to `events` (migration needed — approval required)
3. Update all 3 apps to filter by venue_id where appropriate
4. Update marketing site to show a venue selector
5. Cross-site sync: still works as-is since all apps share the same DB, just need UI filters

**Gotchas:**
- Hardcoded "Maguey Delaware" / "3320 Old Capitol Trl" in components — grep and replace with dynamic from events.venue_name/venue_address
- `VITE_PURCHASE_SITE_URL` would still be one URL — if each venue needs its own site, much bigger architectural change

---

## Pattern: Subscription fatigue at scale
If concurrent users exceed ~150, realtime connection load may cause subscription drops. Signs:
- Users see stale data intermittently
- Hard refresh fixes it temporarily
- No pattern by location

**Mitigation options:**
- Upgrade Supabase plan
- Debounce/throttle subscriptions
- Add periodic refetch as fallback (every 30s)
- Consider server-sent events or polling for read-heavy paths
