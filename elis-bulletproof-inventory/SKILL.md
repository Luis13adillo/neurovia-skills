---
name: elis-bulletproof-inventory
description: Audit, diagnose, or scale-check the Eli's Dulce Tradicion products + ingredients + recipes system (src/lib/api/modules/products.ts, src/lib/api/modules/inventory.ts with deductInventoryForOrder + logIngredientUsage + getLowStockItems, src/components/dashboard/MenuManager.tsx owner CRUD, src/components/dashboard/InventoryManager.tsx, src/components/kitchen/FrontDeskInventory.tsx live panel with inventory-health-monitor realtime channel, src/pages/Menu.tsx customer-facing, FALLBACK/MOCK_PRODUCTS, product_recipes + order_component_recipes tables, migration 20260211_recipe_engine.sql, order_form_options for cake_sizes + bread_types + cake_fillings + premium_filling_upcharges). Use when the customer menu shows a cake that doesn't exist, ingredient quantities drift, low-stock alerts don't fire, deductInventoryForOrder silently no-ops, or before onboarding new cake variants. Read-only SQL via mcp__supabase__execute_sql (project rnszrscxwkdwvvlsihqc). Never writes to production DB. Never modifies inventory code without explicit user approval.
---

# Eli's Bulletproof Inventory

The menu is what customers see. The ingredients are what the kitchen runs on. If they drift apart, the customer orders something the kitchen can't make, or the kitchen runs out silently mid-week. This skill guards both surfaces.

This skill covers:
- `src/lib/api/modules/products.ts` — `getProducts`, `getAllProducts`, `createProduct`, `updateProduct`, `deleteProduct` (soft-delete via `is_active=false`)
- `src/lib/api/modules/inventory.ts` — `getInventory`, `updateIngredient`, `deductInventoryForOrder`, `logIngredientUsage`, `getLowStockItems`
- `src/components/dashboard/MenuManager.tsx` — owner CRUD
- `src/components/dashboard/InventoryManager.tsx` — owner ingredient management
- `src/components/kitchen/FrontDeskInventory.tsx` — live panel (realtime channel `inventory-health-monitor`)
- `src/pages/Menu.tsx` — customer-facing menu
- `src/components/order/steps/orderStepConstants.ts` — `FALLBACK_*` hardcoded sizes / fillings / breads
- `src/components/order/steps/SizeStep.tsx` / `FlavorStep.tsx` — where order options surface
- Tables: `products`, `ingredients`, `ingredient_usage`, `product_recipes`, `order_component_recipes`, `cake_sizes`, `bread_types`, `cake_fillings`, `premium_filling_upcharges`, `order_form_options`
- Migrations: `20260211_recipe_engine.sql`, `20260402_order_form_options.sql`

**Not covered here:**
- Owner dashboard chrome around MenuManager/InventoryManager → `elis-bulletproof-dashboard`
- Pricing computation from these tables → `elis-bulletproof-orders`
- Kitchen display order cards → `elis-bulletproof-frontdesk`

---

## The two inventory domains (keep straight)

1. **Configurator** (the order wizard): `cake_sizes`, `bread_types`, `cake_fillings`, `premium_filling_upcharges`, `order_form_options`. These drive what the customer *can pick*. Read-heavy, public-readable.
2. **Operations** (what the kitchen has): `ingredients`, `ingredient_usage`, `product_recipes`, `order_component_recipes`. These drive *what gets consumed per order*. Write-heavy (on order transitions), owner-managed.

Failure patterns come from confusing these or letting them drift out of sync.

---

## Known gaps (flag every audit — CLAUDE.md)

- **Recipe management UI not built.** `product_recipes` and `order_component_recipes` tables exist. There is no admin UI to create / edit recipes. Without seeded recipes, `deductInventoryForOrder` silently no-ops.
- **Mock fallback in products.ts.** If the `products` table is empty (or the request fails), the customer menu shows MOCK_PRODUCTS. Real menu may differ.
- **Pricing fallback constants in orderStepConstants.ts.** If `cake_sizes` / `bread_types` / `cake_fillings` are empty, the wizard falls back to hardcoded values. Any real price change in the DB is masked.

