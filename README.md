# Salahly

Salahly is a local home-services platform that connects customers with
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
- Notifications: per-user inbox with read state.
- Profile: editable name, phone, and city, plus a language switch (English/Arabic).
- Provider setup: saved professional details, service skills/areas, weekly
  availability, private credential submission, and trusted-review status.
  Open **Manage provider setup** from a provider's Home or Profile tab.
- Interaction polish: reduced-motion-aware transitions, retained tab input,
  Material press feedback, and lazy notification rows that stay visible on refresh.
- All UI is intentionally minimal Material 3; no final visual design yet.
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
create a project, run both migrations in order (foundation, then provider
onboarding), and put your public URL/key in `.env`. The setup guide also covers
private Storage and the trusted-only review operation.

## Not built yet

Service requests, quotes, job tracking, realtime/push notifications, ratings,
complaints, warranties, price estimation, and the AI diagnosis assistant are
future milestones described in [MILESTONES.md](MILESTONES.md). The UI says so
where relevant instead of showing dead buttons.

## Verification

```bash
flutter analyze
flutter test
```

Local checks cover demo flows, offline client behavior, responsive/RTL layouts,
and motion/rendering regressions. SQL/grants/triggers/RLS checks also pass on
isolated PGlite PostgreSQL, not hosted Supabase. Real Auth, OTP email delivery,
SDK session lifecycle, hosted private Storage, and HTTP authorization still require the dedicated test
project checks in [SETUP.md](SETUP.md#live-integration-checklist). Device frame-rate
and raster performance have not been measured.

No native platform folders were modified; the Android application ID and
launcher label still need a manual change (see SETUP.md).
