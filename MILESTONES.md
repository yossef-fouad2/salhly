# Salahly Milestones

Created before implementation on 2026-10-16. This is the working roadmap for
the local home-services platform described in `plan.md`.

## Current Scope

The foundation, authentication, homepage, motion, provider onboarding, requests,
and quotes/jobs work is retained below. The 2026-11-11 continuation authorizes
M8 matching only, not every remaining feature in `plan.md` at once.
UI preserves the current reusable Material 3 components and supplied visual
references. Hosted/backend and real-device acceptance remain separate checks.

- App name: **Salahly**; Dart package: `salahly`.
- Stack: Flutter, BLoC/Cubit, GoRouter, Supabase, English and Arabic.
- Navigation: Home, Notifications, Profile, with replaceable Material icons.
- Default backend: explicitly labelled local demo mode with dummy configuration.
- Real backend: Supabase Auth and RLS-protected repositories, enabled in `.env`.
- No service-role key, AI key, real credentials, or real customer data in the app.
- Native folders are protected by `AGENTS.md`. Android launcher/application IDs
  need a separate manual native change, documented in `SETUP.md`.

## Scaffold Review

- [x] Read `AGENTS.md`, `README.md`, `SETUP.md`, `DESIGN.md`, `architecture.md`,
  and the full product requirements in `plan.md`.
- [x] Inspect the existing startup, routing, auth, localization, and shared code.
- Reuse the existing button, text-field, validation, theme, logging, failure,
  localization, and task-result conventions instead of adding another stack.
- Fix missing auth state provisioning, navigation from business logic, and the
  incorrect assumption that a signup response always contains a session.
- Replace unconditional Supabase initialization with explicit demo/live setup.
- Keep data access out of widgets and keep route guards in the central router.
- Keep the existing AI experiment isolated; it is not part of this milestone.
- At the original scaffold review this workspace had no Git metadata. The
  current workspace is a Git repository; historical no-commit notes remain below.

## Implementation Milestones

### M1: Identity and Backend Foundation

Status: implemented (2026-10-16).

Goals: rename allowed source/configuration/docs; make dummy-key startup work;
establish shared repository injection and a copyable database setup script.

Database: `profiles`, `service_categories`, and `notifications`, with UUIDs,
timestamps, constraints, indexes, category seed data, and an auth-user trigger.
Later business tables will arrive with their own features, not as unused schema.

Flutter: app initialization, app title/imports, demo/live configuration, shared
repositories, and the existing theme/helpers.

Security: initialize the SDK only in live mode; accept only public client keys;
do not persist demo passwords or manually cache Supabase tokens. Profile role
is fixed at signup to customer/provider. Clients cannot self-grant admin or
verification, write catalog records, or create notifications.

Acceptance and tests: app can start with dummy values and no Supabase traffic;
SQL is reproducible on a fresh Supabase project; invalid live configuration
fails clearly rather than silently showing demo data; model/config/repository
tests cover the boundary. SQL execution needs a real or local PostgreSQL setup.

Dependencies and risks: platform naming remains a native-configuration task;
demo data must never be confused with production data.

### M2: Authentication and Basic Onboarding

Status: implemented (2026-10-16). Verified in demo mode; live Supabase Auth still needs a configured project.

Goals: email/password login, signup with full name and customer/provider role,
email confirmation, password recovery, session restoration, and logout.

Database: use Supabase Auth plus the M1 profile trigger. Store editable profile
details separately from authentication credentials.

Flutter: login, signup, email-code confirmation, password-reset flow, loading
and validation/error states, and centralized authenticated-route guards.

Integration: live Supabase Auth behind the existing service/repository boundary;
deterministic local demo accounts behind the same contract. Email-code flows
avoid requiring native deep links in this pass. Email templates need the OTP
token configured as described in `SETUP.md`.

Security: a user returned without a session is not authenticated. Recovery
must not bypass the password-update screen. No administrator signup option,
secret keys, token copies, or claims of real email delivery in demo mode.

