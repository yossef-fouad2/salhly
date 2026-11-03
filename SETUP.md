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

Signup confirmation and password recovery use the code `123456` locally; no
email is sent.

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
   `request-photos` bucket. Run all three migrations in order; each supports
   rerunning its own version without discarding existing records.
5. Verify database authorization by running
    [`supabase/tests/foundation_rls.sql`](supabase/tests/foundation_rls.sql).
   Also run
   [`supabase/tests/provider_onboarding_rls.sql`](supabase/tests/provider_onboarding_rls.sql).
   Then run
   [`supabase/tests/service_requests_rls.sql`](supabase/tests/service_requests_rls.sql).
   All three suites roll back their fixtures. Storage SQL fixtures do not upload real
   files or prove the hosted Storage API's behavior.
6. In **Project Settings > API**, copy the project URL and the public
    publishable/anon key.
7. Put them in `.env` and switch the mode:

   ```dotenv
   APP_MODE=live
   SUPABASE_URL=https://YOUR-PROJECT.supabase.co
   SUPABASE_ANON_KEY=YOUR-PUBLIC-KEY
   ```

8. In **Authentication > Email Templates**, make the confirmation and recovery
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
reviewed credential snapshot; this does not grant job/booking access.

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
The existing Home/Notifications/Profile tab structure is unchanged. Providers
cannot browse requests yet; quotes, provider selection, and job tracking are M7.

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
not user-supplied filenames. Only the owning authenticated customer can read
requests and photos. Published request details and photo references are immutable;
the only client state change is idempotent `open` to `cancelled`. Cancellation
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

### Live integration checklist

Run these checks against a dedicated Supabase test project configured in
section 3, using synthetic customer/provider accounts. Demo and fake-transport
tests do not verify hosted Auth, email delivery, or HTTP authorization.

1. Run all three migrations in order and all three rollback-only RLS suites. Confirm
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

The SQL-only PGlite checks exercise migration, grants, triggers, and RLS under
simulated database roles. They do not replace these live integration checks.
Native branding remains the separate manual task in section 4. Realtime belongs
to a later functional milestone. Hosted Storage verification and on-device
performance profiling remain outstanding; SQL, fake-transport, and widget
results must not be described as measured device FPS or hosted acceptance.