---

## Mandatory Preflight

1. `/Users/luismiguel/Desktop/elis-dulce-tradicion/CLAUDE.md` — Known Issues: "Recipe management UI not built", "Pricing hardcoded in Order.tsx".
2. Supabase project `rnszrscxwkdwvvlsihqc`.
3. State: "Preflight complete. Running [mode]."

---

## Choose a Mode

- **audit** — monthly + before any menu change or price update
- **diagnose** — "menu shows wrong thing" / "inventory is wrong" report
- **scale-check** — adding a new cake line, bread type, or ingredient

---

## Mode: audit

### Code-level invariants

1. **`getProducts` does NOT silently return MOCK_PRODUCTS in prod.**
   - Grep: `grep -n "MOCK_PRODUCTS\|fallback" src/lib/api/modules/products.ts`
   - The fallback may mask an empty / unavailable products table. Ideally: in prod, fall through to a visible error banner, not silent mocks.
   - Query: `SELECT COUNT(*) FROM products WHERE is_active=true;` — if 0 in prod, Menu.tsx is entirely mocks.

2. **`deleteProduct` is soft-delete only.**
   - Grep: `grep -n "deleteProduct\|is_active" src/lib/api/modules/products.ts`
   - Hard delete breaks referential integrity with `order_component_recipes` + any historical orders referencing the product.

3. **`updateIngredient` writes `last_updated` and respects non-negative quantity.**
   - Grep: `grep -n "last_updated\|quantity" src/lib/api/modules/inventory.ts`
   - Negative inventory quantity is a data bug — the UI or RPC must clamp at 0.

4. **`deductInventoryForOrder` has a visible no-op path when recipes are missing.**
   - Expected: if no recipe exists for an order's component, the function should log a warning, not silently succeed.
   - Grep: `grep -n "product_recipes\|order_component_recipes\|console.warn\|logger" src/lib/api/modules/inventory.ts`

5. **`logIngredientUsage` is idempotent OR called exactly once per status transition.**
   - If status goes `confirmed → in_progress` twice (double-tap, two devices), deduction should fire only once.
   - Grep: `grep -n "deductInventoryForOrder\|in_progress" src/hooks/useRealtimeOrders.ts src/components/kitchen/*.tsx supabase/migrations/20260206_order_status_transition_rpc.sql`
   - If the RPC guards the transition, double-fire is prevented at DB level.

6. **`getLowStockItems` query matches InventoryManager + FrontDeskInventory expectations.**
   - Return set: rows where `quantity <= low_stock_threshold`.
   - Grep: `grep -n "getLowStockItems\|low_stock_threshold" src/lib/api/modules/inventory.ts src/components/kitchen/FrontDeskInventory.tsx`

7. **Customer menu (`Menu.tsx`) filters by `is_active=true` + matches what Order wizard offers.**
   - If MenuManager shows Red Velvet as active but `cake_fillings` has no Red Velvet filling, the customer picks it at /menu and fails at checkout.
   - Cross-check by hand: `SELECT name_en FROM products WHERE is_active=true;` vs. `SELECT name FROM cake_fillings WHERE is_active=true;`

8. **Recipe tables are non-empty if the owner intends inventory deduction.**
   - Query: `SELECT COUNT(*) FROM product_recipes; SELECT COUNT(*) FROM order_component_recipes;`
   - If both 0, `deductInventoryForOrder` is purely ornamental. Flag to owner.

9. **FrontDeskInventory's realtime channel doesn't leak.**
   - `FrontDeskInventory.tsx:74` — `supabase.channel('inventory-health-monitor')`.
   - Cleanup: component must call `supabase.removeChannel(channel)` on unmount.
   - Grep: `grep -n "removeChannel\|useEffect" src/components/kitchen/FrontDeskInventory.tsx`