Acceptance and tests: both roles can sign in; invalid forms/credentials are
handled; unconfirmed signup stays outside protected pages; recovery updates
the password; logout removes protected navigation; real SDK session persistence
is preserved. Live email delivery remains an external verification step.

### M3: Homepage and App Shell

Status: implemented (2026-10-16).

Goals: a readable, role-aware landing page; service-category browsing/search;
a three-destination bottom bar; a basic notification inbox and editable profile.

Database: read active service categories, read the current user's notifications,
mark owned notifications read, and read/update allowed current-profile fields.

Flutter: Home, Notifications, Profile, reusable state feedback, and modest
responsive layouts. Support English/Arabic, RTL, light/dark themes, loading,
empty, retry, and error states. Explain unfinished booking features honestly.

Security: all production data comes through repositories under RLS. Demo lists
stay in memory and do not masquerade as real requests, providers, or bookings.

Acceptance and tests: all three destinations work; category filtering and
refresh work; owned notification read state and profile changes work; sign out
returns to auth; narrow layouts and Arabic do not overflow.

Dependencies and risks: provider verification and actual request creation are
future milestones; do not imply that a new provider is verified or can take jobs.

### M4: Verification and Handoff

Status: in progress. Depends on M1-M3.

- [x] Run `flutter pub get`.
- [x] Run `flutter pub run easy_localization:generate -S assets/translations -O lib/src/core/i18n -o locale_keys.g.dart`.
- [x] Run `flutter analyze` - no issues found.
- [x] Run `flutter test` - 50 tests pass (auth, repositories, route guard, widget flows, responsive/RTL).
- [x] Provide database authorization checks that run against Supabase
  (`supabase/tests/foundation_rls.sql`, rollback-only).
- [x] Verify SQL/grants/triggers/RLS on an isolated PostgreSQL 18.6 (PGlite) run:
  5 migration executions and 3 authorization runs passed. This is not hosted
  Supabase; Auth email/OTP, PostgREST, and Realtime remain untested.
- [x] Update `README.md`, `SETUP.md`, and this file with actual results/limits.
- [ ] Verify real Auth, email templates, and RLS against a configured Supabase
  project when credentials/environment become available. Do not claim unrun
  database or real-email tests have passed.
- [ ] Native branding/application-ID rename in the protected platform folders.


### M4.5: Performance and Interaction Polish

Status: implemented and regression-tested (2026-10-17). On-device profiling
remains outstanding. Builds on M1-M3 without changing their data contracts,
authentication rules, or the three-tab navigation.

Goals: subtle, responsive interactions with readable reusable code, not a new
visual design or an animation dependency.

- [x] Short tab transitions that preserve each branch's state, scroll position,
  and form input, and disable tickers/focus in inactive branches.
- [x] A shared, finite entrance timeline for category content; no per-row
  entrance controllers and no replay on every search or state update.
- [x] Subtle press feedback using Material interaction states; preserve keyboard,
  semantics, gesture cancellation, disabled state, and ripple behavior.
- [x] Lazy notification rows and retained content during refresh.
- [x] Honor system reduced motion, including preference changes mid-animation.
- [x] Regression tests for lazy building, retained branch state, bounded
  animation/rebuild work, accessibility, and the existing auth/UI flows.
- [x] Run dependency, formatting, analysis, and full Flutter test checks.

Database: no migration or new credentials. Keep the dummy-key demo path intact.
Reuse `AppDurations`, `AppCurves`, existing shared widgets, and feature cubits.

Acceptance: interactions finish promptly, do not delay requests/input, preserve
tab state, and leave no decorative animation ticking after settling. Test
structural performance properties, not unreliable stopwatch timings in widget
tests. Device frame-rate and GPU/raster claims require a profile-mode run on an
actual target; they must not be inferred from passing widget tests.

### M5: Provider Onboarding

