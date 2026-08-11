# Services Scale Anti-Patterns

Run in `scale-check` mode. Report-only — never auto-fix. Triggers:
- Adding a new location
- Launching a bulk service price change or new service menu
- Onboarding a cohort of new barbers

---

## 1. Inactive-services cruft

```sql
SELECT id, name, created_at, category
FROM services
WHERE is_active = false
ORDER BY created_at;
```

Known cruft (seed artifacts from initial setup, verified 2026-04-21):
- `sample cut` — test row
- `Zero-Point Fade`, `Executive Protocol`, `Standard Cut`, `Buzz Cut`, `Junior Protocol`, `Beard Sculpt`, `Beard Trim`, `Hot Towel Shave`, `Total System Reset`, `Cut + Beard Trim`, `Hair Design`, `Color Service` — 12 seed rows from `c0010000-...` through `c0120000-...`.

Report them as "safe to prune before scale." Do not delete without explicit user approval.

---

## 2. Category enum drift

```sql
SELECT DISTINCT category FROM services WHERE category IS NOT NULL;
```

Documented enum (from `src/lib/hooks/useServices.ts` `servicesByCategory` logic):
- `haircuts`, `beard`, `combos`, `grooming`, `linework`, `specialty`, `color`, `treatments`, `addons`
- Legacy aliases: `hair` (maps to haircuts), `combo` (maps to combos)

Flag anything outside this set — a barber may have typed a new category that no UI filter handles.

---

## 3. Duration range sanity

```sql
SELECT id, name, duration_minutes, 'services' AS src FROM services
WHERE is_active = true AND (duration_minutes < 10 OR duration_minutes > 180)
UNION ALL
SELECT id, name, duration_minutes, 'custom' FROM barber_custom_services
WHERE is_active = true AND (duration_minutes < 10 OR duration_minutes > 180);
```

< 10 min: too short for any real cut; sub-slot bookings confuse the calendar.
> 180 min: holds a chair hostage; verify intentional (extensive color/restoration work).

---

## 4. Uniform walk-in pricing check

When adding a new location, MT's HARD RULE is that walk-in services are uniform across all barbers AND all locations. There is NO per-location price override on `services`. If the new location should have different walk-in prices, the architecture needs a conversation BEFORE the location goes live — it is not a simple schema tweak.

---

## 5. Custom service duplication (consolidation candidates)

```sql
SELECT lower(trim(name)) AS name_key,
       COUNT(DISTINCT barber_id) AS barber_count,
       array_agg(DISTINCT price) AS prices,
       array_agg(DISTINCT duration_minutes) AS durations
FROM barber_custom_services
WHERE is_active = true
GROUP BY lower(trim(name))
HAVING COUNT(DISTINCT barber_id) > 1
ORDER BY barber_count DESC;
```

If 3+ barbers have an identical "Kids Haircut" custom service at different prices, consider promoting it to a global `services` row and letting each barber override via `barber_services.custom_price`. Cleaner reports, simpler admin.

---

## 6. Upsell rule reachability

```sql
SELECT ur.id, ur.trigger_service_id, ur.suggested_service_id
FROM upsell_rules ur
LEFT JOIN services ts ON ts.id = ur.trigger_service_id
LEFT JOIN services ss ON ss.id = ur.suggested_service_id
WHERE ur.is_active = true
  AND (ts.is_active = false OR ss.is_active = false);
```

Silent failure: an upsell rule referencing an inactive service never triggers at Post-Service Flow. Either reactivate the service or disable the rule.

---

## 7. SMS/email template service-name coupling

```bash
grep -rn "service_name\|{service}\|{{service" src/lib/email/ src/lib/twilio/ src/app/api/bookings/
```

Templates must read the service name FRESH from the booking row (stored copy), not hardcode a specific service's name. Any hardcoded reference is a bug — if the service is renamed, the template silently shows the old name.

---

## 8. Stripe payment link pricing

```bash
grep -rn "service\.price\|services\.price" src/app/api/stripe/ src/app/api/payment-link/ src/app/api/payments/ 2>/dev/null
```

Expected: zero matches. Payment links must use `booking.service_amount` or `booking.total_amount` (stored at creation), not a live service re-fetch. A live re-fetch could mid-flow the amount if the owner is editing prices concurrently — in the worst case, the customer gets a different price than they agreed to.

---

## 9. Hardcoded service IDs or names in app code

```bash
grep -rEn "'Men.{0,2}s Haircut'|\"Men.{0,2}s Haircut\"|'Fade & Beard'|'Shape Up'" src/
```

Services are data. Any component, hook, or utility that branches on a specific service name is brittle — renaming the service breaks logic silently. Flag for review.

---

## 10. Service-related migrations drift

```bash
ls supabase/migrations/ | grep -iE "service"
```

Expected:
- `20260306223406_create_barber_custom_services.sql`
- `20260421030000_fix_bookings_service_id_cascade.sql`

If additional service-affecting migrations exist, audit them for any schema change that may have reset RLS, FKs, or duration defaults.

---

## 11. RLS regression check

```sql
SELECT c.relname, c.relrowsecurity
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('services', 'barber_services', 'barber_custom_services');
```

All three must show `relrowsecurity = true`. If any shows false, someone ran `ALTER TABLE ... DISABLE ROW LEVEL SECURITY` and forgot to re-enable — fix before scale.

---

## 12. Cross-dashboard UI mirror drift

```bash
diff <(sed -n '/Services tab/,/^}/p' src/app/\(dashboard\)/barber/settings/page.tsx 2>/dev/null) \
     <(sed -n '/page/,/^}/p' src/app/\(dashboard\)/dashboard/my-chair/services/page.tsx 2>/dev/null) \
     | head -80
```

Not a byte-perfect diff, but a structural comparison. Features that live on one page but not the other are mirror drift — apply the fix to both (Cross-Dashboard Mirroring Rule).

---

## 13. `barber_custom_services` type assertions

```bash
grep -rn "barber_custom_services" src/ | grep -v "as any" | grep -iE "from\(|update\(|insert\(|delete\("
```

Every server-side write to `barber_custom_services` needs the `(supabase as any)` cast OR the types need to be regenerated. Any TS error on build means the cast was removed without the regen.

---

## Output verdict template

```
## Services Scale Readiness — [trigger]

### Safe
- [list green items]

### Must fix before go-live
1. [file:line or SQL result] — [reason]

### Recommended (not blocking)
- [cleanup/optimization suggestions]

### Verdict
[READY / BLOCKED BY N ITEMS]
```
