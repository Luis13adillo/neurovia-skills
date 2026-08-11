---
name: neurovia-pre-deployment-audit
description: Use when auditing a project for deployment readiness, when asked to "audit this project", "is this ready for deployment", "run a pre-launch check", "check this codebase", or any request to evaluate project health. Designed for Next.js + Supabase + Stripe + Vercel stack. Runs a comprehensive multi-phase audit covering code quality, security, database, payments, performance, configuration, and documentation.
---

# Neurovia Pre-Deployment Audit

## Overview

Full-stack deployment readiness audit for projects built with Next.js, Supabase, Stripe, and Vercel. Runs 10 audit phases using subagents in parallel where possible, then compiles a single prioritized report with a deployment readiness score.

## When to Use

- Before deploying any client project to production
- After major feature additions or refactors
- When onboarding a project you haven't touched in a while
- When a client reports issues and you need a full health check
- Periodically as a quality gate (monthly or per sprint)

## Audit Process

**IMPORTANT: Do NOT skip phases. Do NOT summarize findings as "looks good" without evidence. Every phase must produce specific file paths, line numbers, and concrete findings.**

Run all 10 phases. For each phase, report findings as:
- 🔴 CRITICAL — Must fix before deployment. Will cause failures, data loss, or security breaches.
- 🟡 WARNING — Should fix before deployment. Will cause performance issues, poor UX, or technical debt.
- 🟢 PASS — Meets standards. No action needed.
- ⚪ N/A — Not applicable to this project.

---

## Phase 1: Project Documentation & Configuration

Check that project documentation is accurate and complete.

### CLAUDE.md
- [ ] Exists at project root
- [ ] Tech stack description matches actual dependencies in package.json
- [ ] File structure description matches actual directory layout
- [ ] Database schema description matches actual Supabase tables
- [ ] API routes listed match actual routes in app/api/ or pages/api/
- [ ] Environment variables listed match .env.example and .env.local
- [ ] No outdated references to removed features or files

### Project.md (if used)
- [ ] Feature list matches implemented functionality
- [ ] Client requirements are reflected in the codebase
- [ ] Sprint/phase status is accurate
- [ ] No TODO items that should be completed before launch

### Package.json
- [ ] No unused dependencies (check imports across codebase)
- [ ] No missing dependencies (all imports resolve)
- [ ] No wildcard versions (^, ~) on critical packages (next, @supabase/supabase-js, stripe)
- [ ] Scripts include build, dev, lint at minimum
- [ ] Node engine version specified if required

---

## Phase 2: Environment Variables & Vercel Configuration

### Environment Variables
- [ ] .env.example exists with ALL required variables (no values, just keys)
- [ ] .env.local is in .gitignore
- [ ] No secrets or API keys hardcoded in source code (grep for patterns: sk_, pk_, key=, secret=, password=, token=)
- [ ] All Supabase variables present: NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
- [ ] All Stripe variables present: STRIPE_SECRET_KEY, NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY, STRIPE_WEBHOOK_SECRET
- [ ] NEXT_PUBLIC_ prefix only on variables safe for client exposure
- [ ] No SUPABASE_SERVICE_ROLE_KEY exposed with NEXT_PUBLIC_ prefix

### Vercel Configuration
- [ ] vercel.json exists if custom config needed (redirects, headers, rewrites)
- [ ] Build command is correct
- [ ] Output directory is correct
- [ ] Environment variables documented for Vercel dashboard setup
- [ ] Cron jobs configured if needed (vercel.json crons field)
- [ ] Function regions set appropriately for client location

---

## Phase 3: Supabase Database & RLS

### Schema Design
- [ ] All tables have created_at and updated_at timestamps
- [ ] Primary keys are UUID type (not serial/integer) for security
- [ ] Foreign key relationships properly defined with ON DELETE behavior
- [ ] Indexes exist on frequently queried columns (especially foreign keys and filter columns)
- [ ] No unused tables or columns from abandoned features
- [ ] Enum types or check constraints used where appropriate (status fields, role fields)

