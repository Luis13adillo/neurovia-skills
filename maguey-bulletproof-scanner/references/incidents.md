# Scanner — Known Incidents & Fix Patterns

---

## Incident: Valid ticket gets rejected with "invalid signature"
**Symptom:** Customer has a real, just-purchased ticket. QR scans but scanner shows red with signature error.
**Root cause options:**
1. `app.qr_signing_secret` was rotated but some tickets still signed with old secret
2. Secret mismatch between Supabase DB setting and what `verify-qr-signature` Edge Function reads
3. Clock skew caused signature timing drift (rare — HMAC isn't time-based, but if we add TTL, it matters)

**Debug:**
```sql
-- Is secret configured?
SELECT current_setting('app.qr_signing_secret', true) IS NOT NULL AS secret_set;

-- Check a recent ticket's signature format (should be base64 HMAC, length ~44 chars)
SELECT id, qr_token, qr_signature, LENGTH(qr_signature) AS sig_len, created_at
FROM tickets WHERE id = '<ticket_id>';
```
**Fix:** if secret was rotated, re-sign all unscanned tickets via `sign_qr_token` RPC (WRITE operation — requires user approval). OR restore old secret temporarily and schedule re-signing during downtime.

---

## Incident: Counterfeit ticket accepted
**Symptom:** Customer enters with a screenshot of someone else's QR. Both parties now inside.
**Root cause:** Most likely the original customer sent the screenshot to a friend BEFORE they scanned. The "first scan wins" rule lets the first arrival check in; the second gets "already scanned." If both made it in, cooldown failed or `check_vip_linked_ticket_reentry` allowed re-entry without verifying VIP link.
**Debug:**
```sql
-- Who scanned this ticket and when?
SELECT * FROM scan_logs WHERE ticket_id = '<id>' ORDER BY scanned_at;
-- Was it flagged as re-entry?
SELECT * FROM ticket_events WHERE ticket_id = '<id>' ORDER BY created_at;
-- Was it linked to a VIP reservation?
SELECT * FROM vip_linked_tickets WHERE ticket_id = '<id>';
```
**Fix pattern:** if this happens often, consider requiring photo ID for re-entries or disabling re-entry entirely for GA (keep for VIP only).

---

## Incident: Scanner shows ticket already scanned but customer hasn't entered yet
**Symptom:** First-time scan shows "already scanned" red.
**Root cause options:**
1. Someone pre-scanned the QR from the customer's confirmation email (leaked QR image somehow)
2. Duplicate ticket row (query ticket_types.tickets_sold mismatch — escalate to tickets skill)
3. Dexie offline cache got populated with a stale `scanned=true` flag that didn't get cleared

**Debug:**
```sql
SELECT id, qr_token, checked_in_at, order_id FROM tickets WHERE qr_token = '<token>';
SELECT * FROM scan_logs WHERE ticket_id = '<id>' ORDER BY scanned_at DESC LIMIT 5;
```
If no scan_log rows but `checked_in_at` is set: the Dexie offline state was wrong; a WRITE to clear `checked_in_at` may be required (requires user approval; coordinate with Stripe/email to ensure customer isn't scammed).

---

## Incident: Offline queue stuck on one device
**Symptom:** One scanner shows "50 pending scans" that never clear even when back online.
**Root cause options:**
1. Device's anon key or auth token expired
2. `sync_offline_scan` RPC throwing error for all attempts (look at Edge Function logs)
3. Dexie corruption — check browser dev tools → Application → IndexedDB
4. `syncStatus='failed'` with `retry_count >= max` — manual sync button should reset

**Fix:** try a hard reload on the scanner (clears cached auth). If that fails, user taps "Force resync" in scanner settings (if implemented). Worst case: clear IndexedDB and re-download tickets — DATA LOSS of un-synced scans is the risk, only if device was 100% offline AND server didn't receive any scan from this device.

---

## Incident: Heartbeat drops but scanner is working
**Symptom:** Dashboard shows scanner "offline" but door staff confirms it's scanning fine.
**Root cause:** `scanner_heartbeats` write failing but scan writes succeeding. Likely RLS policy or network reliability issue on the heartbeat endpoint.
**Debug:** check `scanner_heartbeats` table's RLS policies. Also test if any heartbeats are coming through at all from that device_id.
**Workaround:** ignore dashboard status temporarily; rely on scan log activity as proof of life.

---

## Incident: Wrong event auto-detected
**Symptom:** Scanner opens with wrong event pre-selected. Staff rejects valid ticket thinking wrong event.
**Root cause:** `getActiveEvents()` returned multiple events for tonight (overlapping dates?) and the wrong one got selected.
**Fix:** in `Scanner.tsx` line ~160-161: prefer exact date match + status='active'. If multiple, show a picker instead of auto-selecting.

---

## Incident: VIP re-entry treated as duplicate
**Symptom:** VIP guest stepped outside for a cigarette, comes back, scanner rejects.
**Root cause:** Scanner flow checked duplicate BEFORE VIP link check. Should be:
1. Parse + signature verify
2. Ticket lookup
3. Event match
4. **VIP link check** (via `check_vip_linked_ticket_reentry`) — if allow_reentry=true, success
5. If not VIP-linked: duplicate check → reject if scanned

**Fix:** verify order in `simple-scanner.ts`. Line-number drift over refactors can put the VIP check in the wrong order.

---

## Incident: Two scanner codepaths (simple-scanner.ts vs scanner-service.ts) diverge
**Symptom:** Different scan UX in different parts of the app (e.g., manual entry uses scanner-service, camera uses simple-scanner).
**Root cause:** legacy `scanner-service.ts` not fully consolidated.
**Current state:** TODO per MEMORY.md. Both files contain similar logic.
**Fix:** long-term, consolidate into simple-scanner.ts. Short-term, ensure any bug found in one is patched in both (or document the divergence).

---

## Incident: Conflict resolution rejected the real first scanner
**Symptom:** Client A was the legit first arrival but server recorded Client B's scan first (network race).
**Root cause:** `sync_offline_scan` uses SERVER-received timestamp for first-scan-wins. If A synced after B, A loses.
**This is by design** to prevent client clock manipulation. The correct guidance:
- Scanners should sync as quickly as possible after scanning (retry aggressive)
- Staff should refuse entry if "already scanned" unless they eyeball the person (rare edge case)

**Alternative design (requires approval):** switch to client-provided timestamp with server validation (must be within a sane window of server time). Trade-off: customer clock-skew attacks become possible.

---

## Incident: Dexie cache didn't pre-populate before event
**Symptom:** Event night, scanner goes offline (venue WiFi dies), scanner can't validate anyone.
**Root cause:** scanner wasn't opened + connected before the event to trigger cache population. `cacheMetadata` shows `lastSyncAt` stale.
**Fix:** operational — staff must open scanner app + connect to venue WiFi ≥30 min before doors open. Adding a "Pre-cache event" button in admin would make this bulletproof.

---

## Incident: Fraud detection flags a legitimate operator
**Symptom:** Same staff member scans 100 tickets fast → flagged as velocity anomaly.
**Root cause:** velocity_score threshold too low for real-world door rates.
**Fix:** tune `scan_velocity_metrics` threshold (requires understanding the calculation — check the migration). OR add per-operator exemptions.
