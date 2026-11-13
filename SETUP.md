# Salhly setup

Salhly runs with dummy credentials out of the box. Switch to Supabase only
when you have a real project.

## 1. Dependencies

```bash
flutter pub get
```

Localization keys are generated into `lib/src/core/i18n/`. Regenerate after
editing `assets/translations/*.json`:

```bash
flutter pub run easy_localization:generate -S assets/translations -O lib/src/core/i18n -o locale_keys.g.dart
```

## 2. Demo mode (default)

`.env` ships with:

```dotenv
APP_MODE=demo
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-public-anon-key
```

In demo mode these values are ignored, no network call is made, and the app is
clearly labelled as demo. Sample accounts:

| Role | Email | Password |
|------|-------|----------|
| Customer | `customer@salahly.demo` | `Salahly123!` |
| Provider | `provider@salahly.demo` | `Salahly123!` |
| Sample marketplace provider | `marketplace-provider@salahly.demo` | `Salahly123!` |

Signup confirmation and password recovery use the code `123456` locally; no
email is sent.

The separate marketplace provider is an explicitly synthetic eligibility fixture
for **Plumbing** in **Cairo**. It does not approve a credential or change an M5
submission: ordinary demo providers/new submissions remain ineligible/pending.
To exercise M7, create a plumbing request as the customer, open its quotes screen,
publish a new non-sensitive summary with city `Cairo`, then sign in as the sample
marketplace provider and submit a quote. Switch back to the customer to accept,
then use both accounts' **My jobs** screens to progress and confirm completion.
Do not restart between these steps: all demo requests, quotes, and jobs are
in-memory only. No quotes, jobs, approvals, or notifications are generated to
pretend another person has acted.

For M8, open matching from an open plumbing request's quotes screen after
publication. Three explicitly synthetic discovery profiles illustrate ranking:
the sample marketplace account, a new provider without optional evidence, and
an experienced provider. The two extra candidates are discovery-only fixtures,
not sign-in accounts, credential reviews, submitted quotes, or completed jobs.
The sample marketplace profile declares 4 plumbing years, origin `30.04, 31.24`,
and Monday 09:00-17:00 hours; the experienced sample declares 10 years, origin
`30.12, 31.35`, and Monday 10:00-18:00. Try optional matching point `30.04, 31.24`
and Monday 10:00, then compare recommended with all eligible. Values are sample
assumptions, not measurements of real people. Ordinary demo providers can save
private settings but cannot enable discovery without actual eligibility.

## 3. Live mode (real Supabase)

