# Salahly: AI First-Visit Preparation

Date: 2026-11-13.
Status: recommended implementation scope, ready for user review. No app changes
or deployment have been performed or authorized by this planning discussion.

## Product Decision

Position Salahly around preparing a useful repair visit, not "Uber for repairs."
The proposed contribution is an adaptive, safety-constrained intake assistant
that produces clearer requests while explicitly preserving uncertainty.
First-visit success is a future outcome to measure, not a promised capability.

A map is a supporting interface. Later, a provider-side view of consented coarse
demand areas can support flexible neighborhood repair rounds. Neither maps nor
photo-to-category suggestions are, by themselves, a defensible novelty claim.
Conduct competitor and literature research before making originality claims.

This plan covers applied AI using the existing model-provider integration and
an evaluation of its usefulness. Original model training, compulsory review/fraud
detection, and compliance with an unavailable academic rubric are outside this
milestone. Do not remove any previously required academic feature on its basis.

## Existing Foundations

- The request, consented listing, quote, acceptance, and participant-only job
  journey exists in source. Reuse it rather than replacing it with dispatch.
- Matching is deterministic weighted ranking, not a learned success predictor.
  It uses category eligibility, optional coarse points, declared hours, and
  self-reported experience. It does not model equipment expertise or capacity.
- `supabase/functions/ai-diagnose/index.ts` contains a standalone Gemini prototype.
  It is not integrated into Flutter intake and needs comprehensive hardening.
- Public listings contain separately consented summary/city/category. Original
  descriptions and addresses become visible only to the accepted provider;
  request photos remain customer-only. Public summaries are not automatically
  anonymized. The assistant must preserve these boundaries.
- No GPS/map/geocoder or collision-free booking system currently exists.
  Presence of source and recorded local tests does not establish hosted operation.

## Initial Scope

- Optional assistance inside the existing customer request-draft journey.
- Support plumbing and air-conditioning intake first. Other categories retain
  the existing manual form. Bind reviewed checklists to existing active catalog
  identifiers; do not invent categories or route by translated display text.
- Accept a description and, optionally, one explicitly selected draft photo.
  Ask at most two short follow-up questions, selected from reviewed checklists.
- Produce a customer-editable brief: observed/reported symptoms, equipment facts,
  suggested service category, and information still missing. Distinguish observed
  facts from possible explanations; do not assert an exact fault or necessary part.
- Require customer approval before transferring any suggestion into the normal
  request form. Use existing field limits and submission/reconciliation behavior.
- Keep existing category-based matching and quote acceptance unchanged. Do not
  label recommendations as equipment-qualified until that capability exists.

Excluded: live tracking, autonomous assignment, booked slots, new quote terms,
price prediction, repair instructions, general chat, predictive maintenance,
automatic image-based quality judgments, and training a model from scratch.

## Implementation Tasks

1. **Define the intake contract and reviewed question bank.** Keep a small
   category-specific checklist beside the Edge Function, with stable question IDs,
   allowed answers, evidence requirements, and conservative safety text. Validate
   category IDs against the active catalog on the server. The response contract
   contains `status` (`needs_information`, `draft_ready`, `uncertain`, or
   `out_of_scope`), `suggested_category_id`, bounded `summary`, `observations`,
   `missing_information`, an optional allowed `next_question_id`, and allowlisted
   `risk_flags`. Validate every field and cross-field combination. Do not turn
   model-generated confidence labels into probabilities or matching scores.

2. **Harden and adapt the existing Edge Function.** Verify the authenticated caller
   and customer role on the server, independent of gateway assumptions. Require
   explicit consent for external text/photo processing. Bound request bytes,
   decoded image bytes, MIME/signature, text, context, model output, and total
   calls. Re-encode accepted images to remove embedded metadata before sending
   them to the external model; do not claim that this removes visible private
   details. Never send saved address/contact fields. Use server-only AI secrets,
   bounded timeouts, and catalog/checklist-constrained prompts. Treat descriptions,
   images, and model output as untrusted data. The model cannot execute tools or
   publish, submit, assign, or modify records.

3. **Add narrowly scoped usage controls.** Create an additive ordered migration
   for a private, expiring usage ledger containing caller, run ID, consent time,
   call count, timestamps, and status, not images or conversation content. Reserve
   quota atomically through a server-only operation after caller verification.
   Default to at most three model calls per run and five runs per rolling hour;
   keep limits server-configurable. No client can bypass limits or write another
   user's ledger. Expire usage metadata after 24 hours. Failed/ambiguous external
   calls consume their reserved attempt; do not automatically repeat them.

