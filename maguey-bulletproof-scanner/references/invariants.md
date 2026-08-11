# Scanner — Invariants

## Signature Security
1. Every JSON-format QR payload has a signature. Unsigned JSON payloads are rejected.
2. Signature verification is fail-closed: network/API errors = reject, not accept.
3. HMAC-SHA256 is the only accepted algorithm. Implemented server-side in `verify-qr-signature` Edge Function.
4. The signing secret is NEVER in the scanner bundle. No `VITE_QR_SIGNING_SECRET` anywhere in `maguey-gate-scanner/src`.

## Cooldown & Dedup
5. Scan cooldown is 2500ms. Same QR/NFC input within that window is silently ignored.
6. `lastScannedRef` tracks the last input; `lastScanTimeRef` tracks when.
7. No two `scan_logs` rows for the same `ticket_id` within 1 second (a cooldown failure = bug).

## State Machine
8. Scanner states: `idle` → `scanning` → one of [`success`, `error`, `already_scanned`, `reentry`, `vip_success`] → back to `idle`.
9. Success overlay auto-dismisses after 1.5s. Rejection overlay requires manual dismiss.
10. VIP success overlay shows table number + reservation info.

## Ticket Check-In
11. Update `tickets.scanned_at = now()`, `is_used = true`, `status = 'scanned'` atomically with scan_log INSERT via `scan_ticket_atomic` RPC. (There is no `checked_in_at` column — `scanned_at` + `is_used` are authoritative.)
12. Every successful scan produces: `scan_logs` row (inserted by the RPC) + `ticket_events` row (via `publishTicketScanned` fire-and-forget) + `scanner_heartbeats` update.
13. Events can be specified or auto-detected (tonight's event). Cross-event scans rejected client-side until the `scan_logs.event_id` migration ships (see `migrations/20260421_add_event_id_to_scan_logs.sql` in the scanner-hardening branch).

## VIP Re-Entry
14. For GA tickets linked to VIP via `vip_linked_tickets`, `check_vip_linked_ticket_reentry` decides whether re-entry is allowed.
15. VIP guest pass re-entry is tracked in `vip_scan_logs` with `scan_type='reentry'` (doesn't increment `checked_in_guests`).

## Offline
16. Scanner pre-caches tickets to Dexie IndexedDB before the event (via `ensureCacheIsFresh`).
17. Offline scans queue locally, sync on reconnect via `sync_offline_scan` RPC.
18. Conflict resolution is first-scan-wins by SERVER-recorded timestamp of the original client scan_at.
19. Retry uses exponential backoff with a retry_count cap.

## Event Sourcing
20. `ticket_events` is append-only. Never UPDATE/DELETE a row.
21. Full lifecycle of every ticket is replayable from `ticket_events` alone.

## Heartbeat
22. Active scanner posts to `scanner_heartbeats` every 30-60s.
23. Dashboard surfaces heartbeat age; staff should be alerted if any scanner >5 min during event hours.

## Staff
24. Emergency overrides: `emergency_override_logs` table DOES NOT EXIST in this DB. If added later, overrides must be logged with reason + reviewer flag. Until then, any manual entry is effectively unlogged.
25. Fraud detection: `fraud_detection_logs` and `scan_velocity_metrics` tables DO NOT EXIST in this DB. Proxy: query `scan_logs` grouped by device + minute (see `references/audit-queries.sql` #7) to flag >20 scans/minute.

## Code Organization (consolidated 2026-04-21)
26. All production scanner logic lives in `simple-scanner.ts`. `scanner-service.ts` is no longer imported by any production code path; only integration tests reference it.
27. `Scanner.tsx` imports from `simple-scanner.ts`. `batch-scan-service.ts` imports from `simple-scanner.ts`. Do not re-introduce `scanner-service.ts` as a production dependency.

## Schema Reality Check (verified 2026-04-21)
28. `scan_logs` columns: id, ticket_id, scanned_by, scan_result, scanned_at, metadata, scan_success, device_id, scan_method. `event_id` column ships with the scanner-hardening migration; until applied, event id lives in `metadata->>'event_id'`.
29. `tickets` scan markers: `scanned_at`, `is_used`, `status`, `current_status`. There is NO `checked_in_at`.
30. `ticket_events` keys: `aggregate_id` (uuid == ticket id, NOT `ticket_id`), `occurred_at`/`recorded_at` (NOT `created_at`), append-only.
31. `vip_guest_passes.scanned_at` (NOT `checked_in_at`) is the check-in marker.
32. `app.qr_signing_secret` Postgres config is NOT set and is NOT consulted by the scanner. `verify-qr-signature` Edge Function reads `Deno.env.get("QR_SIGNING_SECRET")`. Tables that do NOT exist: `fraud_detection_logs`, `scanner_devices`, `scan_metadata`, `scan_velocity_metrics`, `device_battery_logs`, `emergency_override_logs`, `ticket_failed_scans`.