Status: implemented and locally verified (2026-10-18).
Hosted Storage/API checks and production review/privacy operations remain
external acceptance requirements, not simulated successes.

Goals: provider-only setup reached from Home and Profile, with three sections:
professional introduction/skills, service areas/weekly hours, and credential
submission/status. Preserve M1-M4.5 and do not start requests, quotes, or jobs.

- [x] Immutable models and a repository shared by explicit demo/live modes;
  feature state stays in a page-scoped cubit, not widget business logic.
- [x] Explicit partial-draft saves, retained edits between steps, retry feedback,
  dirty-exit confirmation, and no network writes on keystrokes.
- [x] Select active service categories; remove a previously saved inactive skill.
- [x] Up to 10 unique city/district labels and one local-time range per weekday.
  These are self-reported areas/hours, not geocoded coverage or bookable slots.
  Overnight hours must be split across days; scheduling/time-zone conversion
  remains a later request/job concern.
- [x] One JPEG/PNG credential image per submission, at most 5 MiB, explicit
  review consent, private authenticated viewing, and no public document URL.
- [x] Pending/verified/rejected states; pending details cannot be edited and
  rejection permits a new submission. Verification concerns the submitted
  credential, not certification of every self-listed skill or access to jobs.
- [x] Only trusted review operations can approve/reject, with a submission
  snapshot, consent time, reviewer identity, and review note. Demo submission
  remains pending and never fabricates a review or approval.
- [x] Reuse `AppCard`, `AppButton`, `AppTextField`, theme tokens and shared motion.
  One mounted section/finite entrance timeline, selective rebuilds, bounded
  on-demand image decoding, and cache eviction when private previews close.
- [x] Loading/refresh preserves mounted content and scroll; form controls fit
  narrow English/Arabic, dark mode, and an enlarged-text keyboard viewport.
- [x] Complete final analysis, full Flutter regression suite, and integration
  review; exact outcomes are recorded in the verification section below.

Database: `202610180001_provider_onboarding.sql`, after the foundation migration,
adds provider profiles, skills, service areas, availability, and verification
records. Clients get owned reads and transactional draft/submission RPCs, not
direct table writes. The `provider-verification` bucket is private; restrictive
bucket policies resist unrelated permissive policies. Referenced evidence is
immutable, including after rejection, and cannot be removed as upload cleanup.
`provider_onboarding_rls.sql` supplies rollback-only authorization/Storage-policy
checks; these do not test the hosted Storage service's handling of actual bytes.

Dependencies and limits: use sample documents until an operator publishes a
privacy/retention policy and appoints reviewers. M5 uses SQL Editor/trusted
server review, not a client administrator screen. Retention, abandoned-upload
cleanup, and deletion of accounts with evidence require a trusted procedure.
See `SETUP.md` for migration order, review commands, and live checks. No native
configuration, new packages, production credentials, or later marketplace
features are part of this continuation.

### M6: Service Requests

Status: implemented and locally verified (2026-10-31). Hosted Storage/API,
multi-connection concurrency, and real-device acceptance remain external checks.

Goals: customers can create and review their own requests with manual location,
optional preferred time, and private photos. Keep the existing three-tab shell,
Salhly visual language, and M1-M5 behavior; quotes, jobs, matching, and AI remain
separate milestones.

- [x] Customer-only form, history, and detail routes, reached from Home, service
  category sheets, and Profile; provider/recovery/signed-out guards stay central.
- [x] Immutable request/photo models and an explicitly demo/live repository,
  with page-scoped cubits and no backend writes on keystrokes or gallery picks.
- [x] Three local form sections with validation, retained input, consent, and
  dirty-exit confirmation; no automatic GPS, maps, or device-location permission.
- [x] Optional preferred instant stored in UTC and displayed in device local time;
  a future preference within 180 days is not a confirmed appointment.
