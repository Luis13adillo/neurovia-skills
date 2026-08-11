# Parser Languages — English + Spanish

The Booksy parser lives in `src/lib/booksy/parser.ts`. It's a single code path that supports BOTH English and Spanish Booksy emails. Language is detected from the subject line. Each language has its own date/time helper; everything else is shared.

This reference exists so a fix/audit in one language doesn't silently break the other.

---

## Email types and subject keywords

The detection switch in `parseBooksyEmail()` maps subject text to a `type` enum: `'new' | 'rescheduled' | 'cancelled' | 'gmail_verification' | 'unknown'`. Keywords are matched case-insensitively against the subject.

### type: 'new'

**English keywords** (any one triggers):
- "new appointment"
- "new booking"
- "booking confirmation"

**Spanish keywords** (any one triggers):
- "nueva reserva"
- "nueva cita"
- "confirmación de reserva"

### type: 'rescheduled'

**English keywords:**
- "changed his booking" / "changed her booking" / "changed their booking"
- "rescheduled"
- "rescheduled appointment"
- "confirmed the new appointment time"  ← proposal accepted; treat as reschedule

**Spanish keywords:**
- "cambió" (e.g., "cambió su cita")
- "cambiada"
- "ha cambiado"
- "modificó"
- "reprogramada"
- "reprogramado"

### type: 'cancelled'

**English keywords:**
- "cancelled appointment" / "canceled appointment"  ← British + American spelling both required
- "booking cancelled" / "booking canceled"

**Spanish keywords:**
- "canceló"
- "cancelada"
- "ha cancelado"
- "cancelación"

### type: 'gmail_verification'

Subject contains a verification-code pattern from Google/Gmail. No action needed for appointments — the parser returns a code string and the webhook acknowledges it.

**Keywords (both languages):**
- "Gmail Forwarding Confirmation"
- "Confirmación de reenvío de Gmail"
- Subject containing a 9-digit code with "(#code)"

### type: 'unknown' (rejected / skipped)

Explicitly bail out (don't insert or update anything):
- English "rejected the new appointment" — barber declined a client's reschedule proposal; do nothing.
- Spanish "rechazó" equivalents.

Any subject that matches none of the above → `type: 'unknown'` → logged to `booksy_sync_logs` with `parse_status='skipped'`.

---

## Date + time parsing

Two helpers, one per language. Both convert `(dateStr, timeStr)` → UTC `Date` with EDT/EST verification.

### English: `parseDateTime(dateStr, timeStr)`

- Accepts 12-hour times: "10:30 AM", "2:00 PM", "12:15 PM".
- Accepts dates like "Fri, Dec 5, 2025", "December 5, 2025", "12/5/2025".
- Algorithm:
  1. Build a naive `Date` from the parsed parts.
  2. Compute two UTC candidates: one assuming EDT (UTC-4), one assuming EST (UTC-5).
  3. For each candidate, format it through `Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', ... })` and check the resulting wall-clock matches `dateStr + timeStr`.
  4. Return the candidate that round-trips. If both do (DST-boundary edge case) OR neither does, fall back to EDT.

### Spanish: `parseDateTimeSpanish(dateStr, timeStr)`

- Accepts 24-hour times: "14:30", "09:05".
- Accepts dates like "vie, 5 dic 2025", "5 de diciembre de 2025", "05/12/2025" (DD/MM/YYYY — Spanish format!).
- Spanish month abbreviation map: `ene|feb|mar|abr|may|jun|jul|ago|sep|oct|nov|dic`.
- Same EDT/EST round-trip verification as English.

Both helpers must return a UTC `Date` object or `null` on parse failure. Never return a naive local `Date` — that will drift 4 or 5 hours the moment Vercel reads it.

---

## Client info extraction

Shared across languages. Booksy wraps client info in a gray box with background color `#f4f4f4`. The box contains name, phone, and email in a consistent label/value format — language of the label doesn't matter because the parser pattern-matches on structure, not words.

Fallback chain if the gray box is missing:
1. `<title>` tag.
2. Bold text near "Client:" / "Cliente:".
3. Subject line pattern (e.g., "New appointment: Jane Doe").
4. First line of plain-text body.

---

## Service name extraction

Shared. Service names appear in bolded `<strong>` tags within a tabular layout. The parser normalizes curly quotes (`"` / `"`) to straight quotes (`"`) so matching against `barber_custom_services` works regardless of email encoding.

Price extraction falls back in this order:
1. Formatted "$XX.XX" next to the service.
2. Bold service text containing a `$`.
3. Default of 0 if absent.

---

## Multi-appointment emails

`extractServiceBlocks()` splits a single email into one logical block per service. Common when a parent books themselves + a kid in one transaction. Each block becomes one `external_calendar_events` row with its own `message_id#N` suffix.

Language-agnostic — the split is driven by HTML structure (repeated service rows), not keywords.

---

## Extending to a new language

If a barber somewhere adopts a Booksy locale we don't support (e.g., Portuguese, French):

1. Add keyword groups to the type-detection switch in `parseBooksyEmail()` — new, rescheduled, cancelled, verification.
2. Add a new helper `parseDateTimeXX(dateStr, timeStr)` that mirrors the EDT/EST round-trip pattern from `parseDateTimeSpanish()`.
3. Add a month abbreviation map for the new language.
4. Add at least one unit test per type (new / rescheduled / cancelled) to `tests/unit/booksy-parser.test.ts`.
5. Run `npx tsx tests/unit/booksy-parser.test.ts` and confirm all existing tests still pass.

Do NOT extend by string-matching inside existing English helpers. That has silently broken Spanish in the past because of overlapping words (e.g., "appointment" fragments appearing in otherwise-Spanish bodies).

---

## Known tricky cases

- **English email in a Spanish subject** (barber has Spanish Booksy locale but their Google account is English): the subject determines language path. Today the parser trusts the subject — if body language differs, client-info fallback chain still works because it's structural. Keep it that way.
- **DST boundary** (2 AM ET doubled on fall-back Sunday): the round-trip verifier picks EDT first; on fall-back day, both offsets may round-trip, and EDT wins. Acceptable for now. Flag if a barber reports a wrong time on the first Sunday of November.
- **Confirmed proposals** (client proposed a new time, barber accepted): subject often lacks "changed" but includes "confirmed the new appointment time". These MUST map to `type: 'rescheduled'` — not `'new'` — otherwise the old event never gets updated.
- **Rejected proposals** (barber declined): subject includes "rejected the new appointment" or Spanish equivalents. These MUST map to `type: 'unknown'` and be skipped — there's nothing to insert, update, or cancel.
