# Salahly Graduation Project Direction

Status: exploratory draft, not approved or implementation-ready.
Updated: 2026-11-13 after the user proposed live dispatch, grounded repair estimates,
and maintenance scheduling. The user requested an opinion, not implementation.

## Proposed Product

**A home-maintenance platform that helps customers maintain their appliances,
understand likely repair costs, and find an available technician when needed.**

Recommend live dispatch as the main technical contribution. Data-backed estimates
and appliance maintenance support the same journey rather than becoming unrelated
demonstrations. Preserve normal quote comparison for non-urgent or uncertain work.

Earlier feature lists and the AR, acoustic, and fraud-graph alternatives were not
selected. This draft does not treat them as additional approved work.

## Existing Boundaries

- M7 provides consented publication, versioned quotes, atomic customer acceptance,
  participant-only jobs, immutable terms/history, and concurrency tests.
- `ServiceJob` requires quote ID, revision, price, and a customer-originated initial
  event. A technician claiming an urgent offer cannot simply bypass this contract.
- M8 provides explainable recommendations using coarse work origins and declared
  hours. These are not live GPS, online presence, reserved capacity, or road ETAs.
- Reviews/ratings are not implemented. Do not invent rating evidence for dispatch.
- The inbox is not a durable dispatch-delivery system. AI remains an isolated Edge
  experiment. Asset records, pricing catalogs, and maintenance scheduling are new.
- Local test records are not proof of hosted or real-device behavior. No tests or
  deployments were performed for this planning update.

## First Decision

What does a customer commit to before an urgent technician travels?

Recommended: a disclosed fixed inspection/call-out fee, followed by a separately
approved repair quote. The indicative estimate is not a binding repair price.
Alternatives are an explicitly free inspection or narrowly defined fixed-price
services. This remains unanswered; no payment or dispatch contract is finalized.

## Proposed Work Packages

1. **Set the dispatch contract.** Define urgent versus ordinary requests, supported
   categories/area, visit versus repair booking, consent, charges, cancellations,
   no-shows, and reassignment. Choose an explicit model for a visit before the
   existing quote-bound repair job; do not fabricate customer quote acceptance.

2. **Build server-authoritative dispatch.** Combine provider online intent, expiring
   heartbeat/location freshness, relevant skills, required verification, and actual
   workload. Filter eligibility before ranking. Recommend time-limited offers to
   small ranked groups rather than notifying every provider at once. Each claim
   atomically rechecks offer validity, request state, provider eligibility/capacity,
   and agreed terms. Prevent both multiple winners for one request and excess
   assignments to one provider. Use idempotent retries and server-side expiry.

3. **Deliver and track reliably.** Persist offers/events; use Realtime for connected
   updates and explicitly scoped push for background alerts. Reconnect must reload
   authoritative state. Handle expired offers, duplicate delivery, unavailable
   providers, cancellation/claim races, lost replies, and no-match fallback. GPS
   needs explicit consent, freshness labels, restricted participant access, and a
   stop/retention policy. Do not reuse public discovery origins for live tracking.
   Distinguish straight-line distance from travel time and actual routing estimates.

4. **Ground estimates in real rates.** AI asks clarifying questions and proposes
   tentative catalog scopes; a deterministic calculator uses versioned, validated
   provider-supplied rates. Show source/date, visit fee, labour/parts ranges,
   assumptions, and exclusions. Unknown faults may yield several scenarios or an
   inspection-only result. Validate all AI output; keep manual input and rate-limit
   expensive calls. Never let the model invent prices, authorize charges, or dispatch
   automatically. Inspection and repair approval remain explicit and separate.

5. **Create a minimal appliance record.** Store owner-controlled appliance type,
   optional model/installation details, usage assumptions, relevant service history,
   and consented provider access. Reuse this context for estimates and maintenance.
   A completed job updates only the maintenance tasks actually performed, not every
   due date associated with the appliance.

6. **Start with preventive scheduling.** Use applicable manufacturer guidance and
   explicit user settings to produce explainable due tasks and reminders. Record
   the source, last qualifying service, and reason for each due date. Label this
   rule-based preventive maintenance, not trained failure prediction. ML requires
   longitudinal usage/outcome data, including appliances that have not failed.

## Validation And Demonstration

- Compare dispatch policies on identical documented scenarios: nearest-only,
  broadcast, and ranked waves. Measure assignment time, unassigned requests,
  workload distribution, and invariant violations. Label simulations as simulated.
- Test concurrent claims for the same request and different requests by the same
  provider; also expiry, offline presence, cancellation, retry, and unauthorized GPS
  access. Realtime delivery must never determine who owns a booking.
- Evaluate estimate range coverage and width against technician-reviewed costs for
  comparable scopes; record additional discoveries separately. Use held-out cases
  and report data limitations instead of interpreting fluent output as accuracy.
- Test maintenance rules against their documented sources, missing history, task
  completion, date boundaries, and reminder deduplication. Do not claim reduced
  failures from reminder correctness alone.
- Demonstrate appliance -> symptoms/questions -> grounded range -> explicit urgent
  booking -> two competing acceptances with one winner -> fresh location/status ->
  approved repair quote -> completed service history and relevant next due task.
- Retain architecture, threat model, requirements/test traceability, and clear
  separation between local, hosted, simulated, and physical-device evidence.

## Remaining Decisions And Rollout Boundaries

- Resolve the booking/fee contract first, then offer policy, capacity, assignment
  disclosure, reassignment, and financial/cancellation behavior one at a time.
- Confirm supported devices, foreground/background behavior, map/routing provider,
  and explicit approval for location/push native configuration. Native folders are
  protected; this planning session changes no native or application files.
- Confirm real pricing sources, maintenance guidance, pilot categories, and data
  consent/retention. Clarify compulsory assessment features, including the proposal's
  fake-review detection, rather than silently removing them.
- Recommend excluding life-safety emergency response, guaranteed arrival times,
  autonomous repair authorization, trained failure prediction without data, and a
  payment gateway from the initial scope unless explicitly required.
- Retain Flutter/BLoC/GoRouter/Supabase and existing private-data/quote guarantees.
  A later implementation should use additive migrations, feature-controlled rollout,
  and regression tests for the ordinary marketplace. Preserve unrelated user edits.
- Do not hand off for implementation until contracts, data flow, failure rules,
  native dependencies, migration boundaries, and acceptance criteria are resolved.

## Evidence Anchors

- `README.md:22-35,80-103`.
- `lib/src/data/models/marketplace.dart:369-390,426-519`.
- `supabase/functions/ai-diagnose/index.ts:47-112`.
- `supabase/migrations/202611090001_quotes_and_jobs.sql:81-107,547-565,832-875`.
- `supabase/tests/quotes_and_jobs_concurrency.mjs:85-135,200-285`.
- `supabase/tests/run_local.mjs:33-35,292-338`.