### Row Level Security (RLS)
- [ ] RLS is ENABLED on every table (no exceptions)
- [ ] Every table has at least one policy for SELECT, INSERT, UPDATE, DELETE as needed
- [ ] Policies use auth.uid() for user-scoped data
- [ ] Service role bypass is only used in server-side API routes, never client-side
- [ ] No policies with USING (true) on sensitive tables (this exposes all data)
- [ ] Multi-tenant/multi-location data properly scoped (users can only access their location's data)

### Migrations
- [ ] All schema changes are in migration files (not manual dashboard edits)
- [ ] Migrations are sequential and non-conflicting
- [ ] Seed data exists for required lookup tables

### Realtime Subscriptions
- [ ] Subscriptions are cleaned up on component unmount (useEffect cleanup)
- [ ] Realtime is only enabled on tables that need it
- [ ] Subscription channels use specific filters (not listening to entire tables)

### Edge Functions (if used)
- [ ] CORS headers set correctly
- [ ] Error handling returns proper HTTP status codes
- [ ] Service role key used securely (not exposed in responses)

---

## Phase 4: Stripe & Payment Flows

### Webhook Handlers
- [ ] Webhook endpoint exists (app/api/webhooks/stripe or similar)
- [ ] Webhook signature verification using stripe.webhooks.constructEvent()
- [ ] Idempotency handling — duplicate events don't create duplicate records
- [ ] All relevant event types handled:
  - checkout.session.completed
  - payment_intent.succeeded
  - payment_intent.payment_failed
  - customer.subscription.created (if subscriptions)
  - customer.subscription.updated (if subscriptions)
  - customer.subscription.deleted (if subscriptions)
  - invoice.payment_failed (if subscriptions)
- [ ] Webhook returns 200 quickly (heavy processing done async or after response)
- [ ] Failed webhook processing logged with enough context to debug

### Payment Flow
- [ ] Stripe Checkout or Payment Intents used (not raw card collection)
- [ ] Success and cancel URLs configured and working
- [ ] Payment amounts validated server-side (not trusting client-sent prices)
- [ ] Currency set correctly
- [ ] Customer email captured for receipts
- [ ] Metadata attached to payments for order tracking

### Error Handling
- [ ] Card decline errors shown to user in friendly language
- [ ] Network failures handled with retry logic or clear error messaging
- [ ] Partial payment states handled (payment succeeded but order creation failed)

---

## Phase 5: Security

### Authentication
- [ ] Supabase Auth properly configured
- [ ] Protected routes check for session/user before rendering
- [ ] API routes verify authentication before processing
- [ ] Password reset flow works
- [ ] Email verification enabled if required
- [ ] OAuth providers configured correctly (if used)

### API Security
- [ ] All API routes validate input (type checking, required fields)
- [ ] Rate limiting implemented on public-facing endpoints
- [ ] Rate limiting implemented on authentication endpoints (login, signup, password reset)
- [ ] CORS configured properly (not wildcard * in production)
- [ ] No sensitive data in URL parameters (use POST body or headers)
- [ ] API responses don't leak internal errors to clients (generic error messages in production)

### Data Security
- [ ] SQL injection prevention (parameterized queries, Supabase client handles this but check raw queries)
- [ ] XSS prevention (no dangerouslySetInnerHTML without sanitization)
- [ ] CSRF protection on state-changing operations
- [ ] File uploads validated (type, size) if applicable
- [ ] Sensitive data encrypted at rest where required
- [ ] No console.log statements exposing sensitive data in production

### Dependencies
- [ ] No known CVEs in dependencies (npm audit)
- [ ] No deprecated packages
- [ ] Lock file (package-lock.json or pnpm-lock.yaml) committed

---

## Phase 6: React & Next.js Performance

### Critical Performance
- [ ] No request waterfalls (sequential data fetches that could be parallel)
- [ ] Server Components used by default, Client Components only when needed ('use client' not overused)
- [ ] Dynamic imports (next/dynamic) for heavy components not needed on initial load
- [ ] Images use next/image with proper width, height, and priority attributes
- [ ] No large libraries imported entirely when only a subset is needed (e.g., import entire lodash vs lodash/get)

### Bundle Size
- [ ] No unnecessary client-side JavaScript (check with next build output)
- [ ] Tree shaking working (no barrel file re-exports that prevent it)
- [ ] Fonts loaded via next/font (not external CSS links)
- [ ] Third-party scripts loaded with next/script and proper strategy

### Rendering
- [ ] Pages that can be static ARE static (no unnecessary dynamic rendering)
- [ ] Loading states exist for async operations (Suspense boundaries, loading.tsx files)
- [ ] Error boundaries exist (error.tsx files in app router)
- [ ] Metadata properly set for SEO (title, description, og tags)

### Data Fetching
- [ ] Server-side data fetching preferred over client-side where possible
- [ ] Proper caching strategy (revalidate settings, cache tags)
- [ ] No useEffect for data that could be fetched server-side
- [ ] Pagination or infinite scroll for large data sets (not loading everything at once)

---

## Phase 7: Multi-Location Data Isolation (if applicable)

Skip this phase if the project is single-location.

- [ ] Location/store identifier present in database schema
- [ ] RLS policies filter by location (users only see their location's data)
- [ ] Admin users can access cross-location data where needed
- [ ] Location selection/switching works in the UI
- [ ] Orders, bookings, and transactions scoped to correct location
- [ ] Analytics and reports filterable by location
- [ ] Location-specific settings (hours, menu, pricing) stored separately
- [ ] No data leakage between locations (test by logging in as Location A user and attempting to access Location B data)

---

## Phase 8: API Endpoint Completeness

### Route Inventory
- [ ] List all routes in app/api/ (or pages/api/)
- [ ] Every route has proper HTTP method handling (GET, POST, PUT, DELETE as needed)
- [ ] Every route has error handling with try/catch
- [ ] Every route returns appropriate status codes (200, 201, 400, 401, 403, 404, 500)
- [ ] Every route validates request body/params before processing

### Business Logic
- [ ] All CRUD operations exist for core entities (create, read, update, delete)
- [ ] Soft delete preferred over hard delete for important data
- [ ] Audit trails exist for critical operations (who did what and when)
- [ ] Background jobs or cron routes exist for scheduled tasks (if needed)

---

## Phase 9: Error Handling & Logging

- [ ] Global error boundary exists (app/global-error.tsx)
- [ ] Route-level error boundaries exist for critical pages
- [ ] API routes return consistent error response format: { error: string, code: string }
- [ ] User-facing error messages are helpful (not "Something went wrong")
- [ ] Critical errors would be visible in Vercel logs (proper console.error usage)
- [ ] No unhandled promise rejections
- [ ] No uncaught exceptions in async operations
- [ ] Try/catch blocks around all external service calls (Supabase, Stripe, third-party APIs)

---

## Phase 10: TypeScript & Code Quality

### TypeScript
- [ ] strict mode enabled in tsconfig.json
- [ ] No @ts-ignore or @ts-expect-error without explanatory comment
- [ ] No 'any' types (or minimal, justified usage)
- [ ] Interfaces/types defined for all API responses, database rows, and component props
- [ ] Zod or similar validation for runtime type checking on API inputs

### Code Quality
- [ ] No TODO or FIXME comments that should be resolved before launch
- [ ] No commented-out code blocks
- [ ] No console.log statements (should use proper logging or be removed)
- [ ] Consistent file naming convention
- [ ] No duplicate logic that should be extracted to shared utilities
- [ ] No hardcoded values that should be environment variables or constants

---

## Output Format

After running all phases, produce a summary report:

```
============================================
NEUROVIA PRE-DEPLOYMENT AUDIT REPORT
Project: [project name from CLAUDE.md or package.json]
Date: [current date]
============================================

DEPLOYMENT READINESS SCORE: [X/100]

CRITICAL ISSUES (must fix): [count]
WARNINGS (should fix): [count]
PASSED CHECKS: [count]

--- CRITICAL ISSUES ---
[List each with phase number, specific file, line number, and what to fix]

--- WARNINGS ---
[List each with phase number, specific file, line number, and what to fix]

--- PHASE SUMMARY ---
Phase 1 - Documentation:      [🔴/🟡/🟢]
Phase 2 - Environment/Config:  [🔴/🟡/🟢]
Phase 3 - Supabase/Database:   [🔴/🟡/🟢]
Phase 4 - Stripe/Payments:     [🔴/🟡/🟢]
Phase 5 - Security:            [🔴/🟡/🟢]
Phase 6 - Performance:         [🔴/🟡/🟢]
Phase 7 - Multi-Location:      [🔴/🟡/🟢/⚪]
Phase 8 - API Completeness:    [🔴/🟡/🟢]
Phase 9 - Error Handling:      [🔴/🟡/🟢]
Phase 10 - Code Quality:       [🔴/🟡/🟢]

--- DEPLOYMENT RECOMMENDATION ---
[READY / READY WITH WARNINGS / NOT READY]
[Brief explanation of what must happen before deployment]
```

## Scoring

- Start at 100 points
- Each CRITICAL issue: -10 points
- Each WARNING: -3 points
- Score 80+: READY WITH WARNINGS
- Score 90+: READY
- Score below 80: NOT READY