10. **Pricing fallbacks in `orderStepConstants.ts` are NOT used as the canonical source in prod.**
    - Grep: `grep -n "FALLBACK\|DEFAULT_" src/components/order/steps/orderStepConstants.ts`
    - The fallback is fine as a safety net, but the normal path must fetch from `cake_sizes` / `bread_types` / `cake_fillings` / `premium_filling_upcharges` / `order_form_options`.

### Data-level invariants

```sql
-- I1. Active product count
SELECT COUNT(*) FROM products WHERE is_active=true;

-- I2. Empty order-option tables (wizard fallback risk)
SELECT 'cake_sizes' AS tbl, COUNT(*) FROM cake_sizes
UNION ALL SELECT 'bread_types', COUNT(*) FROM bread_types
UNION ALL SELECT 'cake_fillings', COUNT(*) FROM cake_fillings
UNION ALL SELECT 'premium_filling_upcharges', COUNT(*) FROM premium_filling_upcharges
UNION ALL SELECT 'order_form_options', COUNT(*) FROM order_form_options;

-- I3. Ingredients with quantity <= threshold (what the owner should see)
SELECT id, name, category, quantity, low_stock_threshold
FROM ingredients
WHERE quantity <= low_stock_threshold
ORDER BY (quantity::float / NULLIF(low_stock_threshold,0)) ASC;

-- I4. Negative or NULL ingredient quantities
SELECT id, name, quantity FROM ingredients WHERE quantity IS NULL OR quantity < 0;

-- I5. Orphan recipe rows (reference non-existent product or ingredient)
SELECT 'product_recipes' AS tbl, pr.id
FROM product_recipes pr
LEFT JOIN products p ON p.id = pr.product_id
LEFT JOIN ingredients i ON i.id = pr.ingredient_id
WHERE p.id IS NULL OR i.id IS NULL
UNION ALL
SELECT 'order_component_recipes', ocr.id
FROM order_component_recipes ocr
LEFT JOIN ingredients i ON i.id = ocr.ingredient_id
WHERE i.id IS NULL;

-- I6. Ingredient usage in last 30 days
SELECT DATE_TRUNC('week', created_at) AS week, SUM(quantity_used) AS used, COUNT(*) AS entries
FROM ingredient_usage
WHERE created_at > now() - interval '30 days'
GROUP BY week ORDER BY week;

-- I7. Orders transitioned to in_progress in last 7d vs. usage entries (deduction coverage)
WITH inprog AS (
  SELECT COUNT(DISTINCT order_id) AS n
  FROM order_status_history
  WHERE status='in_progress' AND created_at > now() - interval '7 days'
), usage AS (
  SELECT COUNT(DISTINCT order_id) AS n
  FROM ingredient_usage WHERE created_at > now() - interval '7 days'
)
SELECT inprog.n AS orders_started, usage.n AS orders_deducted FROM inprog, usage;
-- If orders_deducted << orders_started, recipe gap is confirmed.

-- I8. Ingredients never used (either not seeded in recipes, or legitimately unused)
SELECT i.id, i.name FROM ingredients i
LEFT JOIN ingredient_usage u ON u.ingredient_id = i.id
WHERE u.id IS NULL
LIMIT 20;

-- I9. Products referenced by historical orders but inactive today (cancel-during-queue risk)
SELECT DISTINCT p.id, p.name_en, p.is_active
FROM products p
WHERE p.is_active = false
  AND EXISTS (
    SELECT 1 FROM orders o WHERE o.status IN ('pending','confirmed','in_progress') AND
      -- orders don't carry product_id directly, so check by name or cake_size text
      o.cake_size = p.name_en OR o.filling = p.name_en
  );
```

### Audit output template