4. **Implement the Flutter repository and draft state.** Add immutable typed
   assistant models and a repository following the existing demo/live injection
   pattern. Compose with `ServiceRequestFormCubit` without introducing another
   state-management library. Keep conversation/result state in memory and clear it
   on discard, logout, or account change. A late response cannot modify a different
   account's draft. Clearly label deterministic demo responses as samples, not
   live AI. Do not pass presentation context into backend code.

5. **Build the bounded assistant UI.** Use existing widgets, theme, and English/
   Arabic localization. Offer manual entry first, opt-in text/photo assistance,
   question/answer progress, and an editable result preview. Apply only fields the
   customer confirms; never silently overwrite manual edits or publish the brief.
   Keep private draft information separate from later public listing text. Show
   uncertainty and missing facts prominently, with no diagnostic percentage.
   Use reviewed safety banners for flagged hazards; do not display raw model DIY
   instructions or claim emergency detection is reliable. Retain manual access
   after timeout, quota refusal, invalid output, cancellation, or abstention.

6. **Verify before enabling live assistance.** Add Edge Function/model-mock tests,
   migration/RLS tests, repository/cubit tests, and English/Arabic widget tests.
   Run existing Flutter analysis/tests and disposable database checks. Keep live
   assistance explicitly disabled until configuration and dedicated hosted checks
   pass. Do not deploy, alter native configuration, or edit real secrets as part
   of this plan. Existing request-photo retention is unchanged; disclose this
   separately from the assistant's transient processing and usage-ledger expiry.

## Validation And Academic Evidence

- Compare three approaches over equivalent cases: existing manual form, a static
  reviewed checklist, and the adaptive AI assistant using that same checklist.
  This tests whether AI adds value beyond better form design.
- Use consented, technician-reviewed examples spanning supported categories,
  insufficient evidence, conflicting symptoms, other categories, and hazards.
  Freeze evaluation cases before prompt tuning; keep variants of the same repair
  or image out of both tuning and held-out sets. Label synthetic examples clearly.
- Have technicians assess brief usefulness/completeness without knowing its
  method. Counterbalance user task order. Report category routing, missing-field
  coverage, unsupported claims, corrections, completion/dropout, latency, cost,
  and English/Arabic differences. Include failed and abstained cases.
- Report unsafe-output and inappropriate-reassurance rates for a reviewed safety
  challenge set. Passing it is evidence for that set, not proof of universal safety.
- Test unauthenticated/provider callers, cross-user access, consent refusal,
  concurrent quota reservation, oversized/malformed input, prompt injection,
  catalog mismatch, invalid model output, timeout, account changes, and manual
  fallback. Never log prompts, photos, credentials, or customer contact details.
- A reproducible comparison, limitations, model/version record, threat model, and
  requirement-to-test traceability are deliverables. Actual repeat-visit reduction
  requires a separate field study; simulation or brief ratings cannot prove it.

## Later Extensions, Not Authorized By This Plan

1. **Capability-aware quoting:** collect explicit equipment/brand/task capabilities
   and provider-confirmed readiness. Distinguish declared from verified evidence;
   an approved credential does not certify every capability. Connect suggestions
   to actual provider quotes before considering invitations or scheduling.
2. **Neighborhood repair rounds:** customers separately opt into flexible time
   windows and grouping. A provider proposes compatible visits; each customer
   retains an independent approval/quote/job. Requires scheduling/capacity and
   duration rules. Compare travel against individual/nearest-job baselines;
   route optimization is not automatically machine learning.
3. **Provider-side demand map:** authorized coarse areas and category filters,
   with a list alternative. No public exact household pins or persistent live
   provider tracking. Sparse areas can still identify households; do not promise
   anonymity. Define aggregation, suppression, consent, abuse limits, and map
   provider/road-distance costs before introducing coordinates or ETAs.

## Evidence Anchors

- `README.md:17-35,80-103`; `MILESTONES.md:313-364`.
- `supabase/functions/ai-diagnose/index.ts:17-38,69-112`.
- `lib/src/ui/requests/service_request_form_cubit.dart:165-257`.
- `lib/src/data/models/matching.dart:610-787`.
- `supabase/migrations/202611090001_quotes_and_jobs.sql:179-206,261-317,832-877`.
- `supabase/migrations/202611110001_smart_matching.sql:344-405,423-505`.
- Frontdoor's public site demonstrates that remote repair guidance plus access
  to local professionals already exists: https://www.frontdoor.com/ . This is
  a counterexample to broad novelty claims, not a comprehensive market survey.
