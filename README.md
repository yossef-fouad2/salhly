# Salhly

Salhly is a local home-services platform that connects customers with
professionals such as plumbers, electricians, carpenters, and technicians.

It is built on a Flutter scaffold. See [MILESTONES.md](MILESTONES.md) for the
feature roadmap, [AGENTS.md](AGENTS.md) for architecture rules,
[DESIGN.md](DESIGN.md) for UI tokens, and [SETUP.md](SETUP.md) for setup.

## What works now

- Authentication: sign in, sign up with a customer/provider role, email
  confirmation, password recovery, session restore, and sign out.
- App shell with a three-destination bottom navigation: Home, Notifications,
  Profile. Icons are Material defaults and easy to replace later.
- Home: role-aware greeting, service-category browsing and search.
- Customer requests: a three-step form with a category, problem description,
  manually entered location, optional preferred time, and up to three private
  photos. Open **New request** or choose **Request this service** on a category.
- Request history/details: owned, paginated requests, private on-demand photo
  viewing, and cancellation. **My requests** is available from Home and Profile.
- Quotes: explicitly publish a separate public summary/city, browse eligible
  requests as a provider, submit/update/withdraw EGP quotes, and compare offers.
  Acceptance checks the displayed revision and selects one provider atomically.
- Jobs: participant-only details, frozen accepted terms, recorded status history,
  provider progress updates, customer completion confirmation, and pre-work
  cancellation. Open **My jobs** from Home or Profile.
- Matching: opt-in provider discovery for an open published request, explainable
  rule-based recommendations, and all-eligible browsing. Optional coarse points,
  service-area wall-clock hours, and self-reported category experience contribute
  only when provided; unknown factors use an explicitly neutral prior.
- Notifications: per-user inbox with read state.
- Profile: editable name, phone, and city, plus a language switch (English/Arabic).
- Provider setup: saved professional details, service skills/areas, weekly
  availability, private credential submission, and trusted-review status.
  Open **Manage provider setup** from a provider's Home or Profile tab.
- Interaction polish: reduced-motion-aware transitions, retained tab input,
  Material press feedback, and lazy notification rows that stay visible on refresh.
- UI follows the supplied `ui design/` references with Salhly branding, pale-blue
  surfaces, dark primary actions, amber accents, and matching light/dark themes.
- Credential submission is not approval. Demo submissions stay pending with
  no real review. Use sample documents until a privacy/retention policy and
  operational reviewer process are established.

## Two backends, one codebase

The app runs in one of two modes selected by `APP_MODE` in `.env`:

- `demo` (default): clearly labelled local sample data. No Supabase connection
  and no real email. Demo accounts, edits, and passwords reset on restart.
- `live`: real Supabase Auth and RLS-protected repositories. Requires a real
  project URL and a public (publishable/anon) key.

The app never ships or accepts a service-role, secret, or AI key.

## Getting started

```bash
flutter pub get
flutter run
```

Demo mode works immediately. To use Supabase, follow [SETUP.md](SETUP.md):
create a project, run the five migrations in order (foundation, provider
onboarding, service requests, quotes and jobs, matching), and put your public URL/key in `.env`. The setup
guide also covers private Storage, request consent/retention, and trusted review.

For a complete local marketplace walkthrough, use the customer account and the
separate `marketplace-provider@salahly.demo` account, both with `Salahly123!`.
That provider is an explicitly synthetic plumbing/Cairo eligibility fixture,
not a reviewed M5 submission. Ordinary demo provider submissions still remain
pending. Quotes and jobs are created by user actions, not fabricated automatically.

Open matching from a published request's quotes screen. The demo includes two
additional, explicitly synthetic discovery-only candidates to illustrate missing
data and different experience; they cannot sign in or submit quotes. Matching
settings are separate from M5 credential review and never approve an ordinary
provider. See `SETUP.md` for optional sample points and service-area hours.

## Not built yet

Realtime/push notifications, ratings,
complaints, warranties, price estimation, and the AI diagnosis assistant are
future milestones described in [MILESTONES.md](MILESTONES.md). The UI says so
where relevant instead of showing dead buttons.

Original requests remain private unless the customer explicitly accepts a quote
and consents to sharing their original text/location with that selected provider.
The open feed contains only the separately consented summary, city label, and
category metadata. Request photos stay customer-only even after acceptance.
A preferred time is not a booked appointment; cancellation does not delete photos.
Demo requests/photos stay in memory and reset on restart. Interrupted submissions
retain a stable request ID; uncertain outcomes lock editing until reconciled.
M7 retains the original interrupted action for explicit retry across page changes.

Provider discovery requires a separate opt-in to sharing the consented name and
matching signals. Optional coarse work origins are inferable/public through
distance queries; never use a private home location. Customer matching points
are not saved in application tables or sent to providers. Distance is spherical
straight-line, hours are self-reported, experience is not certified, and scores
are configurable assumptions rather than probabilities of quality or success.
No rating is invented for missing reviews, and missing-factor neutral scores are
shown separately from actual evidence.

## Verification

```bash
flutter analyze
flutter test
```

Local checks cover demo flows, offline client behavior, responsive/RTL layouts,
and motion/rendering regressions. The local SQL runner checks migrations, grants,
triggers, RLS, and independent-connection quote/job races on disposable native
PostgreSQL. See the verification record in [MILESTONES.md](MILESTONES.md) for
actual results. These are not hosted Supabase checks. Real Auth, OTP email delivery,
SDK session lifecycle, hosted private Storage, and HTTP authorization still require the dedicated test
project checks in [SETUP.md](SETUP.md#live-integration-checklist). Device frame-rate
and raster performance have not been measured.

No native platform folders were modified; the Android application ID and
launcher label still need a manual change (see SETUP.md).