```
## Inventory & Menu Audit — [YYYY-MM-DD]

### Code-level
- [PASS / NOTE] Mock product fallback present (CLAUDE.md known)
- [PASS/FAIL] deleteProduct is soft-delete
- [PASS/FAIL] updateIngredient clamps non-negative
- [PASS/FAIL] deductInventoryForOrder logs warnings on missing recipe
- [PASS/FAIL] logIngredientUsage fires exactly once per transition
- [PASS/FAIL] getLowStockItems shape matches UI expectations
- [PASS/FAIL] Customer menu items match configurator options
- [FAIL — KNOWN GAP] Recipe tables populated
- [PASS/FAIL] inventory-health-monitor channel cleaned up
- [PASS/FAIL] Wizard fetches from DB (fallback constants not canonical)

### Data-level
- I1 active products: X
- I2 configurator table counts: [list — zeros are red]
- I3 low-stock ingredients: X (owner should see this count match InventoryManager)
- I4 negative/null quantities: X (target: 0)
- I5 orphan recipe rows: X (target: 0)
- I6 weekly usage: [sample]
- I7 deduction coverage: orders_started=X, orders_deducted=Y
- I8 unused ingredients: [list]
- I9 inactive products referenced by live orders: X (target: 0)

### Flag as gap (every audit)
- Recipe admin UI absent → tables likely empty / stale
- MOCK_PRODUCTS fallback still in place
- orderStepConstants FALLBACK_* still in place
```

---

## Mode: diagnose

### Step 1 — Ask
- What does the owner / customer see vs. expect?
- Which surface: customer menu / wizard / FrontDeskInventory / InventoryManager?

### Step 2 — Symptom matrix

| Symptom | Likely cause | Check |
|---|---|---|
| "Customer sees a cake we don't sell" | products is_active not flipped OR Menu.tsx hit MOCK fallback | I1; Menu.tsx fallback code |
| "Wizard offers a filling we don't have" | cake_fillings table not in sync with products | Q comparing the two |
| "Ingredient count doesn't go down after orders" | recipes empty OR deduct function never fires | I5, I7 |
| "Low-stock alert didn't fire" | getLowStockItems query mismatched thresholds OR UI polling stale | I3 + component read logic |
| "Ingredient went negative" | no clamp on updateIngredient OR concurrent deduction race | I4; inspect updateIngredient implementation |
| "Menu manager saves but no change visible" | react-query cache not invalidated after update (see dashboard skill) | elis-bulletproof-dashboard item #6 |

### Step 3 — Report + propose
Root cause + SQL patch or code change proposal. Do not modify without explicit user approval.

---

## Mode: scale-check

Before adding a new cake line or bread type:

1. **Configurator + product sync.** Adding a bread type requires row in `bread_types` AND potentially a matching `products` variant row. Both updated?
2. **Pricing consistency.** If `premium_filling_upcharges` changes, verify server-side recompute in `create_new_order` picks up the new value.
3. **Recipe for the new variant.** Add `product_recipes` entries so deduction fires.
4. **Customer menu images.** Upload images to Supabase storage, reference in `products.image_url`. Confirm 200 response.
5. **FALLBACK constants.** If you add a new bread type but leave `FALLBACK_BREADS` without it, an offline customer sees a missing option. Either update the fallback or remove it.

### Output
```
## Inventory Scale Readiness — Change: [new cake / new bread / new filling]

- products row added + is_active=true: Y/N
- configurator tables updated (cake_sizes / bread_types / cake_fillings): Y/N
- Recipes added for new variant: Y/N
- Image uploaded + reachable: Y/N
- FALLBACK constants updated: Y/N
- Staged test order placed: Y/N

Verdict: [READY / NOT READY — list]
```

---

## HARD RULES

- **NEVER hard-delete products.** Always soft-delete via `is_active=false`.
- **NEVER decrement ingredient quantity below 0** at DB level. UI clamp is not enough — the RPC or trigger must enforce.
- **NEVER modify `product_recipes` or `order_component_recipes`** rows from this skill without explicit user approval. These drive deduction math.
- **NEVER remove MOCK_PRODUCTS** without confirming the prod products table is seeded.
- **NEVER write to production DB** from this skill.
- **Scope:** if a fix touches the order wizard UI, dashboard chrome, or kitchen display, hand off to the matching skill.