1. Create a project at [supabase.com](https://supabase.com/).
2. Open **SQL Editor**, paste the entire contents of
   [`supabase/migrations/202610160001_salahly_foundation.sql`](supabase/migrations/202610160001_salahly_foundation.sql),
   and run it. It is safe to rerun and creates `profiles`,
   `service_categories`, and `notifications` with RLS and a signup trigger.
3. Then run the entire
   [`supabase/migrations/202610180001_provider_onboarding.sql`](supabase/migrations/202610180001_provider_onboarding.sql)
   as `postgres`. It adds provider setup tables, transactional RPCs, trusted
   review, and the private `provider-verification` Storage bucket.
4. Run the entire
   [`supabase/migrations/202610310001_service_requests.sql`](supabase/migrations/202610310001_service_requests.sql)
   as `postgres`. It adds owned service requests, immutable category snapshots,
   private photo metadata, transactional submit/cancel/read RPCs, and the private
   `request-photos` bucket.
5. Run the entire
   [`supabase/migrations/202611090001_quotes_and_jobs.sql`](supabase/migrations/202611090001_quotes_and_jobs.sql)
   as `postgres`. It adds separate consented marketplace listings, versioned
   quotes, unique assigned jobs, immutable history, and transactional RPCs.
   M6 request/photo table reads and Storage policies remain owner-only.
6. Run the entire
   [`supabase/migrations/202611110001_smart_matching.sql`](supabase/migrations/202611110001_smart_matching.sql)
   as `postgres`. It adds opt-in discovery settings and versioned matching rules,
   with owner-scoped and request-owner-scoped RPCs. Provider/request/photo and
   marketplace table policies remain private; matching does not publish old data.
   Run all five migrations in order. For a replay, use a maintenance/test window
   and reapply the whole sequence through M8; never leave a database running
   only an older migration's replacement functions. Existing rows are retained.
7. Verify database authorization by running
    [`supabase/tests/foundation_rls.sql`](supabase/tests/foundation_rls.sql).
   Also run
   [`supabase/tests/provider_onboarding_rls.sql`](supabase/tests/provider_onboarding_rls.sql).
   Then run
   [`supabase/tests/service_requests_rls.sql`](supabase/tests/service_requests_rls.sql).
   Then run
   [`supabase/tests/quotes_and_jobs_rls.sql`](supabase/tests/quotes_and_jobs_rls.sql).
   Finally run
   [`supabase/tests/smart_matching_rls.sql`](supabase/tests/smart_matching_rls.sql).
   All five suites roll back their fixtures. Storage SQL fixtures do not upload real
   files or prove the hosted Storage API's behavior.
8. In **Project Settings > API**, copy the project URL and the public
    publishable/anon key.
9. Put them in `.env` and switch the mode:

   ```dotenv
   APP_MODE=live
   SUPABASE_URL=https://YOUR-PROJECT.supabase.co
   SUPABASE_ANON_KEY=YOUR-PUBLIC-KEY
   ```

10. In **Authentication > Email Templates**, make the confirmation and recovery
   templates include the numeric `{{ .Token }}` so the in-app email-code screens
   work. The app verifies email codes, not deep links.

Never put the service-role key or any AI key in `.env`; the app rejects them.

### Provider setup and trusted review

Use sample documents in the prototype. Before collecting real credentials,
the operator must publish a privacy/retention policy, assign authorized
reviewers, establish an appeal/contact process, and approve a deletion and
abandoned-upload cleanup procedure. The app does not invent these policies.

Provider setup saves self-reported details, up to 20 active service categories,
up to 10 area labels, and one start/end range per weekday. Hours are local
wall-clock availability for each area, not time-zone-converted appointment
slots. A complete submission requires a 20-1,000 character introduction and
at least one service, area, and available day.

The gallery picker accepts one JPEG/PNG image up to 5 MiB and asks for explicit
consent before upload/submission. It uses the existing system image picker,
without adding camera or broad photo-library permission requests. Files use
random names under the owning user ID in `provider-verification`. The bucket
must remain private, with `file_size_limit = 5242880` and allowed MIME types
`image/jpeg` and `image/png`. The client checks length and file signatures;
the submission RPC checks ownership and Storage metadata. Do not assume MIME
metadata alone is a complete content/malware inspection.

Only an authorized operator using SQL Editor as `postgres`, or a trusted
server using `service_role`, can review. There is no client admin role or
approval button. For the prototype, the operator can inspect pending records:

```sql
select id, user_id, submitted_at, submitted_profile, document_path
from public.provider_verifications
where status = 'pending'
order by submitted_at;
```

Inspect the corresponding private object in the trusted Storage dashboard or
through a server-side authenticated download. Do not publish a document URL,
paste credentials into the app, or log document contents. After actually
reviewing a record, use its ID and an internal reviewer handle:

```sql
select public.review_provider_verification(
  p_verification_id => 'REPLACE_WITH_VERIFICATION_UUID'::uuid,
  p_decision => 'rejected',
  p_review_note => 'Please submit a clearer image of your trade certificate.',
  p_reviewer => 'operator-reviewer-handle'
);
```

The only decisions are `verified` and `rejected`, and only a pending record can
be reviewed. A rejection needs a nonblank note of at most 500 characters; an
approval may pass `null` for the note. The function retains reviewer/time audit
fields. Providers use **Check review status** to refresh; no automatic polling
or realtime review notification is implemented in M5. Pending details are
locked. Rejection permits a new file/submission, keeping the prior evidence.
Verified providers can edit self-reported service details without changing the
reviewed credential snapshot. Verification alone does not grant access to every
request: M7 also checks the current active skill and matching service-area label.

Unsubmitted uploads are cleaned up best-effort after a confirmed failure. An
ambiguous submission is reconciled before cleanup; if session/status checks
fail, cleanup is deferred rather than risking submitted evidence or using a
replacement account. Referenced evidence cannot be overwritten or deleted,
including rejected evidence. Consequently deleting an account with submission
records requires an explicit trusted retention/deletion procedure. Do not
delete rows from `storage.objects` directly: that does not remove the underlying
blob. A scheduled server-side orphan sweep is not included in this milestone.

### Customer service requests

M6 adds customer-only **New request**, **My requests**, and request details.
The existing Home/Notifications/Profile tab structure is unchanged. M7 providers
browse only separately published listings, never the customer-only request API.

The form keeps its draft in memory and performs no backend writes on typing,
step changes, gallery selection, or preview. It requires an active service,
a 5-120 character summary, a 10-2,000 character description, a 2-100 character
city/district, and 5-500 character address details. Location is entered manually:
no maps, geocoding, GPS calls, or new native permissions are introduced. A preferred
date/time is optional, must be in the next 180 days, is stored as a UTC instant,
and is displayed in the device's local time. It is not a confirmed appointment.

Use synthetic addresses and sample photos until a privacy/retention and account
deletion process is approved. Explicit consent is required before submission.
The gallery accepts at most three JPEG/PNG images, each at most 5 MiB; the
signature/size checks do not constitute malware/content inspection or EXIF
removal. The picker does not request full metadata, but bytes may still contain
embedded metadata. No photo is sent to the existing AI experiment automatically.

The `request-photos` bucket must remain private, with a 5 MiB object limit and
JPEG/PNG MIME types. Objects use `customerUUID/requestUUID/photoUUID.jpg|png`,
not user-supplied filenames. Only the owning authenticated customer can read the
M6 request/photo APIs. Submitted details and photo references are immutable;
M6 cancellation is idempotent `open` to `cancelled`, while M7 acceptance changes
`open` to `assigned` transactionally. Cancellation
retains history/photos and does not claim to delete personal data.

Submission uses stable request and photo IDs, sequential uploads, and one
transactional publish RPC. After a lost response, the client reconciles the exact
request and attachment manifest before claiming success. An absent read alone
does not prove an in-flight publication will not commit: uncertain outcomes keep
the original draft frozen for retry. Users leaving that state are directed to
history before starting another request. Photo-free requests are idempotent too.

Cleanup is best-effort and only for the current attempt's unreferenced objects
after a definitive failure. Conflicting/existing uploads, committed references,
failed reconciliation, and replacement sessions never trigger destructive
cleanup. SQL guards and foreign keys separately protect referenced objects,
including cancelled requests. Abandoned private uploads may require a trusted
operator sweep; no scheduled cleanup or account-erasure workflow is implemented.
Use the Storage API for blob cleanup, not direct deletion of `storage.objects`.

Owned history uses bounded keyset pagination and stored category names, so old
requests remain readable when a category is deactivated. Photos are fetched only
when explicitly opened, streamed under the byte limit, decoded at up to 1200x1200
(draft thumbnails at 320x320), and evicted on close or authorization loss. These
are memory/race safeguards, not measured device frame-rate guarantees.

### Quotes and jobs

M7 does not silently publish old requests. The customer must enter a separate
10-1,000 character public summary and 2-100 character city label and explicitly
consent on the quotes screen. Do not include names, contact details, addresses,
or other sensitive text in those fields. Listings cannot be edited after
publication; cancelling an open request removes it from the eligible feed.

Feed visibility and new/updated quotes require a current provider role, a verified
credential, the request's currently active category in the provider's skills,
and an exact case-insensitive match between trimmed service-area and public-city
labels. These are self-reported labels, not geocoded distance or an availability
guarantee. Matching/ranking, time-zone scheduling, and bookable slots are not M7.
Providers with existing quotes may still read their own quote and its public
listing after it closes or they become ineligible; they cannot edit closed terms.

Each provider has at most one quote per request. Quotes contain integer EGP minor
units (1-100,000,000 piastres), an estimated duration (1-43,200 minutes), and up to
1,000 characters of notes. The provider's name is snapshotted with the quote;
email, phone, verification documents, and competing providers' offers are not
exposed through provider quote reads. Pending/withdrawn quotes may be revised
while eligible and the request is open. Revisions prevent accepting unseen price
changes; withdrawing a quote does not revive or modify accepted terms.

Acceptance explicitly discloses the original title, description, city, address,
and preferred time to the selected provider. It does **not** share request photos
or credential evidence. The original preferred time is still a preference, not
a confirmed appointment. In one database transaction, acceptance locks/rechecks
the request, provider eligibility, and expected quote revision, accepts that
quote, closes pending competing quotes, creates one job, marks the request
assigned, and records the first history event. A unique accepted-quote index and
unique request/job association independently prevent double selection.

Job access uses immutable participant IDs, even after a provider changes skills
or loses feed eligibility. Accepted price, currency, duration, notes, and quote
revision are frozen. The lifecycle is:

| Current state | Allowed actor and next state |
| --- | --- |
| Selected | Provider: on the way or in progress; either participant: cancelled |
| On the way | Provider: in progress; either participant: cancelled |
| In progress | Provider: awaiting customer confirmation |
| Awaiting confirmation | Customer: completed |
| Completed / cancelled | Terminal; no reopening |

Cancelling a job does not reopen its assigned request or delete evidence. No
payments, automatic extras, reviews, disputes, or live notifications are added.
History records actual transitions; duplicate retries do not invent extra events.

The app retains exact interrupted mutation parameters in session memory. If a
response is lost and a canonical read cannot resolve it, alternative actions and
editing stay frozen. **Retry original action** replays the original consented
intent, including after closing/reopening its page, and then reloads authoritative
data. An empty read is not treated as proof that a server transaction will never
commit. No requests run using a replacement account's credentials. Restarting
clears this local retry memory, so review canonical request/quote/job status
before making another choice after a restart.

Publication and acceptance consent timestamps, quotes, and job history are
retained. Use only synthetic text/locations until privacy, retention, account
deletion, and reviewer operations are established; M7 does not invent those policies.

### Smart matching and discovery

M8 is discovery, not an invitation, automatic quote, or provider selection.
Customers open matching for their own **open, published** request and can view
recommendations or every eligible participating provider. New discovery requires
current provider role, latest trusted verification, the active request-category
skill, matching published-city/service-area label, and separate discovery opt-in
with consent. Hours and ranking scores never bypass those hard filters.
Label matching trims surrounding whitespace and ignores case, but does not
translate `Cairo` into Arabic, geocode districts, or establish geographic coverage.

Providers open matching settings from Profile. Settings are separate from M5
credential submission: opting in publishes a consented name snapshot and allowed
matching evidence, not private bios, phone/email, credential paths, review notes,
or job/customer details. Ordinary pending providers may retain private drafts,
but cannot enable discovery. Disabling discovery removes future matching access
without withdrawing an M7 quote or revoking an assigned job. Pure opt-out is
allowed after skill or verification loss; new experience entries still require
current active selected skills. Changed publication settings need fresh consent.
Name/consent snapshots and revisions make exact interrupted-save retries
idempotent; a retry does not silently republish a later profile name.

Provider origin and customer matching point are optional manually entered
latitude/longitude pairs, at most two decimal places, with explicit consent.
Provider points must be broad **public service origins**, not homes or sensitive
locations. An origin can be inferred through repeated distance queries even
though its raw coordinates are not returned on candidate cards. Customer points
start blank, are not copied from M6 addresses/preferences, are sent only to the
matching RPC, and are not saved in application tables or published to providers.
Infrastructure request logging/retention is a separate operator responsibility;
the app does not promise those logs do not exist.

Distance uses a bounded Haversine calculation on a 6,371.0088km-radius sphere and
is displayed to 0.1km between the coarse declared points. It is not GPS tracking,
road distance, travel time, actual availability, or verified coverage. No maps,
geocoding, PostGIS dependency, or native location permission is added. M8's
prototype population does not justify a spatial index yet; profile query plans
and add PostGIS deliberately if measured production scale requires it.

An optional weekday/time is explicitly **service-area wall time**, not an instant
converted from device time or private M6 `preferred_at`. Declared hours compare
ISO weekday 1-7 and minute 0-1439 using `[start, end)`. A supplied preference
outside declared hours scores zero; no preference or no schedule is unknown.
This is not a booked appointment, capacity check, DST conversion, or promise that
the provider is available now. Self-reported years are optional per current skill,
0-60, and are not certified by credential verification.

Default ranking assumptions:

| Factor | Initial Weight | Normalization |
| --- | --- | --- |
| Distance | 35 | `max(0, 1 - straight_line_km / 50)`, capped at 100 |
| Rating | 25 | Unavailable in M8: no fabricated reviews/stars |
| Declared hours | 20 | 100 inside declared hours, 0 outside, unknown without evidence |
| Self-reported relevant years | 20 | `min(years / 10, 1)`, capped at 100 |

Each factor is represented as 0-10,000 basis points. Unknown factors contribute
a fixed neutral **50/100** and remain marked unavailable. The total divides by
the **entire configured weight sum**, not just each provider's known factors.
This avoids inflated perfect scores from one piece of evidence and automatic
zero-rating penalties for new providers. Unknown data can outrank a known poor
fit under this policy; neutral is an assumption, not measured merit. Evidence
coverage is the known-factor weight share, not statistical confidence or a
probability of successful work. Scores/weights are not proven optimal. No
completion/response-rate quality signal is inferred from insufficient policy/data.

Recommended order uses total score, then a deterministic request-specific tie
key; all-eligible ignores score order/cutoffs and uses that tie key. Registration
time, provider name, and platform job volume do not win ties. Both modes are
bounded/keyset paginated and retain the complete hard-filtered population,
including eligible providers with missing optional signals. Cursors bind the
request, mode, canonical matching inputs, and rules revision. Changed inputs or
rules require restart; mutable provider data still requires refresh between pages.
The app labels retained previous/stale results and does not claim a frozen roster.

Only `postgres` can configure rules using the private trusted function. This
does not create a client admin privilege. Inspect the current revision first in
a maintenance/test environment; use the expected revision rather than blindly
overwriting another operator's change:

```sql
select * from public.matching_rules;
select salahly_private.configure_matching_rules(
  p_expected_revision => 1,
  p_distance_weight => 35,
  p_rating_weight => 25,
  p_availability_weight => 20,
  p_experience_weight => 20,
  p_distance_scale_km => 50,
  p_experience_cap_years => 10
);
```

Weights may be 0-1,000, with a positive total; the distance scale is 1-500km and
experience cap 1-60 years. Neutral remains 50/100. Publication settings and rules
survive migration reruns; RPC-only table/column ACLs and strict schema/policy
integrity checks reject unsafe drift. Review real-world fairness, consent,
location/log retention, accuracy, abuse controls, and query plans before release.

## 4. Native app name and package (manual)

`android/` and `ios/` are protected from tooling. To fully rebrand the launcher:

- `android/app/src/main/AndroidManifest.xml`: set `android:label="Salhly"`.
- `android/app/build.gradle.kts`: change `namespace` and `applicationId`
  (currently `com.example.nex_fit`), and move
  `android/app/src/main/kotlin/.../MainActivity.kt` to the matching package.
- iOS: update the display name and bundle identifier in Xcode.

Changing the Dart package name (`pubspec.yaml` -> `salahly`) does not rename
these native identifiers.

## 5. Splash screen (optional)

Place a logo at `assets/images/splash.png`, uncomment the `image:` paths in
`flutter_native_splash.yaml`, then run:

```bash
dart run flutter_native_splash:create --path=flutter_native_splash.yaml
```

## 6. Run

```bash
flutter run
```

## 7. Verify changes

```bash
flutter analyze
flutter test
```

### Disposable local PostgreSQL checks

The Node test runner starts its own authenticated, loopback-only native PostgreSQL
cluster. It accepts no remote DSN and never connects to an existing project. It
runs fresh migrations, rollback suites, populated ordered migration replay, and
optional independent-connection races. Every suite must emit its final PASS
notice and end in ROLLBACK; row digests also verify rollback/replay preservation.
The default run includes M8 and all five suites; `--through m7` or `--through m6`
explicitly selects an earlier prefix. `--concurrency` retains the independently
blocked M7 acceptance/lifecycle checks alongside the selected M8 suites.

Test-only Node dependencies are installed outside the application. The runner
requires an existing `<OS temp>/kilo` parent directory. Example in PowerShell:

```powershell
$deps = Join-Path $env:TEMP 'kilo/salahly-pg-verification'
npm install --prefix "$deps" --ignore-scripts --no-audit --no-fund embedded-postgres@18.6.0-beta.19 pg@8.23.1
node supabase/tests/run_local.mjs --deps "$deps" --concurrency
```

The cluster and generated password are removed and PostgreSQL stops on exit;
diagnostic logs stay in the reported temporary run directory. The bootstrap
simulates Auth identity claims and Storage metadata, not the hosted Auth,
PostgREST, or Storage services. Database concurrency is real, but it is not
end-to-end HTTP/session verification. See `MILESTONES.md` for recorded outcomes.

### Live integration checklist

Run these checks against a dedicated Supabase test project configured in
section 3, using synthetic customer/provider accounts. Demo and fake-transport
tests do not verify hosted Auth, email delivery, or HTTP authorization.

1. Run all five migrations in order and all five rollback-only RLS suites. Confirm
   their final `PASS: all Salahly ...` notices, not just generic successful-query
   results. Repeat against the actual Storage schema before using real files.
2. Sign up both roles with email confirmation enabled. Protected tabs must stay
   inaccessible until a valid email code is entered. Check the generated
   profile role and exactly one welcome notification for each new user.
3. Verify confirmation/resend and recovery emails contain usable numeric codes.
   Invalid or expired codes must fail; a recovery session must remain on the
   password-update screen until the new password is accepted.
4. Restart the app while signed in, then verify SDK session restoration, token
   refresh, and logout. After recovery, confirm that the old password fails and
   the replacement password works.
5. Through the app, browse active categories, edit allowed profile fields, and
   mark an owned notification read. With each account's authenticated API
   session, verify that foreign profiles/notifications are inaccessible and
   role, ownership, catalog, and notification-content writes are rejected.
6. Delay a profile request, then sign out or switch accounts before releasing
   its response. The old response must not restore the previous account or
   clear a pending password-recovery requirement.
7. With two synthetic providers and a customer, save/reopen drafts and submit
   a sample JPEG/PNG. The customer and other provider must not access the
   provider's rows, RPCs, or private objects, even through direct HTTP requests.
   Anonymous/public document URLs must fail. Test both named route navigation
   and deep links.
8. Test real uploads at and above 5 MiB, wrong MIME/extension, corrupt content,
   foreign/traversal paths, and overwrite/delete attempts on submitted evidence.
   Confirm the Storage API enforces bucket size/type settings for actual bytes,
   not just the metadata-only SQL fixtures. Reviewers must reject invalid
   content; metadata is not content inspection.
9. Reject a pending submission through the trusted review function, refresh in
   the app, then resubmit a new file. Approve a pending record and verify the
   app shows the actual decision. Client calls cannot approve/reject or alter
   audit fields. Check simultaneous submission/review/delete races using
   independent HTTP sessions; SQL fixture runs are not concurrency tests.
10. Interrupt upload and submission responses, then reload status before retry.
    A committed submission must not lose its evidence. Confirm best-effort
    cleanup removes only unreferenced uploads; exercise deferred cleanup and
    logout/account-switch/recovery during an in-flight upload/download. Check
    private image viewing on target devices, including gallery cancellation and
     supported image formats, with no persistent disk cache added by this feature.
11. With two synthetic customers and a provider, submit requests with zero and
    three sample photos, browse history, open private photos, and cancel. Test
    direct HTTP reads/writes and public object URLs: other users and providers
    must not access the address, photos, rows, or customer-only RPCs. Verify
    PostgREST's embedded photo metadata and pagination against the real service.
12. Retry the same request ID after a lost response, after cancellation, and
    after the category is deactivated or the preferred time has passed. Identical
    retries return the original request; changed details/attachment manifests
    must be rejected. Cancellation must not delete referenced photos.
13. Interrupt individual photo uploads and final publication; include 409
    conflicts, failed reconciliation, cleanup failure, logout/recovery, and
    same-user sign-out/sign-in while work is pending. Exercise simultaneous
    publish/cancel/delete attempts from independent HTTP sessions. No uncertain
     outcome may delete referenced files or silently change the submitted draft.
14. Use two customers and two trusted-reviewed providers to test M7 over actual
    authenticated HTTP. Unpublished text, other customers' requests, original
    locations before acceptance, photos, credential records, and competing quotes
    must remain inaccessible. Verify current role/credential/skill/category/area
    eligibility and that customer comparison contains only the intended projection.
15. Race quote acceptance against another quote, cancellation, revision, and
    withdrawal from independent HTTP sessions. Exactly one provider/job may win,
    and a stale displayed revision must not select changed terms. Drop responses
    and test exact retry after page changes, logout, recovery, and app restart.
16. Verify selected-provider original-detail access only after explicit acceptance
    consent; request photos remain customer-only. Exercise both roles' job states,
    pre-work cancellation, terminal states, immutable terms/history, duplicate
    transition retries, and immediate old-account hiding during account switches.
17. Exercise M8 with two customers, reviewed/ordinary providers, optional and
    missing evidence, different service areas, inactive skills, and discovery
    opt-out. Through direct authenticated HTTP verify foreign/unpublished/closed
    requests and private matching/profile/request/photo/credential tables remain
    inaccessible. Only the consenting name and approved factor projection may
    appear; raw provider origins and customer query points must not enter feeds.
18. Compare cold-start, known-zero, near/far, and custom-weight scenarios over
    actual PostgREST. Test equal-score pagination, all-eligible completeness,
    config/query changes with old cursors, provider changes mid-page, and dropped
    settings responses followed by exact retry/opt-out after eligibility loss.
    Test account switches/recovery/relogin and phone RTL/large-text/keyboards.
    Verify logging/retention policy and public-origin consent before using real
    data; these local rules do not establish real-world fairness or accuracy.

The SQL-only checks exercise migration, grants, triggers, RLS, and local database
races under simulated identity claims. They do not replace live integration checks.
Native branding remains the separate manual task in section 4. Realtime belongs
to a later functional milestone. Hosted Storage verification and on-device
performance profiling remain outstanding; SQL, fake-transport, and widget
results must not be described as measured device FPS or hosted acceptance.