- [x] Up to three JPEG/PNG photos, each at most 5 MiB, private authenticated
  previews, bounded decoding, and immediate revocation/cache eviction on logout.
- [x] Stable request/photo identities and transactional submission, including
  photo-free idempotency, exact-manifest reconciliation, conservative cleanup,
  and frozen drafts after ambiguous results or subsequent network failures.
- [x] Owned, lazy, keyset-paginated history with category-name snapshots; refresh
  retains current content, and returning from details reflects cancellation.
- [x] Idempotent open-to-cancelled transition. Submitted details and referenced
  photos remain immutable, including after cancellation; no deletion promise.
- [x] Private Storage policies/guards, owner checks, trusted RPC-only writes,
  file/metadata limits, and rollback-only SQL authorization tests.
- [x] Shared cards/buttons/fields, one active form section, bounded entrance and
  progress/status motion, stable category/photo widgets while typing, and no
  new packages or decorative animation loops.
- [x] English/Arabic, RTL/dark, 320/1200 layouts, enlarged text, keyboard handling,
  and existing regression coverage; full analysis/tests are recorded below.

Database: apply `202610310001_service_requests.sql` after the foundation and
provider migrations. It creates `service_requests`, `service_request_photos`,
owned submit/read/cancel RPCs, and the private `request-photos` bucket. Provider
access to request/address/photo data is intentionally not granted in M6.

Dependencies and limits: demo submissions/photos are session-local and reset
on restart. Use synthetic locations and sample photos until privacy, retention,
account deletion, and orphan cleanup procedures are established. Cancellation
does not delete photos; original files may contain embedded metadata. The
existing AI experiment is not invoked by the manual request flow. See SETUP.md
for ordered migration, Storage, and hosted verification instructions.

### M7: Quotes and Jobs

Status: implemented and locally verified (2026-11-09). Hosted Supabase and
physical-device acceptance remain external checks, not completed verification.

Goals: explicit privacy-safe request publication, eligible provider browsing,
versioned quote comparison/acceptance, and participant-only job tracking.
Preserve M1-M6, the three-tab shell, and customer-only request photos.

- [x] Separate, immutable public summary/city with explicit publication consent;
  existing M6 text/address/photos are never copied into an open feed.
- [x] Current verified-provider, active-skill, and exact normalized service-area
  eligibility; no distance, ranking, or availability-slot claims.
- [x] One quote per provider/request, integer EGP minor units, estimated duration,
  notes, revision-checked updates, withdrawal, and explicit reactivation.
- [x] Transactional acceptance rechecks the displayed revision and eligibility,
  accepts one quote, closes pending competitors, assigns one job, and records
  consent/history. Accepted terms are immutable; retries are idempotent.
- [x] Acceptance-time disclosure of original text/location to the selected provider
  only. Request photos, credential evidence, emails, and phones are not shared.
- [x] Provider progress, customer completion confirmation, pre-work cancellation,
  immutable participant access/history, and no terminal-state reopening.
- [x] Bounded keyset lists, retained refresh content, page-scoped state, original
  interrupted-action recovery, and immediate account-sensitive hiding.
- [x] Explicit shared in-memory demo flow with a separate plumbing/Cairo sample
  marketplace provider; ordinary onboarding submissions remain pending.

Database: apply `202611090001_quotes_and_jobs.sql` after M6. It creates
`request_marketplace_listings`, `provider_quotes`, `service_jobs`, and
`job_status_history`, with RLS enabled and RPC-only client access. Existing M6
request/photo owner policies remain unchanged in scope. Requests gain `assigned`;
job completion/cancellation does not reopen the assigned request.

Verification: **430 Flutter tests pass**, full analysis is clean, and all 32
hand-edited Dart files pass formatting checks. `quotes_and_jobs_rls.sql` extends
the rollback suites; the disposable native PostgreSQL 18.6 run passed all four
suites on fresh and populated-rerun schemas, plus **10 independently blocked
concurrency scenarios**. Detailed commands and limits are recorded below.

