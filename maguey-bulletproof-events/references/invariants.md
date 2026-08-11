# Events — Invariants

## Lifecycle
1. `events.status` ∈ {`draft`, `published`, `archived`} OR NULL (legacy).
2. `cancellation_status` ∈ {`active`, `cancelled`} — orthogonal to status.
3. Valid paths: new → `draft` → `published` → `archived`. Any state → `cancellation_status = cancelled`.

## Creation
4. Only `EventManagement.tsx` (scanner dashboard) creates events.
5. Creating an event with defined ticket tiers INSERTs `ticket_types` rows automatically.
6. Creating with `vip_enabled=true` seeds `event_vip_tables` (from templates or defaults).
7. Default status on create: `draft`.

## Ticket Types
8. Every published upcoming event has ≥1 `ticket_types` row with `is_active=true` + `price_cents > 0`.
9. `ticket_types.capacity` is immutable once tickets sold (changing it risks oversell).

## VIP
10. `vip_enabled=true` on `events` implies existence of `event_vip_tables` rows for that event.
11. `vip_table_templates` provides reusable configurations (common tiers, layouts).
12. Individual VIP table fields: `table_number`, `tier`, `capacity`, `price_cents`, `bottles_included`, `is_available`, `display_order`.

## Images
13. Event image stored in Supabase Storage `event-images` bucket with public read.
14. Max file size: 5MB. Formats: jpg, png, webp.
15. Upload path: `events/{eventId}/{timestamp}-{random}.{ext}`.
16. `events.image_url` stores the public URL after upload.

## Cancellation
17. Cancellation flow uses `cancel-event-with-refunds` Edge Function — not direct DB update.
18. Cancellation atomically: event flagged + tickets refunded + orders refunded + emails enqueued.
19. Stripe refunds use idempotency key `refund-<order_id>` — safe to retry.
20. `events.cancelled_at` + `cancellation_reason` always populated when `cancellation_status='cancelled'`.

## Reminders
21. `send-event-reminders` Edge Function runs on cron (typically hourly).
22. `event_reminder_log` UNIQUE(ticket_id, reminder_type) — idempotent per-ticket.
23. Reminder types: `event_reminder_24h`, `event_reminder_2h`.
24. Only active, upcoming events (not cancelled, not past) get reminders.

## Duplicates
25. UI should warn or block duplicate (name, event_date) creation.
26. No DB-level constraint (different dates can have same name legitimately).

## Delete Protection
27. Events with sold tickets cannot be deleted — cancellation flow required.
28. FK from `tickets.event_id` + `vip_reservations.event_id` prevents accidental drop.

## Age Restriction
29. `events.age_restriction` column: `'none'`, `'18+'`, `'21+'` (or similar).
30. Purchase flow may prompt for DOB if restricted event.
31. Scanner flow integrates with `id_verifications` for age checks at door.

## AI Assistance
32. `generate-event-description` Edge Function — AI-generated description (prompt-engineered for nightclub tone).
33. `scan-flyer` Edge Function — OCR extracts fields from uploaded image → autofills form.
34. AI outputs are suggestions — owner reviews + edits before save.

## Multi-Artist Flyers
35. Recent feature per git log: flyer scanning supports multi-artist detection.
36. Extracted artist names may populate event's `artists` or `lineup` field (if exists).
