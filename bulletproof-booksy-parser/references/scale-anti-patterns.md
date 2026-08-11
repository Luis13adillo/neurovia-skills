# Scale Anti-Patterns — Adapting the Booksy Parser to All Barbers

The parser was born serving a handful of barbers. Rolling it out across 10+ barbers at 4 locations surfaces assumptions that worked quietly and now must scale. This file catalogs those assumptions AND the things that must NOT change under pressure.

Read before onboarding a new barber to Booksy sync, before adding a new location, or before a language/template migration.

---

## 1. Hardcoded English-only assumptions elsewhere in the codebase

Symptom risk: a barber with Spanish-locale Booksy syncs fine into `external_calendar_events`, but some downstream surface (analytics, email confirmations, a log viewer) displays English-only labels where the service name should render in Spanish.

Grep for:
```bash
grep -rn "Booksy:\|imported from Booksy" src/
grep -rn "source.*booksy" src/
```
Review each hit for hardcoded English strings that would read awkwardly for a Spanish-speaking barber. The parser itself is language-neutral; UI chrome often isn't. Flag, don't fix, without a UX call.

---

## 2. Per-barber `booksy_sync_email` silos

Each barber has ONE forwarding address. Adding a second Booksy account (e.g., barber manages both a personal and a shared MT-branded profile on Booksy) would break the lookup — the webhook matches `booksy_sync_email` as a single-column unique field.

Check before onboarding:
- Does this barber own or receive Booksy emails at MULTIPLE addresses?
- If yes, current model forces them to pick one OR forward both through the same MT-side virtual inbox.

Structural fix (do not build preemptively): junction table `barber_booksy_aliases(barber_id, email)`. Only if multiple barbers genuinely hit this wall.

---

## 3. Shared Gmail account anti-pattern

Some shops have a single `shop-booksy@gmail.com` that forwards all barbers' appointments. This COMPLETELY breaks the system — every email routes to the same `booksy_sync_email` and the webhook has no way to know which barber it belongs to.

Rule: every barber using Booksy sync must have their own email account receiving Booksy emails, forwarded to their own per-barber MT-side virtual address.

If a shared inbox is unavoidable, the correct solution is to parse the "Barber" field from the Booksy email body and match against a barber name mapping — but that's a NEW feature, not a patch. Propose via `gsd:plan-phase`.

---

## 4. Gmail forwarding silently breaks monthly

Google periodically requires re-verification of forwarding rules. Without it, forwarding silently stops. The webhook logs show silence, not error.

Mitigation already in place:
- Query #10 in `audit-queries.sql` surfaces "last-seen" gaps.
- Owner dashboard's Booksy logs viewer paginates `booksy_sync_logs`.

Scaling pressure: as the barber count rises, manually scanning for dead forwarders doesn't scale. Future work (flag, don't build): automatic staleness alert when a `booksy_sync_enabled=true` barber has no successful log in 7 days.

---

## 5. Resend inbound is per-domain, not per-recipient

Resend's inbound email service receives all addresses ending in a single configured domain (e.g., `*@mt.booksy-sync.mtbarbershop.com`). Every barber's virtual address hits the same webhook endpoint, which then routes by `to` address.

This is fine today. Pressure points if volume spikes:
- Single-endpoint serverless function has a latency envelope. A spike of, say, 100 inbound emails in a minute (unlikely but possible on a busy Saturday) can queue.
- Webhook timeouts cause Resend retries — which re-post the SAME `message_id`. Current UNIQUE constraint absorbs this, but ONLY if the original insert completed. If the function times out MID-insert, retry may succeed and look like a single event; still idempotent.

Rule: never relax the `message_id` UNIQUE constraint even if "duplicates seem easy to dedup in code later."

---

## 6. Location inference via `barber_schedules` for APPOINTMENTS (not current clock-in)

Booksy emails don't carry a location. When converting to a booking, `from-external/route.ts` calls `resolveBarberLocation(mode='appointment', date)` which reads `barber_schedules` by `day_of_week`.

Load-bearing assumptions:
- The barber HAS a `barber_schedules` row covering the appointment's day.
- That row's `location_id` reflects reality — i.e., the barber actually works at that location that day.

Failure modes at scale:
- A barber who works at two locations on the same day (morning here, afternoon there) — today's schedule model is single-location-per-day. The appointment lands at whichever location the schedule names first.
- A barber without any `barber_schedules` row → convert-to-booking fails with "no location."

Mitigation: invariant #11 in `invariants.md` surfaces barbers without schedule coverage. Run before every Booksy-rollout rollout.

---

## 7. `barber_custom_services` as the only match target

Per `bulletproof-services` skill and deprecation rule (MEMORY.md), `barber_services` is deprecated and blocked by a DB trigger. `from-external/route.ts` reads ONLY `barber_custom_services`.

Scaling risk: a new barber joining Booksy sync without pre-populated custom services sees 100% convert-to-booking failure. Invariant #11 surfaces this; onboarding checklist should make custom-service setup a prerequisite, not a follow-up.

Do NOT fall back to the global `services` table on no-match. That tempted a short-cut PR once; it would break the owner's "each barber can charge their own price" model.

---

