# Salahly setup

Salahly runs with dummy credentials out of the box. Switch to Supabase only
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
   review, and the private `provider-verification` Storage bucket. Both
   migrations support rerunning their own version; do not skip the foundation.
4. Verify database authorization by running
    [`supabase/tests/foundation_rls.sql`](supabase/tests/foundation_rls.sql).
   Also run
   [`supabase/tests/provider_onboarding_rls.sql`](supabase/tests/provider_onboarding_rls.sql).
   Both suites roll back all fixtures. Storage SQL fixtures do not upload real
   files or prove the hosted Storage API's behavior.
5. In **Project Settings > API**, copy the project URL and the public
    publishable/anon key.
6. Put them in `.env` and switch the mode:

   ```dotenv
   APP_MODE=live
   SUPABASE_URL=https://YOUR-PROJECT.supabase.co
   SUPABASE_ANON_KEY=YOUR-PUBLIC-KEY
   ```

7. In **Authentication > Email Templates**, make the confirmation and recovery
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

## 4. Native app name and package (manual)

`android/` and `ios/` are protected from tooling. To fully rebrand the launcher:

- `android/app/src/main/AndroidManifest.xml`: set `android:label="Salahly"`.
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

1. Run both migrations in order and both rollback-only RLS suites. Confirm
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

The SQL-only PGlite checks exercise migration, grants, triggers, and RLS under
simulated database roles. They do not replace these live integration checks.
Native branding remains the separate manual task in section 4. Realtime belongs
to a later functional milestone. Hosted Storage verification and on-device
performance profiling remain outstanding; SQL, fake-transport, and widget
results must not be described as measured device FPS or hosted acceptance.