Dependencies and limits: M5/M6; no hosted migration, credentials, native changes,
payment integration, live notifications, matching/ranking, or production privacy
operations are included. See `SETUP.md` for migration order, lifecycle policy,
explicit sample accounts, local test commands, and hosted acceptance checks.

### M8: Smart Matching

Status: implementation and verification in progress (2026-11-11).

Goals: explainable request-specific recommendations and full eligible-provider
browsing, with configurable initial ranking assumptions and fair missing-data
handling. Preserve M1-M7 disclosure, quote revision, and job lifecycle rules.

- Separate provider discovery opt-in and consented name snapshot; no automatic
  publication of private M5 bios, credentials, contact fields, or service records.
- Hard current provider role, latest verified credential, active matching skill,
  published service-area label, and discovery consent filters in trusted SQL.
- Optional manually supplied two-decimal work-origin and customer matching
  point. Straight-line estimates are not GPS, road distance, ETA, or verified
  coverage. A discoverable origin is public/inferable and must not be private.
- Optional explicit service-area weekday/time preference compared with declared
  weekly hours, not the device time zone or M6 preferred appointment instant.
- Category-specific self-reported years, bounded normalized factors, a fixed
  neutral prior for unknown data, and whole-weight-denominator scoring. Ratings
  remain unavailable until M9; no invented stars or response/completion quality.
- Trusted configurable weights, distance scale, experience cap, and revision;
  initial 35/25/20/20 weights are assumptions, not proven optimal.
- Recommended and all-eligible modes with request-specific deterministic ties,
  bounded query/rules-bound cursors, explicit explanations, and retained refresh
  content. Provider selection still requires an actual M7 quote and consent.
- Separate provider settings and customer matching routes; English/Arabic,
  RTL/dark and narrow/large-text layouts using the existing visual system.
- Realistic synthetic near/far/new-provider scenarios, no-review cold starts,
  owner/role/consent tests, and full M1-M7 regression verification.

Database: `202611110001_smart_matching.sql` after M7; separate RPC-only
`provider_matching_profiles` and `matching_rules` with RLS and closed table/
column grants. Old request/photo/provider/quote/job policies remain unchanged.
Customer matching points are query inputs only, not saved in application tables.

Limits: no geocoding/maps/GPS permissions, trained model, review workflow,
invitations/notifications, booked availability, payments, or remote deployment.
Verification results are recorded after integrated checks, not inferred from
the presence of implementation files.

## Future Product Roadmap

All remaining milestones below are **not started**. Their order can be revised after
reviewing the foundation. Each database feature ships with its migration,
constraints, ownership policies, and relevant authorization tests.

| Milestone | Goals and Screens | Database / Integration | Security and Acceptance | Dependencies / Risks |
| --- | --- | --- | --- | --- |
| M9: Work history and reviews | Before/after photos, completed work, rating and review screens | Private job photos, reviews, aggregates | Completed-job eligibility, unique review per job, signed URL and moderation tests | M7; protect location/photo privacy |
| M10: Live notifications | Durable job/quote alerts, read state, reconnect behavior | Notification event generation, Realtime, optional push delivery | Private channels, deduplication, reconnect and recipient tests; Realtime is not the only record | M7; native push setup needs separate approval |
| M11: AI problem assistant | Photo/text suggestions and customer-confirmed request draft | Harden existing Edge Function; AI diagnoses and private uploads | Server-only AI secrets, rate limits, validated structured output, uncertainty and safety tests | M6; unreliable models and timeouts must not block manual requests |
| M12: Price estimates | Explainable indicative price ranges and quote breakdown | Pricing rules and estimate snapshots; integer minor units | No invented guaranteed prices; currency/rounding/rule tests; customer approves extras | M7; requires validated local pricing assumptions |
| M13: Complaints and warranties | Job complaints, provider terms, claims, review tools | Complaints, warranties, claims and admin audit trail | Scoped evidence access and trusted decisions; workflow tests; no universal warranty promise | M7/M9; policy and administrator responsibilities |
| M14: Release readiness | Accessibility, final design, performance, demo script | Database integration/security suite, monitoring and backup checks | Cross-user RLS/Storage tests, abuse checks, release signing and real-device acceptance | All approved features; native branding/configuration and production secrets supplied separately |

