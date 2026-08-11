# Email — Invariants

## Secrets Hygiene
1. `RESEND_API_KEY` is in Supabase Edge Function secrets only. Never client-side, never VITE_-prefixed.
2. `RESEND_WEBHOOK_SECRET` (Svix) for verifying incoming Resend events.
3. `EMAIL_FROM_ADDRESS` env var (defaults `tickets@magueynightclub.com`). Must match a Resend-verified domain.

## Queue Workflow
4. Emails NEVER sent directly from app/Edge Function. Always enqueued to `email_queue`.
5. `process-email-queue` worker is the single sender path.
6. Worker runs every 1 minute via pg_cron. Configurable.
7. Each run claims up to 10 pending rows via `claim_pending_emails` RPC (optimistic lock).
8. Claimed rows flip status from 'pending' to 'processing' atomically; only rows still 'pending' can be claimed.

## Status Lifecycle
9. `email_queue.status` ∈ {`pending`, `processing`, `sent`, `delivered`, `failed`, `bounced`, `complained`}.
10. CHECK constraint enforces allowed values.
11. Transitions: pending → processing → sent → delivered (or bounced/complained). Failed path retries.

## Retry / Backoff
12. Max attempts: 5.
13. Exponential backoff schedule: 1, 2, 4, 8, 16 minutes (cap 30min) + 10% jitter.
14. After 5 attempts: status='failed' permanently. Audit query #13 surfaces.

## Email Types (CHECK constraint)
15. `ga_ticket`, `vip_confirmation`, `ticket_transfer_received`, `ticket_transfer_sent`, `event_reminder_24h`, `event_reminder_2h`.
16. Adding a new type requires migration updating the CHECK constraint.

## QR Codes
17. QR codes in emails are base64 data URLs, inlined in HTML `<img src="data:image/png;base64,...">`.
18. Generated client-side in template functions (`generateQRCode` or similar).
19. No external QR image URLs — avoids broken links if CDN down.

## Delivery Tracking
20. `resend-webhook` receives events: sent, delivered, bounced, complained, opened, clicked.
21. Each event produces a row in `email_delivery_status` (audit trail, never overwritten).
22. `email_queue.resend_email_id` links our row to Resend's message ID for correlation.

## Idempotency
23. Event reminders: UNIQUE(ticket_id, reminder_type) in `event_reminder_log` — second call same day rejected at DB.
24. Order confirmation: one email per order (related_id = order.id, email_type = 'ga_ticket'). Duplicate = bug.

## Bounce Handling
25. Hard bounce → status='bounced', no retry.
26. Soft bounce → retry once, then status='bounced'.
27. Complaint → status='complained', unsubscribe from all further sends.

## Newsletter Separation
28. Newsletter emails (from `newsletter_subscribers`) are separate from transactional emails.
29. Unsubscribed users still receive transactional (ticket, VIP, reminders) — that's legally required per CAN-SPAM.

## Performance
30. Avg send latency: 60-120 seconds from enqueue to customer inbox under normal load.
31. Worker throughput: 10 emails/min = 600/hour per worker. Scale via batch size or cron frequency.
