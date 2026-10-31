# Design system - Salahly

These are the scaffold's shared conventions, not a finalized Salahly visual design.
Keep feature UI minimal until a product design is approved.

---

## Theme overview

- **Preset:** `material3`
- **Material 3:** Primary app chrome uses Material 3 theming in `lib/src/theme/theme.dart`.
- **Dark mode:** Light and dark themes are supported; app can follow system brightness. Use semantic colors — do not branch on brightness in widgets for basic surfaces.
- **Customization:** Global `ThemeData` lives in `lib/src/theme/theme.dart` — avoid one-off `ThemeData` overrides in feature widgets.

- **Seed color:** `#FFFFFF` (used to derive `ColorScheme` via `ColorScheme.fromSeed` where applicable).

---

## Color system

- Use `context.colors` (`ColorScheme`) for standard Material roles: `primary`, `onPrimary`, `secondary`, `surface`, `onSurface`, `error`, etc.
- Use `context.appColors` for semantic extensions: `success`, `warning`, `info`, and their `on*` / container variants (see `lib/src/theme/color_schemes.dart`).
- Definitions: `lib/src/theme/color_schemes.dart`, applied through `lib/src/theme/theme.dart`.
- **Do not** hardcode hex colors in widgets — use theme roles or `appColors`.

---

## Typography

- Use `context.textTheme` (alias `context.typography`) for all text styles.
- Roles follow Material 3: `display*`, `headline*`, `title*`, `body*`, `label*`.
- No custom fonts uploaded — platform default typography (Roboto / SF Pro) via Material/Cupertino theme.

---

## Spacing, borders, motion

Import tokens via `package:salahly/src/theme/theme_constants.dart`.

| Token class | Purpose |
|-------------|---------|
| `AppSpacing` | Padding, gaps (`xxs` … `xxxl`, plus `pagePadding`, `itemGap`, `cardPadding`) |
| `AppBorders` | Border radii (`xs` … `xl`, `button`, `card`, `input`, `dialog`, …) |
| `AppShadows` | Elevation shadows (`none`, `subtle`, `card`, `elevated`, `modal`) |
| `AppDurations` | Animation durations (`fast`, `normal`, `medium`, `slow`, …) |
| `AppCurves` | Standard curves (`standard`, `emphasized`, `pageEnter`, …) |

**Rules**

- Do not use magic numbers for padding — use `AppSpacing`.
- Do not use inline `BorderRadius.circular(n)` — use `AppBorders`.
- Prefer Material 3 tonal elevation on `Card` / `Surface` — custom shadows only via `AppShadows`.

`AppCard` supplies a shaped Material surface, so child switches, checkboxes,
and ink responses paint correctly. Do not add an opaque decoration between
interactive Material controls and their Material ancestor.

---

## Motion and performance

The shared helpers in `lib/src/shared/motion/` reuse `AppDurations` and
`AppCurves`. They add interaction polish without changing the visual theme.

- `AppMotion.durationOf(context, duration)` respects system reduced motion.
- `StaggeredEntrance` owns one finite timeline; `EntranceItem` uses a slice of
  it for a small opacity/paint-transform reveal. Keep the group mounted across
  search and refresh so updates do not replay its entrance.
- `PressableScale` supplies a `WidgetStatesController` to the wrapped Material
  button or `InkWell`. Native states preserve keyboard, ripple, disabled, and
  scroll-cancellation behavior; no competing gesture detector is added.
- Tab transitions retain navigators while disabling inactive tickers and focus.
- Long lists use lazy builders. Refreshing existing data must not replace it
  with a full-page spinner or discard the scroll position.
- Avoid decorative animation loops, per-row entrance controllers, animated
  layout measurements, blur, and crossfading two live tab trees.
- Repaint boundaries and opacity layers have costs; do not add them everywhere
  or claim GPU/FPS improvements without profiling a real device.

```dart
PressableScale(
  builder: (states) => TextButton(
    statesController: states,
    onPressed: save,
    child: Text(label),
  ),
)
```

---

## Responsive scaling (ScreenUtil)

- `ScreenUtilInit` is already applied in the app wrapper — do not add another.
- Design size baseline: **390×844** (iPhone 14 class).
- In templates and new code, use the `res` convention: widths `.w`, heights `.h`, radius `.r`, font sizes `.sp` when ScreenUtil is enabled.
- ScreenUtil values are runtime — avoid `const` widgets that depend on `.w` / `.sp`.
- `AppSpacing` getters already apply `.r`; do not apply `.w`, `.h`, or `.r` again.

---

## Context extensions

Defined in `lib/src/extensions/context_extension.dart`:

| Member | Use |
|--------|-----|
| `context.colors` | `ColorScheme` |
| `context.textTheme` / `context.typography` | Text styles |
| `context.appColors` | Semantic success/warning/info |
| `context.designTokens` | Theme extension tokens |
| `context.isDarkMode` | Brightness check |
| `context.width` / `context.height` | Screen size |
| `context.showAppDialog` | Dialog helper |
| `context.showTypedSnackBar` | Status snackbars |

Prefer these shortcuts over repeating `Theme.of(context)` in widgets.

---

## Component conventions

- Reusable widgets belong in `lib/src/shared/widgets/`.
- Default style parameters to theme values, not hardcoded colors.
- Widget file names match the widget class (`primary_button.dart` → `PrimaryButton`).
- Do not read theme inside `const` constructors.

Provider onboarding reuses `AppCard`, `AppButton`, and `AppTextField` in three
feature-local sections rather than adding a second design system or wizard
package. Layout and styling can change without changing the immutable models,
repository, or cubit. Only the active section is mounted; inputs are retained
in the draft, and save/submit actions are explicit. Typing does not rebuild the
service chips or perform backend writes. Private document previews load on
demand, use a bounded decode target, and evict their image-cache entry on close.

### Dark mode checklist

- No raw `Colors.white` / `Colors.black` for surfaces — use `colorScheme` roles.
- Verify new screens in both light and dark theme.

---

## Localization

- User-visible strings use `easy_localization` — files in `assets/translations/`.
- Do not hardcode display strings in widgets.
- Add keys to JSON translation files, then run the generate command in **SETUP.md**.
- Use interpolation in JSON — do not concatenate translated strings in Dart.

---

## Do / Don't

**Do**

- `context.colors` / `context.appColors` for color
- `context.textTheme` for typography
- `AppSpacing`, `AppBorders`, `AppShadows`, `AppDurations`, `AppCurves` for layout and motion
- `showAppDialog` and shared widgets for consistent UX

**Don't**

- Hardcode hex colors or arbitrary font families in widgets
- Magic padding/radius numbers
- Duplicate theme definitions per screen
- Bypass design tokens for one-off “quick” UI

For agent workflows and architecture boundaries, see **[AGENTS.md](AGENTS.md)**.
