# iOS 27 design-language compatibility check — Overeasy (Ladle)

Date: 2026-08-31 · Branch: `ui/watch-recipe-polish`

## What was checked and how

iOS 27 shipped after this assistant's knowledge cutoff, so nothing here is
recalled from training. Every claim below comes from running the app on the
iOS 27.0 simulator runtime installed on this machine and diffing it against
iOS 26.5, pixel by pixel.

Three configurations, all on the **same device model (iPhone 17)**, status bar
frozen at 9:41 so diffs need no masking:

| Config | Build SDK | Runtime | Meaning |
| --- | --- | --- | --- |
| **A** | iOS 26.5 | iOS 26.5 (`614AF85D`) | today's baseline |
| **B** | iOS 26.5 | iOS 27.0 (`92158C96`) | what shipped users get on updating |
| **C** | iOS 27.0 | iOS 27.0 (`DF3DB4C0`) | after rebuilding against the new SDK |

Toolchains: Xcode 26.6 (17F113, iOS 26.5 SDK) and Xcode 27 beta 4 (27A5228h,
iOS 27.0 SDK). Runtime iOS 27.0 (24A5390f) is a **beta seed** — findings may
shift before GA.

## Headline results

**1. Both builds compile clean.** The app builds against the iOS 27.0 SDK with
no errors and no new warnings or deprecations (4 warnings on 26.5, 6 on 27.0,
same content). None of the iOS 27 source-level changes bite here.

**2. Rebuilding changes nothing: B vs C = 0.000% pixel difference** on every
screen tested. The new design tokens apply to the *already-shipped binary*.
Whatever iOS 27 does to this app, it does the day a user updates, whether or
not you ship a build.

**2b. An opt-out still exists, but only until you build with Xcode 27 — and
you do not want it.** See "The compatibility flag" below.

**3. Info.plist already satisfies the reported new SDK requirements.** `UILaunchScreen`
is present, there is no `UIRequiresFullScreen`, and the app is already on the
SwiftUI scene lifecycle (`WindowGroup`).

**4. One real regression: the Watch tab bar inverts.** See below.

**5. One systemic change: glass is more transparent and gains a hairline rim.**
Every floating glass container is affected — tab bar, toolbar capsules, menus,
popovers. Content surfaces (typography, cards, photography, graphite grounds)
are untouched.

## The compatibility flag — tested, not assumed

Secondary sources claim `UIDesignRequiresCompatibility` is "completely ignored"
on iOS 27. That is half right, and the half that is wrong matters. Tested
directly by patching the flag into the built app bundle's `Info.plist`:

| Build | Flag | Result on iOS 27.0 |
| --- | --- | --- |
| iOS 26.5 SDK | set | **Honored** — legacy, pre-Liquid-Glass chrome |
| iOS 27.0 SDK | set | **Ignored** — 0.000% different from the normal glass build |

So the opt-out survives exactly as long as you keep shipping from Xcode 26.
Build once with Xcode 27 and it stops working, permanently.

**Do not reach for it as a fix for Finding 1.** It is all-or-nothing and it
reverts the *entire app* to pre-iOS-26 appearance: the floating tab bar becomes
a flat opaque bottom bar, and the toolbar capsules lose their containers
entirely, leaving bare icons. On the Watch screen specifically it is *worse*
than iOS 27 — the tab bar becomes a fully opaque light-grey slab across the
bottom of the video, rather than translucent glass.

It is worth knowing the escape hatch exists and when it expires. It is not
worth using here.

## Finding 1 — Watch tab bar inverts (the only real regression)

On iOS 26.5 the tab bar over Watch video renders **dark glass with white
labels**. On iOS 27 it renders **light glass with dark labels**.

Measured tab-bar background luminance (mean RGB):

| | app in light mode | app in dark mode |
| --- | --- | --- |
| iOS 26.5 | 40 (dark) | 37 (dark) |
| iOS 27.0 | **152 (light)** | 67 (dark) |

That table is the mechanism. On iOS 26.5 the bar stayed dark in *both*
appearances — its glass derived its appearance from the **content behind it**
(the video). On iOS 27 it tracks the **app's colour scheme** instead.

Contrast consequences, light mode, over video:

| Element | iOS 26.5 | iOS 27.0 |
| --- | --- | --- |
| Unselected labels | 12.94:1 | 7.45:1 (still passes AA) |
| **Selected tab label ("Watch")** | 2.67:1 | **1.39:1 — fails WCAG AA** |

The selected label is what tells you which tab you are on, and at 1.39:1 it is
close to invisible. It was already marginal at 2.67:1.

**Root cause.** `WatchView` forces dark chrome at
`Ladle/Library/WatchView.swift:377`:

```swift
.environment(\.colorScheme, hasPlayableVideo ? .dark : systemColorScheme)
```

That override is scoped to WatchView's own overlay chrome. The `TabView` lives
above it, at `Ladle/Library/LibraryView.swift:234`, so it never saw the
override — on iOS 26.5 it didn't need to, because the glass read the backdrop.
On iOS 27 it does.