## Reuse and Work Boundaries

Use `lib/src/ui/` for feature views and state, `lib/src/data/` for repositories
and models, and `lib/src/services/` for backend/platform integrations. Keep
`lib/src/routing/app_router.dart` as the only route table. Prefer small focused
files and existing shared helpers over generic frameworks or extra packages.

Safe parallel work after contracts are agreed: translation/UI refinement,
database policies/tests, and feature-specific repository tests. Quote acceptance
and job transitions must be designed together, and auth/profile role changes
must remain synchronized between SQL and Dart.

## Verification Record

Verified on 2026-10-16:

- `flutter pub get` resolved with Dart/Flutter from the lockfile floor (>=3.13).
- `flutter analyze` reports **No issues found**.
- `flutter test` passes **50 tests**: demo/live configuration validation,
  email validation, translation key/interpolation parity, demo auth behavior,
  `AuthBloc`/`SessionBloc` states (including confirmation-required, failed
  logout, and stale-check races), the central route guard, and widget flows for
  guarded deep links, the three-tab shell, category search, per-user
  notifications, profile edits, signup confirmation, password recovery, and
  responsive/RTL/dark variants.
- SQL was executed on isolated PostgreSQL 18.6 (PGlite); migration reruns,
  backfill, and the rollback-only authorization suite passed. Hosted Supabase,
  Auth email/OTP delivery, PostgREST, and Realtime were **not** tested.
- Native launcher name and Android application ID were **not** changed (protected
  platform folders); see `SETUP.md` for the manual step.

### Motion and Performance: 2026-10-17

- `flutter pub get` succeeded; no new dependencies were added.
- Changed Dart files were formatted; `flutter analyze` reports no issues.
- `flutter test --reporter expanded` passes **69 tests**, including all prior
  authentication, repository, routing, English/Arabic, responsive, and dark-mode
  checks.
- New motion checks verify one shared entrance ticker, no per-frame content
  rebuilds, finite completion/disposal, no replay after item-count changes,
  reduced-motion changes during animation, native keyboard/drag/disabled-button
  behavior, and paused tickers/focus in inactive branches.
- App-level checks retain search text and unsaved profile input across animated
  tab switches. Router refreshes now depend on session status/user ID instead
  of every profile or loading-state update.
- A 1,000-notification fixture mounts at most 12 nearby rows at the tested
  viewport and builds fewer than 50 distinct rows when scrolling to row 30.
  Refresh tests retain row identity and exact scroll offset during delayed
  success/failure; read-state and cross-user isolation tests also pass.
- New decorative motion is limited to a 400 ms category entrance, 200 ms tab
  and auth transitions, and 100 ms press feedback. Existing content remains
  visible during Home and Notifications refreshes.
- These are structural/widget checks, **not** measured device FPS or GPU/raster
  results. Profile-mode testing on target hardware remains a release check.
- At this checkpoint, M5 provider onboarding was the next functional milestone.

### Provider Onboarding: 2026-10-18

- `flutter pub get` succeeded without adding Flutter dependencies; English and
  Arabic locale keys were regenerated with the existing localization command.
- Changed Dart files were formatted. `flutter analyze` reports no issues.
- `flutter test --reporter expanded` passes **160 tests**, retaining all 69
  prior regressions. New coverage includes model immutability/validation,
  authenticated demo isolation, real-SDK loopback HTTP serialization, private
  upload/download limits, response-loss reconciliation, retry cleanup, and
  session/recovery/logout races. There is no hosted Supabase acceptance claim.
