# VIP — Invariants

> **Schema Reality Check (verified 2026-04-21 after audit)**
> - `vip_reservations` has NO `guest_count`. Capacity lives on
>   `event_vip_tables.capacity` via `event_vip_table_id`. Customer-requested
>   count is in `package_snapshot->>'guestCount'`.
> - `vip_reservation_status` enum: `pending, confirmed, checked_in, no_show, cancelled`.
>   NO `completed` value.
> - `vip_guest_passes` columns: `pass_number` (NOT guest_number), `qr_token`
>   (NOT qr_code_token). Pass status text: `assigned/available/checked_in/cancelled`.
> - `vip_linked_tickets` FK is `vip_reservation_id` (NOT reservation_id).
> - `event_vip_tables` has `price_cents`, `capacity`, `is_available`. NO
>   `price`, `table_name`, or `is_active` columns.
> - Signing RPC is `sign_vip_pass(text) -> text`. `generate_vip_pass_signature`
>   does NOT exist (any migration referencing it is dead code).
> - Signature format for passes: `${qr_token}|${reservation_id}|${pass_number}`.


## Pricing & Money
1. VIP table price comes from `event_vip_tables.price_cents`. Never trust client.
2. Bottle config / package snapshot resolved server-side in `create-vip-payment-intent`.
3. Total charged to Stripe PI = sum of server-resolved prices, full stop.

## Atomicity
4. Reservation creation uses `create_vip_reservation_atomic` RPC with `FOR UPDATE` on the `event_vip_tables` row.
5. `rollback_vip_checkout` RPC is called on ANY exception after reservation creation but before successful PI+confirmation.
6. Unified GA+VIP via `create_unified_vip_checkout` is a single transaction — ticket + reservation + link succeed together or fail together.

## State Machine
7. Valid reservation transitions: pending → confirmed → checked_in; pending → cancelled; confirmed → no_show; any → cancelled. Terminal states: checked_in, no_show, cancelled.
8. `validate_vip_status_transition` trigger rejects invalid state jumps.

## Guest Passes
9. Every confirmed reservation has `event_vip_tables.capacity` passes in `vip_guest_passes` (1 host pass, N-1 guest passes). Customer-requested guestCount lives in `package_snapshot->>'guestCount'` but the trigger uses capacity as the default.
10. Every pass has `qr_token` + `qr_signature` populated. Signing is via `sign_vip_pass(text)` RPC (NOT sign_qr_token — that's the GA-ticket signer). Signature input: `${qr_token}|${reservation_id}|${pass_number}`.
11. Pass status: assigned (host) / available (guest) → checked_in (on first scan) → reentry state (2nd+ scans don't change stored status).

## Ownership & Security
12. `confirm-vip-payment` verifies `purchaser_email` matches the request context before flipping status.
13. No anonymous role can UPDATE `vip_reservations` (Feb 2026 security lockdown).
14. `vip_scan_logs` readable by public but only staff can INSERT.

## Check-In Flow
15. `process_vip_scan_with_reentry` distinguishes first_entry vs reentry based on pass.status.
16. First entry increments `reservations.checked_in_guests` by 1.
17. Re-entry does NOT increment the counter.
18. `checked_in_guests` cannot exceed `event_vip_tables.capacity` (join via event_vip_table_id).

## Table Availability
19. `event_vip_tables.is_available` is false when any non-cancelled reservation exists for the table.
20. `sync_vip_table_availability` trigger keeps this in sync (migration `20260407205728`).

## Capacity (bottle service tier feature)
21. `vip_bottle_config` defines allowed bottles per event VIP table. If empty, UI falls back to "confirmed by your host".
22. Bottle selection stored in `vip_reservations.package_snapshot` (JSON) — immutable after confirm.

## Linked Tickets
23. `vip_linked_tickets.ticket_id` is UNIQUE (a GA ticket can link to at most one VIP reservation).
24. `check_vip_linked_ticket_reentry` returns allow_reentry=true if the ticket is linked AND the reservation is active.

## Invite Codes
25. Every confirmed reservation has a non-null `invite_code` (generated at reservation creation since migration `20260408010000`).
26. Invite code is how guests bought separate GA tickets get linked to the VIP party.

## Rate Limiting
27. Both VIP Edge Functions (`create-vip-payment-intent`, `confirm-vip-payment`) enforce 20 req/min per IP via `checkRateLimit(req, 'payment')`.
28. Rate limit is fail-open if Upstash unavailable (availability > strict limiting).