## 8. Timezone assumption: all locations are in America/New_York

Today, all 4 locations are Eastern Time (3 DE + 1 PA). The parser uses `America/New_York` universally. If MT opens a location in a different zone (Texas, Florida-Central Time, etc.):
- `parseDateTime()` / `parseDateTimeSpanish()` still assume Eastern.
- The round-trip verification would MIS-detect the correct offset.

Would require a per-location timezone column AND a parse-time lookup that knows which barber = which location. Do NOT attempt preemptively — flag during location expansion planning.

---

## 9. Rate-limit and retry pressure on `/api/bookings/from-external`

Today this is a manual-click endpoint. If the owner chooses to batch-convert a backlog of 50 Booksy events, 50 rapid POSTs hit the route.

- Each POST writes 1-2 bookings (father+son).
- Each booking insert triggers realtime + notification + `service_transactions` trigger.

At 50 concurrent, this won't fall over but will slow. More importantly: the route does NOT have rate-limiting. Mass batch could interact poorly with the `bookings_no_time_overlap` constraint — if the user clicks "convert" on two overlapping Booksy events in rapid succession, ONE insert will win and the other return an error. The event that loses remains `status='confirmed'` in `external_calendar_events` — a ghost.

Mitigation: before a mass conversion, advise the user to resolve overlaps manually, or add rate-limiting + queued batch endpoint as a separate feature (NOT a hotfix).

---

## 10. Service-block extraction against template drift

Booksy refreshes email templates roughly every 6-9 months. Each refresh has historically broken ONE of:
- Service block extraction (fewer/more blocks than actual).
- Client info box color (`#f4f4f4` → a slightly different hue).
- Time range format (added seconds, changed separator).

Today the code deals with these via regex updates. At scale:
- A broken template silently skips ~20 emails/day across all barbers before someone notices.
- The fast signal is query #12 in `audit-queries.sql` (parse failure rate over 7 days).

Proposal for scale (flag, don't build): add a cron that alerts the owner when the failure rate exceeds 5%. Today it's eyeballed.

---

## 11. `#f4f4f4` hex as a structural signal

The parser relies on the exact color `#f4f4f4` to identify the client info box. If Booksy ever changes this one hex value, client-info extraction silently falls back to less-reliable strategies (title tag, subject line). Symptoms: right service and time, wrong or missing client name/phone.

Audit before template-refresh work:
```bash
grep -rn "f4f4f4" src/lib/booksy/
# Expected: one location, inside extractClientInfoBox().
```

If Booksy shifts the shade, update the regex to a tolerant family (e.g., `/#f[0-9a-f]{5}/i` bounded to the expected CSS context). Do NOT remove the color anchor — pure structural heuristics produce worse false matches.

---

## 12. ±5 min, ±30 min, ±2 min windows are load-bearing

Three distinct windows live in the code:
- **±5 min** — reschedule match (previousStartTime + clientName) and cancel match (clientName + startTime, clientPhone + startTime). Tolerant of minor clock drift between Booksy and MT.
- **±30 min** — reschedule fallback by clientName alone. Avoids matching the wrong day's appointment.
- **±2 min** — multi-block dedup. Avoids treating the same appointment as new when the webhook fires twice inside a single email.

Changing ANY of these requires evidence (logs showing actual drift or actual false positives). It is NOT a dial to tune casually. Today's values are the result of production tuning.

---

## 13. Not-yet-hardened: barber offboarding

If a barber leaves MT:
- Today: flip `barbers.is_active = false` and/or `booksy_sync_enabled = false`.
- `external_calendar_events` rows remain, pointing at an inactive barber. Query #7 surfaces this.
- Pattern #6 in `fix-patterns.md` ensures the webhook skips inactive barbers.

What's NOT done:
- Logs table retention policy. `booksy_sync_logs` grows unbounded.
- No pruning of `external_calendar_events` for inactive barbers.
- No documented rotation of `booksy_sync_email` after offboarding (the forwarding address should be un-verified in Resend to prevent accidental re-use).

Not bugs today. At 20+ barbers with turnover, these become real. Flag during scaling review; do not build preemptively.

---

## 14. What MUST NOT change under scaling pressure

The temptation as volume grows: "simplify" the parser to one path, or auto-merge duplicates, or drop "edge-case" match strategies. Resist. These are the load-bearing rules that keep appointments aligned with reality:

- Reschedule and cancel match strategies run in a SPECIFIC ORDER. Earlier strategies are more precise; later strategies catch edge cases. Reordering or removing ANY one strategy will reintroduce bugs that took weeks to find originally.
- The EDT-first DST round-trip fallback is an explicit choice during the fall-back 1–2 AM overlap hour. Picking EST silently would break appointments that specific Sunday.
- `message_id` UNIQUE at the DB layer is non-negotiable. Application-level dedup is not sufficient under Resend retry pressure.
- `status='confirmed'` filters on the calendar hook AND availability API are LOAD-BEARING. Missing even one filter = cancelled Booksy appointments blocking real slots.
- Service matching must stay on `barber_custom_services` only. Never fall back to the global `services` table.

When in doubt, propose a change, wait for user approval, and run the full audit before and after.