- Provider widget/cubit checks cover provider-only deep links, draft save/resume
  and exit confirmation, duplicate request guards, retained edits/status refresh,
  private preview revocation and cache eviction on direct account switches,
  English/Arabic layouts at 320/1200 widths, dark mode, an enlarged-text keyboard
  viewport, and reduced-motion changes mid-animation.
- Performance checks confirm typing does not rebuild service chips or perform
  network writes. One provider operation validates the mapped auth profile
  once; subsequent session guards do not add repeated profile HTTP requests.
  Private files are streamed with a 5 MiB cap and decoded only for an explicitly
  opened preview with a 1200x1200 maximum decode target.
- Integration fixes include Material-backed shared cards for native control
  feedback, catalog failures no longer hiding authoritative review status,
  private dialogs tied to their originating account, safe SDK auth-event replay,
  and immutable Storage guards that permit generated-column/access-time writes.
- Both SQL suites pass on isolated PGlite **PostgreSQL 16.4 and 18.6** with a
  Supabase-shaped schema, including generated `storage.objects.path_tokens`.
  The provider suite emits 395 passing assertion/group notices and rolls back
  its fixtures. Additional probes cover populated migration reruns, retained
  evidence/audit snapshots, ACL/bucket-setting repair, and atomic refusal of
  unexpected public-table policies. These are SQL checks, not real Storage HTTP
  uploads or multi-connection race tests.
- Updated `README.md`, `DESIGN.md`, and `SETUP.md` explain reusable UI boundaries,
  migration order, trusted review, sample-document privacy limits, and live
  verification steps. Native folders and `.env` were not edited. This workspace
  had no Git metadata, so the existing files were retained as the baseline and
  no commit was created.
- At that checkpoint, the next functional milestone was **M6: Service requests**.
  Real-device gallery/performance checks, hosted Storage/API acceptance, and
  production privacy/retention/reviewer procedures remain external follow-ups.

### Service Requests: 2026-10-31

- `flutter pub get` succeeded without adding application dependencies. English
  and Arabic localization output was regenerated using the existing command.
- The complete Flutter regression suite passes **293 tests**, retaining all
  177 prior tests. New coverage comprises 75 model/repository tests, 15 photo
  input/picker tests, 15 cubit tests, and 11 widget-flow/layout/privacy tests.
- `flutter analyze --no-pub` reports no issues. Changed Dart files were formatted.
- Real-SDK loopback tests cover payloads, keyset pagination, three-photo limits,
  partial upload cleanup, 409 byte matching/non-deletion, dropped responses,
  retained uncertainty, authenticated stream caps, and session/write races.
  These are local HTTP fakes, not hosted Supabase acceptance.
- UI/state tests cover creation, consent, local draft retention, safe retry,
  discard, cancellation and automatic history refresh, category preselection,
  on-demand private viewing/cache eviction, and immediate account-switch hiding.
  Category/photo widgets remain stable while typing and only one form section
  and entrance timeline are mounted. Large-text headings scroll instead of
  consuming the keyboard viewport; narrow large-text back controls retain an
  accessible icon target.
- All three rollback-only SQL suites pass on isolated PGlite PostgreSQL **16.4
  and 18.6**, including generated Storage `path_tokens`. The M6 suite emits
  460 passing assertion/group notices. Fresh/populated reruns, retained records,
  ACL/bucket drift repair, and atomic rejection of unknown public policies pass.
- An isolated demo-only browser host built successfully. Mobile/desktop request
  submission and the rendered forms were checked, including Arabic dark/RTL
  layout. The host stayed outside the workspace; no web/native platform was added.
- No hosted migration, native configuration, credentials, commits, or deployment
  were performed. Real Storage bytes, PostgREST embedding, independent concurrent
  sessions, production privacy/retention operations, and hardware FPS remain
  separate acceptance checks in SETUP.md.