**Who is affected:** light-mode users on the Watch tab. Dark-mode users are
fine (bar stays dark at 67).

**Direction for a fix** (not applied — this was a check): hoist the dark colour
scheme so the tab bar participates, e.g. apply it to `watchTab` in
`LibraryView` rather than inside `WatchView`, or set the tab bar's scheme
explicitly for that tab. Verify against the 1.39:1 number above.

## Finding 2 — Glass is more transparent, with a hairline rim

Systemic and cosmetic, but it works against this app's own design brief.
iOS 26 glass = fairly opaque fill + soft diffuse shadow. iOS 27 glass = more
transparent + a crisp hairline border, less shadow.

Where it shows most:

- **Context menus / popovers over food photography** (10.3% and 9.1% of pixels
  changed) — the dish behind now reads clearly through the menu panel.
- **Tab bar** — recipe titles scrolling underneath are legible through the bar.
- **Toolbar capsules** on Recipe Detail and the Library's account/add pill.

`DESIGN.md` states "Food photography is the most saturated element in the
library." iOS 27 pushes more of that saturation up through the chrome. Nothing
fails a contrast threshold here, but menu text over a bright dish is the spot
to review by eye.

Dark mode is affected roughly 2–3× more than light (6.3–10.6% of pixels vs
0.3–3.5%), because the lightened glass separates more from the near-black
ground. No contrast failures found in dark mode.

## Per-screen results

Percentage = share of pixels differing between iOS 26.5 and iOS 27.0.
Everything not called out is a chrome-only change from Finding 2.

### Light mode

| Screen | Diff | Verdict |
| --- | --- | --- |
| Watch | 7.48% | **Regression — Finding 1** |
| Card context menu (long-press) | 10.26% | Transparency — review legibility |
| View-mode menu (Grid/List/Gallery) | 9.12% | Transparency — review legibility |
| Discover | 3.47% | Chrome only |
| Library (grid) | 3.34% | Chrome only |
| Inbox | 1.87% | Chrome only |
| Recipe Detail | 1.80% | Chrome only |
| Detail — overflow menu | 1.80% | Chrome only |
| Detail — scrolled to bottom ("Start Cooking" CTA clears the bar) | 0.93% | Clean |
| Account / Settings sheet | 0.85% | Chrome only |
| Filter sheet | 0.85% | Chrome only |
| Privacy detail | 0.85% | Chrome only |
| Empty library | 0.78% | Clean |
| Onboarding walkthrough 1–3 | 0.27 / 0.27 / 0.75% | Clean |
| Add-recipe sheet | 0.44% | Clean |
| Full recipe (cooking) | 0.34% | Clean |
| Focus Mode | 0.26% | Clean |
| Welcome | 0.26% | Clean |

Welcome, Focus Mode and the walkthrough are near-zero because they are
full-bleed app grounds with no system chrome — the design language has nothing
to restyle.

### Dark mode

| Screen | Diff | Verdict |
| --- | --- | --- |
| Recipe Detail | 10.56% | Chrome only |
| Watch | 9.72% | Chrome only (bar correctly stays dark) |
| Discover | 7.46% | Chrome only |
| Library | 7.14% | Chrome only |
| Inbox | 6.32% | Chrome only |

## Static risks reviewed

| Spot | Status |
| --- | --- |
| `.toolbarBackground(porcelain, .visible)` — `RecipeDetailView.swift:174`, `FullRecipeView.swift:47` | **Already inert.** Toolbars render as floating glass capsules on both 26.5 and 27.0; the opaque porcelain fill is not applied. Dead code, not a break. |
| `UISegmentedControl.appearance()` — `LadleApp.swift:96` | Still works on 27.0 (white thumb, ink text on the Watch picker). A global UIKit appearance proxy is the fragile way to do this; worth revisiting since its stated reason is the dark Watch chrome that Finding 1 changes. |
| `.ultraThinMaterial` / `.thinMaterial` — `RecipeGridCard.swift:27`, `DiscoverView.swift:481`, `FilterSheet.swift:79` | No change observed. |
| `WatchView` manual safe-area plumbing + `ignoresSafeArea` | No layout break; no clipping or overlap found on 27.0. |
| `UILaunchScreen` / `UIRequiresFullScreen` / scene lifecycle | Compliant. |

## Screens NOT covered

Not reachable without specific app state or extra fixtures, and therefore not
checked. They share the same components, so Finding 2 likely applies, but this
is untested:

RecipeEditor · NutritionView · HealthExportSheet · VideoEmbedSheet ·
ReimportSheet · FailedImportSheet · CorrectionNotesView · SyncConflictReviewView ·
GuestLimitView · AllRecipesView as a pushed screen · Inbox job detail states ·
**LadleShare share extension (`ShareConfirmationView`)**

## Reproducing

Simulators left booted: `614AF85D` (26.5), `92158C96` (27.0),
`DF3DB4C0` (27.0, SDK-27 build, created for this pass — safe to delete).
Captures and the diff script are in the session scratchpad. Launch recipe used
throughout: `-ui-testing -onboarding-complete`.
