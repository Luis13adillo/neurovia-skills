---
name: maguey-bulletproof-scanner
description: Audit, diagnose, or scale-check the Maguey Nightclub door scanner system (Scanner.tsx state machine, simple-scanner.ts QR+HMAC verification, scanner-service.ts legacy path, offline-ticket-cache.ts Dexie IndexedDB, offline-queue-service.ts first-scan-wins sync, scanner_heartbeats, ticket_events event sourcing, VIP re-entry). Use when scanner rejects valid tickets, accepts invalid ones, offline queue fails to sync, heartbeats drop, duplicate scans slip through, or before a major event where door volume spikes. Read-only SQL via mcp__supabase__execute_sql only. Never writes to production DB — scanning errors at the door cause direct customer friction and revenue loss.
---

# Maguey Bulletproof Scanner

The scanner is Maguey's physical trust boundary. Every rejection a paying customer sees at the door is a complaint. Every false-accept is a counterfeit ticket walking in. Every offline sync bug is a double-entry at scale.

This skill covers:
- `maguey-gate-scanner/src/pages/Scanner.tsx` (state machine + UI)
- `maguey-gate-scanner/src/lib/simple-scanner.ts` (939 lines — active QR+HMAC path)
- `maguey-gate-scanner/src/lib/scanner-service.ts` (1,867 lines — legacy, pending consolidation)
- `maguey-gate-scanner/src/lib/offline-ticket-cache.ts` (Dexie IndexedDB cache)
- `maguey-gate-scanner/src/lib/offline-queue-service.ts` (sync + retry)
- `maguey-pass-lounge/supabase/functions/verify-qr-signature/index.ts` (server HMAC verify)
- `maguey-gate-scanner/src/components/scanner/` (20 components)
- Tables: `scan_logs`, `scan_history`, `scan_metadata`, `scan_velocity_metrics`, `fraud_detection_logs`, `ticket_events`, `scanner_heartbeats`, `scanner_devices`, `device_battery_logs`, `emergency_override_logs`, `vip_scan_logs`
- RPCs: `sync_offline_scan`, `scan_ticket_atomic`, `process_vip_scan_with_reentry`, `check_vip_linked_ticket_reentry`

**Not covered here:**
- Ticket creation / QR signing → `maguey-bulletproof-tickets`
- VIP reservation state machine → `maguey-bulletproof-vip`
- Auth for scanner operators → `maguey-bulletproof-auth`

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/Maguey-Nightclub-Live/CLAUDE.md` — "Scanner flow" section, HMAC REQUIRED rule.
2. `/Users/luismiguel/.claude/projects/-Users-luismiguel-Desktop-Maguey-Nightclub-Live/memory/MEMORY.md` — QR signing secret server-only, unsigned rejection.
3. This skill's `references/audit-queries.sql`, `references/invariants.md`, `references/incidents.md`.

Confirm "Preflight complete. Running [mode]." Supabase: `mcp__supabase__execute_sql` project `djbzjasdrwvbsoifxqzd`.

---

## Choose a Mode

- **audit** → weekly + before every event (especially if offline is expected)
- **diagnose** → scanner symptom reported (rejects, misses, offline desync)
- **scale-check** → before a major door night, adding a new scanner device, or onboarding new staff

---

## Mode: audit

### Code-level invariants

1. **Unsigned QR codes are REJECTED**
   - File: `maguey-gate-scanner/src/lib/simple-scanner.ts` line ~149-185
   - Parsing: JSON payload with `{token, signature}` → verify. Plain text allowed for manual entry only.
   - Must reject unsigned JSON payloads with message "Unsigned QR code - ticket may be forged" (line ~163).
   - Grep: `grep -n "Unsigned QR\|signature.*required\|rejecting unsigned" src/lib/simple-scanner.ts`

2. **Signature verification fail-closed**
   - Network/API failure during verify → REJECT the ticket (line ~142).
   - Never "accept on error" or "allow if offline and HMAC unverifiable." Exception: offline cache lookup pre-validates before losing connectivity.
   - Grep: `grep -n "verify-qr-signature\|fail.*open\|fail.*close" src/lib/simple-scanner.ts`

3. **Signing secret server-only (same as tickets skill, worth re-checking here)**
   - `grep -rn "VITE_QR_SIGNING_SECRET" maguey-gate-scanner/src` → 0 matches
   - `grep -rn "QR_SIGNING_SECRET\|app.qr_signing_secret" maguey-gate-scanner/src` → matches only in Edge Function calls (not local HMAC computation)

4. **Scan cooldown in place**
   - `Scanner.tsx` line ~116: `SCAN_COOLDOWN = 2500` (ms)
   - Prevents accidental double-scans within 2.5s window
   - `lastScannedRef` + `lastScanTimeRef` pattern

5. **Two-scanner-file duplication flag**
   - Both `simple-scanner.ts` (939 lines) AND `scanner-service.ts` (1,867 lines) exist.
   - Per MEMORY.md + research, `scanner-service.ts` is legacy with a consolidation TODO.
   - CRITICAL: identify which file `Scanner.tsx` actually imports. If it imports from both, there's a logic split risk.
   - Grep: `grep -n "from.*simple-scanner\|from.*scanner-service" src/pages/Scanner.tsx src/components/scanner/`

6. **Dexie cache schema version**
   - File: `src/lib/offline-ticket-cache.ts`
   - Schema v2 with tables: `cachedTickets`, `cacheMetadata`, `offlineScans`, `deviceMeta`
   - On version bump: migration path must not drop `offlineScans` (pending syncs would be lost)

7. **Offline queue retry logic**
   - File: `src/lib/offline-queue-service.ts`
   - Must have exponential backoff with `shouldRetry()` gate
   - `syncStatus` values: `pending`, `synced`, `failed`, `conflict`
   - Max retry count — verify it's capped (infinite retry = battery drain)

8. **Heartbeat interval**
   - Scanner posts to `scanner_heartbeats` every 30-60s while active
   - Grep: `grep -rn "scanner_heartbeats\|sendHeartbeat\|HEARTBEAT_INTERVAL" src/`

9. **Event sourcing on ticket_events**
   - Every successful scan → INSERT to `ticket_events` (append-only audit log)
   - Verify: scanner calls `record_ticket_event` or direct INSERT path
   - Never updates existing `ticket_events` rows (immutable)

10. **VIP re-entry path**
    - Scanner calls `check_vip_linked_ticket_reentry` for linked GA tickets BEFORE the duplicate-check.
    - Without this order, legitimate VIP re-entries get rejected as "already scanned."

### Data-level invariants

Run `references/audit-queries.sql`. Expected: 0 rows unless noted.

### Audit output template

```
## Scanner Audit Report — [YYYY-MM-DD]

