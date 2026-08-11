# Adding a New Dashboard Section — Checklist

Use this when the owner asks for a new area of the dashboard. The goal: ship a page that looks like it was always there — same shell, same theme, same role-gating — and doesn't break E2E.

**This checklist is a GATE, not a generator.** Read it, list the gaps, then let the normal coding turn write the code. The skill never writes code without explicit user approval.

---

## 0. Name and location

Pick the new section's **URL path**, **sidebar section** (MAIN / SALES / TEAM / SETTINGS / MONITORING), and **role access** (owner-only / owner+promoter / owner+promoter+dev-only).

Write the answers down before any code:
```
URL:            /refunds
Sidebar:        SALES
Role:           owner + promoter
File:           src/pages/Refunds.tsx
Component:      Refunds
```

---

## 1. Route registration — App.tsx

Add the route inside the existing `<ProtectedRoute>` block. Model it after the existing dashboard routes at `App.tsx:76-102`.

```tsx
<Route
  path="/refunds"
  element={
    <ProtectedRoute allowedRoles={['owner', 'promoter']}>
      <Refunds />
    </ProtectedRoute>
  }
/>
```

**If owner-only:** `allowedRoles={['owner']}`.
**If dev-only (e.g., internal monitoring):** add `requireDev` prop: `<ProtectedRoute requireDev allowedRoles={['owner']}>`.
**Never** use a bare `<Route>` for a dashboard page.

---

## 2. Sidebar entry — OwnerPortalLayout.tsx

Add the entry to the correct `sidebarSections` item in `OwnerPortalLayout.tsx:46-93`. Match the role-gating you set in Step 1.

```ts
{
  title: "SALES",
  items: [
    { title: "Ticket Sales", path: "/orders", icon: ShoppingCart },
    { title: "VIP Tables", path: "/vip-tables", icon: Wine },
    { title: "Analytics", path: "/analytics", icon: BarChart3 },
    { title: "CRM", path: "/customers", icon: UserRound },
    { title: "Waitlist", path: "/waitlist", icon: ClipboardList },
    { title: "Refunds", path: "/refunds", icon: Receipt },   // ← new
    { title: "My Referrals", path: "/promoter-dashboard", icon: Link2, promoterOnly: true },
  ],
},
```

Flags:
- `ownerOnly: true` on the **item** if staff-private (promoter can't see this entry).
- `promoterOnly: true` on the **item** if promoter-only.
- If the WHOLE section is owner-only, add `ownerOnly: true` at the section level.
- If the WHOLE section is dev-only, add `devOnly: true` at the section level (currently only MONITORING).

Import the icon from lucide-react at the top of the file. Use an icon that's already in the file or a semantically close one; do not invent a brand icon.

---

## 3. Page shell — the new page itself

The page MUST wrap in `<OwnerPortalLayout>`. Minimum shape:

```tsx
import OwnerPortalLayout from "@/components/layout/OwnerPortalLayout";
import { useAuth, useRole } from "@/contexts/AuthContext";
import { Button } from "@/components/ui/button";

export default function Refunds() {
  const { user } = useAuth();
  const role = useRole();

  const actions = (
    <Button className="w-full bg-gradient-to-r from-emerald-700 via-emerald-600 to-emerald-500 text-white shadow-lg shadow-emerald-900/40 sm:w-auto">
      Export CSV
    </Button>
  );

  return (
    <OwnerPortalLayout title="Refunds" description="Review and issue refunds." actions={actions}>
      {/* content sections here, each <section className="mt-6"> ... */}
    </OwnerPortalLayout>
  );
}
```

Do NOT:
- Render a custom header — use `title`, `subtitle`, `description`.
- Render your own sidebar — the layout provides it.
- Use a different background color on the root.

---

## 4. Theme tokens — internal content

Reference `references/invariants.md` "Theme Tokens" section. The short list:

- Outer container: `section` with `mt-6` between sections.
- Cards: `<Card className="rounded-3xl border border-white/10 bg-black/40 backdrop-blur-md shadow-2xl">` for the primary surface, `rounded-2xl border border-white/10 bg-white/5` for inner tiles.
- Text: `text-white` primary, `text-slate-300` body, `text-slate-400` helper, `text-slate-500` uppercase labels.
- Accent: emerald-500/600/700. No indigo, purple, pink. Amber for VIP, cyan for email, green for scanner status — match existing convention.
- Currency: import the existing formatter or duplicate `Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2 })`.

---

## 5. Data hook — realtime or one-shot?

If the page shows live state (counts that change during the night), use `useDashboardRealtime`:

```tsx
useDashboardRealtime({
  tables: ['orders', 'tickets'],  // only tables your page cares about
  onTableUpdate: {
    orders: () => fetchRefundsData(),
  },
});
```

**Never** subscribe to a table you don't actually consume — it wastes DB round-trips under load.

If the page is reference-only (e.g., Audit Log), a one-shot `useEffect(() => fetchData(), [])` is fine.

---

## 6. E2E hooks — data-cy attributes

If the page will be covered by Cypress specs:

1. On the sidebar entry (Step 2), add the path to the `sidebarDataCy` map in `OwnerPortalLayout.tsx:105-111`:
   ```ts
   const sidebarDataCy: Record<string, string> = {
     // ... existing
     "/refunds": "sidebar-refunds",
   };
   ```
2. On the page, add `data-cy` to the root container: `<section data-cy="refunds-container">`.
3. On any stat tile or table the test will assert on, add `data-cy` with a stable name.

Never remove a `data-cy` attribute that's referenced by a Cypress spec in `e2e/specs/`. If a page is retired, retire the spec in the same PR.

---

## 7. Role-in-page double-check

The `ProtectedRoute` on the route is the FIRST gate, but inside the page you may also need to differentiate owner vs promoter (e.g., hide an "Issue Refund" button for promoters). Use `const role = useRole()` and guard inline.

Promoters currently have view-only access to analytics/events/orders per the auth skill. Refund issuance is an owner-level action — don't expose it to promoters even though they can navigate to the page.

---

## 8. Mobile check

The sidebar is fixed at 288px on desktop and a drawer on mobile. The page content sits inside `max-w-7xl mx-auto space-y-10`. Check:

- Page renders on 844×390 (iPhone landscape)
- Page renders on 390×844 (iPhone portrait)
- Sidebar drawer closes on navigation (`setSidebarOpen(false)` inside the button — already handled by the layout)

---

## 9. Review the checklist one more time

Before marking done, re-walk items 1–8. The most common misses:
- Forgot the `ProtectedRoute` wrapper on the route.
- Forgot to add `ownerOnly: true` on a staff-private sidebar entry.
- Used `text-gray-*` instead of `text-slate-*`.
- Used `rounded-xl` instead of `rounded-2xl` on a card.
- Subscribed to `useDashboardRealtime` with a table the page doesn't need.

---

## 10. Ship

Follow `maguey-bulletproof-ship`. Don't push a new section without running:
- `npm run build --workspace=maguey-gate-scanner` (catches TypeScript drift)
- `npm run cy:run` if the section is in an E2E spec
- Manual browser check at both desktop and mobile widths

---

## What NOT to do from this skill

- Don't write the actual page code. This skill gates; the coding turn builds.
- Don't edit the sidebar without the user's paper trail on the role flag.
- Don't "improve" an existing section while adding a new one. Scope discipline — one change at a time.
- Don't delete `navigationItems` dead code or NavigationGrid component while doing this. That's a separate cleanup pass with its own approval.