- At that checkpoint, the next functional milestone was **M7: Quotes and jobs**.

### Quotes And Jobs: 2026-11-09

- Implemented M7 only, preserving M1-M6 and the Home/Notifications/Profile shell.
  Updated `README.md`, `SETUP.md`, and `DESIGN.md` with actual navigation,
  explicit disclosure boundaries, lifecycle policy, and demo/live behavior.
- Added six named, centrally guarded routes: provider feed, provider quote form,
  provider quote history, customer comparison/sharing, job list, and job detail.
  English/Arabic strings and generated localization are synchronized.
- Added immutable marketplace models, a session-guarded RPC repository, and a
  shared in-memory demo store. A separate plumbing/Cairo sample provider enables
  cross-account demonstration without approving ordinary M5 submissions.
- Added migration `202611090001_quotes_and_jobs.sql`, rollback suite
  `quotes_and_jobs_rls.sql`, and the disposable native-PostgreSQL test runner with
  deterministic independent-connection concurrency checks. No hosted migration
  was applied and no `.env`, native configuration, or runtime package was changed.
- Verified `flutter pub get`, localization generation, and
  `flutter analyze --no-pub` (**no issues found**). All 32 hand-edited Dart files
  pass `dart format --output=none --set-exit-if-changed`; tracked diffs pass
  `git diff --check` (only normal Windows line-ending notices).
- Final full Flutter run: **430 tests passed**, using
  `flutter test --no-pub --reporter silent --file-reporter expanded:<temp-log>`.
  This includes 100 M7 model/repository tests, 17 state tests, 18 full-app widget
  tests, one English/Arabic key-parity test, and the preserved earlier suites.
  M6 additionally tests the new assigned status without a cancellation timestamp.
- Real-SDK loopback tests cover RPC arguments, bounded/tied pagination, lost
  responses and canonical reconciliation, original-action retry across page
  recreation, stale identical-price revisions, frozen terms/history, error
  sanitization, duplicate writes, and auth/account/recovery races. These use
  local HTTP fixtures, not the hosted database or Storage service.
- UI/state checks cover explicit consent, blank public fields, comparison,
  withdrawal/reactivation, provider progress/customer confirmation, retained
  refresh errors, dirty-form exits, guards, session replacement, and private
  content hiding. Layout coverage includes 320/1200 widths, Arabic/dark mode,
  enlarged text, and keyboard space; no physical-device FPS claim is made.
- Final SQL command: `node supabase/tests/run_local.mjs --deps <temp-deps> --concurrency`.
  On native **PostgreSQL 18.6**, all four fresh migrations and all four ordered
  populated reruns passed; stored rows remained unchanged. All four rollback
  suites passed twice: **2,428 PASS notices**, including **333 M7 PASS notices per
  phase**. PostgreSQL stopped and the isolated cluster was removed afterward.
- The **10 deterministic concurrency scenarios** confirm blocking via actual
  PostgreSQL lock state and cover competing acceptance, acceptance/cancellation,
  acceptance/price revision, acceptance/withdrawal, and duplicate provider/customer
  transitions. Exactly one quote/job wins, stale prices cannot be accepted,
  accepted terms remain frozen, and duplicate history is not created.
- M7 SQL security checks include role/owner isolation, publication consent and
  redaction, current eligibility, direct table/column denial, revision and
  canonical-retry rules, participant lifecycle/history, bounded pagination,
  unique/FK backstops, trusted tampering, and policy/schema drift. Existing M6
  owner-only request/photo and Storage policy checks still pass.
- Remaining external checks: real hosted Auth/PostgREST/JWT and Storage behavior,
  independent authenticated HTTP races, physical-device acceptance/profiling,
  and production consent/retention/deletion operations. Local SQL uses simulated
  identity claims and Storage metadata, not uploaded bytes or hosted signed URLs.
- No commits or remote deployments were made. Next functional milestone:
  **M8: Smart matching**, not started.