### Code-level
- [PASS/FAIL] Unsigned QR rejected
- [PASS/FAIL] Signature verify fail-closed
- [PASS/FAIL] No VITE_QR_SIGNING_SECRET in scanner bundle
- [PASS/FAIL] 2.5s scan cooldown active
- [FLAG] simple-scanner.ts vs scanner-service.ts duplication (pending consolidation)
- [PASS/FAIL] Dexie schema v2 intact
- [PASS/FAIL] Offline queue retry with backoff + cap
- [PASS/FAIL] Heartbeat posting every 30-60s
- [PASS/FAIL] ticket_events INSERTed on every scan (append-only)
- [PASS/FAIL] VIP re-entry checked BEFORE duplicate-check

### Data-level
- [PASS/FAIL] No scan_logs with NULL ticket_id for successful scans (query #1)
- [PASS/FAIL] No tickets marked checked_in without matching scan_log (query #2)
- [PASS/FAIL] No offline_scans stuck in 'pending' >7 days (query #3)
- [PASS/FAIL] No scanner_heartbeats gap >2h during event hours (query #4)
- [PASS/FAIL] No duplicate scan_logs for same ticket within 1s (query #5)
- [PASS/FAIL] No failed verify-qr-signature attempts spiking (query #6)
- [PASS/FAIL] scan_velocity_metrics within normal bounds (query #7)
- [PASS/FAIL] No fraud_detection_logs flagged unresolved (query #8)

### Failures
[List with file/line or SQL rows.]
```

---

## Mode: diagnose

### Step 1: Ask
- Scanner device ID / staff operator?
- Ticket ID or QR contents?
- What was the rejection message or unexpected behavior?
- Online or offline at the time?
- Which event?

### Step 2: Simple checks
- `SELECT * FROM tickets WHERE id = '<ticket_id>' OR qr_token = '<token>'` — does it exist, status, event match?
- `SELECT * FROM scan_logs WHERE ticket_id = '<id>' ORDER BY scanned_at DESC LIMIT 10`
- `SELECT * FROM scanner_heartbeats WHERE device_id = '<id>' ORDER BY last_heartbeat DESC LIMIT 5` — is the device online?

### Step 3: Match against incidents (see `references/incidents.md`)
- Valid ticket rejected → QR signature verify failed (network? wrong secret?)
- Invalid ticket accepted → cache stale or unsigned path slipped in
- Duplicate scan not caught → cooldown ref missed or DB race
- Offline scan didn't sync → `syncStatus='failed'` — read `errorMessage`
- Wrong event rejection → event auto-detect misfired

### Step 4: 3-file rule / Two-strike rule / Stay in scope — standard.

---

## Mode: scale-check

Before a major door night (1000+ tickets expected):

### 1. Pre-cache the event
- Did scanners pre-download all tickets for the event to Dexie?
- Check `cacheMetadata` for each device: `ticketCount` should ≈ sold tickets, `lastSyncAt` recent.

### 2. Network resiliency
- If the venue has spotty WiFi, offline queue must handle 2-5 minute outages without data loss.
- `syncPendingScans` — max retry count? exponential backoff ceiling?

### 3. Throughput at peak
- 500 scans in 15 min = ~33/min across all scanners.
- Per scanner: 5-10 scans/min is sustainable. >15/min per scanner → bottleneck.
- Staff training: one scanner per 2-3 door staff.

### 4. Scanner device battery
- `device_battery_logs` — are devices charged, monitored?
- Low battery = scanner restarts mid-event → loss of IndexedDB if user clears data (rare but possible)

### 5. Heartbeat alerts
- Dashboard must visibly flag any scanner with heartbeat >5 min old during event hours.

### 6. VIP pass capacity
- For VIP-heavy events, verify `check_vip_linked_ticket_reentry` performance under load (should be <50ms per call).

### 7. Emergency override path
- `emergency_override_logs` — is there a documented manual entry process for when scanner fails entirely?

### Output

```
## Scanner Scale Readiness — Event: [name], Tickets: [X], Scanners: [Y]

### Pre-cache status: [device list with last sync]
### Network resiliency: [queue capacity + backoff review]
### Peak throughput: [projected vs capacity]
### Device health: [battery, heartbeat]
### Dashboard monitoring: [heartbeat visibility]
### Emergency override documented: [YES/NO]

### Verdict: [READY / NOT READY]
```

---

## Critical Flow: Single scan, online

1. Camera captures QR or NFC tap → raw input string
2. Debounce: if same input within 2.5s, skip
3. `parseTicketPayload(input)`:
   - JSON? → extract `{token, signature, meta}`
     - No signature → REJECT "unsigned QR"
     - Has signature → call `/functions/v1/verify-qr-signature`
       - Valid → proceed
       - Invalid → REJECT "invalid signature"
       - Network error → REJECT "verification unavailable" (fail-closed)
   - Plain text → treat as manual-entry token, no verification (but needs DB match)
4. Lookup: `SELECT * FROM tickets WHERE qr_token = '...'`
5. Validation chain:
   - Ticket exists? → else REJECT "not found"
   - Event matches selected event? → else REJECT "wrong event"
   - Already scanned? → check `tickets.checked_in_at`:
     - NULL → proceed to check-in
     - NOT NULL → is this VIP-linked? `check_vip_linked_ticket_reentry`
       - allow_reentry=true → show VIP success overlay with table info, log re-entry
       - allow_reentry=false → REJECT "already scanned"
6. Mark checked-in: `UPDATE tickets SET checked_in_at = now() WHERE id = ...`
7. Log: INSERT `scan_logs`, INSERT `ticket_events`, UPDATE `scanner_heartbeats`
8. Show SuccessOverlay (1.5s auto-dismiss) + haptic + audio feedback

## Critical Flow: Single scan, offline

1-3. Same as online through signature check (local Dexie cache has pre-synced tickets)
4. Lookup: Dexie `cachedTickets` by qr_token
5. Validation: ticket exists in cache, event matches, NOT already marked scanned in local cache
6. Mark checked-in LOCALLY in Dexie, enqueue to `offlineScans` table (Dexie)
7. Scanner shows success overlay — defers server sync
8. On reconnect: `syncPendingScans()` batches pending → `sync_offline_scan` RPC → first-scan-wins conflict resolution

### Conflict resolution
- Scan A offline at 10:00, syncs 10:05
- Scan B offline at 10:02, syncs 10:03
- Server keeps the EARLIER client timestamp (10:00 wins), marks B as `conflict`
- Staff at door sees "legitimate first scan" — the second scan was the counterfeit attempt

---

## HARD RULES

- **NEVER write to prod DB** except through explicit RPCs and with user approval.
- **NEVER modify** `sync_offline_scan`, `scan_ticket_atomic`, or the HMAC verification without user approval + concurrency test.
- **NEVER accept unsigned QR codes.** Not "for testing", not "temporarily."
- **NEVER disable the cooldown** — it prevents operator double-taps from marking ghost entries.
- **NEVER mix `simple-scanner.ts` and `scanner-service.ts`** code paths. Pick one per scan type and stay there.
- **Branch workflow:** fix/... or feature/... branches. Never push scanner code directly to main before an event.
- **User reports override queries.** "I scanned it and it beeped green but dashboard says nothing" → trust the operator; trace the scan_logs + ticket_events for that device.

---

## What to Return

- **audit** → pass/fail report with failures rows + file locations
- **diagnose** → single repro + one-file fix or "need direction"
- **scale-check** → ready/not-ready + numbered must-fix list
