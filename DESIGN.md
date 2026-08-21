# Ladle Design System — "Butter & Basil"

Status: approved implementation source of truth

## Concept

Overeasy is a sunny deli counter. Butter carries the chrome like an awning,
warm white carries the reading surfaces, deep basil is the ink and the
cooking ground, and tomato is the single appetizing action color. Everything
on screen should look edible; nothing should read cold or clinical.

## Scene

A home cook saves and sorts recipes one-handed on the couch, then reads
Overeasy from a bright kitchen counter with wet or floury hands. Browsing is
sunny and appetizing. Cooking is high contrast, calm, and legible at a
glance.

## Design principles

- Native iOS behavior comes first. Use SwiftUI navigation, sheets, menus,
  alerts, controls, safe areas, and SF Symbols.
- The butter band is the brand: app chrome (top bar, section picker) sits on
  butter in both appearances.
- Surfaces are flat and confident: no outlines, no drop shadows, no glass
  effects. Color blocks do the work.
- Tomato appears for actions and favorites, never decoration. Tomato and
  basil are kept apart at large scale; Focus Mode pairs basil with butter
  gold so the screen never reads as red-on-green.
- Food photography is the most saturated visual element on warm white.
- Dynamic Type, VoiceOver, Reduce Motion, and 44-point targets are preserved.
- Long content scrolls. Primary actions stay reachable without covering
  ingredients, steps, or form fields.

## Color

Legacy token names in code carry the new roles (see `LadleTheme`).

| Role | Code token | Light | Dark | Use |
| --- | --- | --- | --- | --- |
| Butter | `butter` | `#F7E082` | `#2E290F` | Chrome band |
| Warm white | `paper` | `#FFFBEB` | `#15190D` | Primary reading surface |
| Butter-light | `oat` | `#FAF0C0` | `#231F0E` | Cards, fields, secondary surfaces |
| Deep basil | `ink` | `#253312` | `#F6F2DC` | Primary text and controls |
| Basil ground | `plum` | `#2E4517` | `#233611` | Focus Mode, Watch, selected controls, welcome |
| Tomato | `brick` | `#C0391B` | `#E8552E` | Primary actions |
| Basil leaf | `celery` | `#A3C46E` | `#39491F` | Success states |
| Pistachio wash | `ube` | `#EDEFD6` | `#20260F` | Inactive controls, quiet grouping |
| Muted olive | `mutedInk` | `#6C6C4E` | `#B8B694` | Secondary text |
| Deep tomato | `accentText` | `#A63A1B` | `#FF9973` | Favorites, warm accents, tinted icons |
| On-dark cream | `onAccent` | `#FFFBEB` fixed | same | Text and icons on basil and tomato |
| Fixed basil | `onYolk` | `#253312` fixed | same | Text on fixed light fills (timer card, focus CTA) |
| Butter gold | `focusGold` | `#F6D95C` fixed | same | Focus Mode eyebrow, progress, advance button |

Tomato fills always carry cream `onAccent`. Errors use the system
destructive role.

## Typography

All SF Pro (standard design).

- Display and screen titles: black weight, expanded width. The chunky
  grotesque wordmark treatment is part of the identity.
- Recipe names and section headings: heavy weight, standard width.
- Body, controls, ingredients, metadata: regular/medium SF Pro.
- Eyebrows: semibold condensed.
- Long cooking instructions prioritize distance legibility over personality.
- Body copy uses semantic Dynamic Type styles with scaled custom sizes where
  the approved hierarchy requires them.

## Shape and spacing

- Circular icon controls are at least 44 points.
- Primary controls and fields use 14 to 16-point continuous corners.
- Prominent images and grouped surfaces use 18 to 22-point continuous corners.
- Sheets use the native presentation shape and drag indicator.
- Use 8, 12, 16, 24, and 32-point spacing roles.
- Flat color blocks separate content; no strokes or shadows on cards.

## Components

### Chrome band

- `LibraryView` wraps the top bar and section picker in a butter band that
  extends into the top safe area.
- The wordmark renders in deep basil ink; quiet icon buttons are warm-white
  circles; the add button is tomato with cream.

### Buttons

- Primary: tomato fill, cream label, full width when it advances the task.
- Secondary: butter-light fill, basil ink label.
- Quiet: text-only for cancellation or optional paths.
- Destructive actions use the system destructive role.
- Press feedback lasts 150 to 200 milliseconds and respects Reduce Motion.

### The tomato timer

- `RecipeTimerButton` leads with a circular ring that drains as time runs;
  the ring is tomato while running and completes in the card's foreground.
- In Focus Mode the timer card is fixed cream with fixed basil `onYolk`
  content so it reads identically in light and dark appearance.

### Navigation

- Home and All Recipes share a native segmented control inside the band.
- Search is presented only when summoned.
- Sort uses a native menu. Filters use a native sheet.
- Recipe actions use a sheet so cooking content remains primary.

### Async and recovery states

- A circular state symbol, direct heading, short explanation, and one clear
  next action form the shared state pattern.
- Background imports can be dismissed safely.
- Failures always explain what remained unchanged or preserved.
- Loading content uses stable placeholders when the surrounding layout is
  already known.

### Cooking

- Full Recipe remains a light checklist and overview.
- Focus Mode is deep basil with cream text; the step eyebrow, progress bar,
  and advance button are butter gold (advance label in fixed basil).
- One instruction owns the screen. Timers are large and stateful.
- No food photography or library controls appear in Focus Mode.

## Information architecture

### First run

- Launch directly into one dedicated, full-screen welcome surface on deep
  basil (always dark-appearance colors). Do not reveal or soften the library
  behind it, and do not require a passive feature tour.
- Use the same fried-egg mark as the installed app icon.
- Continue with Apple, Sign in with Google, and guest entry are the initial
  account choices. State the ten-recipe guest limit and that later sign-in
  preserves recipes.
- An empty Home or All Recipes view leads directly to adding the first
  recipe. Share Extension guidance stays contextual beside that action.

### Home

- Import Inbox entry with an attention count
- Watch saved recipes entry (basil block)
- Recipes saved this week
- Useful generated groups: ready in 30 minutes, favorites, and not cooked yet

### All Recipes

- Dense archive supporting hundreds of recipes
- Optional list and grid presentation
- Sort, filters, and removable active filters
- Search as a dedicated destination

### Watch

- Vertical, snap-aligned recipe cards
- Overview, Ingredients, and Method switch within a fixed-height card
- Only one source action is active at a time
- Stored imagery and the original source link are the required fallback when
  direct third-party playback is unavailable

## Accessibility and verification

- Test default, extra-large, and accessibility Dynamic Type sizes.
- Verify light and dark cooking surfaces with VoiceOver labels.
- Verify all controls at a minimum 44-point target.
- Verify small text at WCAG AA contrast or better; tomato fills always carry
  cream text, and butter fills always carry basil ink.
- Capture the primary atlas destinations at the project simulator size and
  compare hierarchy, spacing, state, and content.
