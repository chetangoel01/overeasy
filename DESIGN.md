# Ladle Design System

Status: approved implementation source of truth

## Scene

A home cook saves and sorts recipes one-handed on the couch, then reads Ladle
from a bright kitchen counter with wet or floury hands. Browsing is warm and
compact. Cooking is high contrast, calm, and legible at a glance.

## Design principles

- Native iOS behavior comes first. Use SwiftUI navigation, sheets, menus,
  alerts, controls, safe areas, and SF Symbols.
- Food photography is the most saturated visual element.
- Color communicates action or state, never decoration alone.
- Browsing surfaces are light. Focus cooking uses smoky plum to create a clear
  task boundary.
- Dynamic Type, VoiceOver, Reduce Motion, and 44-point targets are preserved
  even when a mockup uses smaller presentation-scale measurements.
- Long content scrolls. Primary actions stay reachable without covering
  ingredients, steps, or form fields.

## Color

| Role | Value | Use |
| --- | --- | --- |
| Smoky plum | `#493943` | Selected controls and Focus Mode background |
| Paper | `#FAF6EF` | Primary reading surface |
| Oat | `#F1ECE3` | Secondary surfaces and fields |
| Ink | `#30272D` | Primary text and controls |
| Dusty brick | `#AD503D` | Primary actions and errors |
| Soft celery | `#BEC9AE` | Success and progress |
| Muted ube | `#DDD5DF` | Inactive controls and quiet grouping |
| Muted ink | `#72676D` | Secondary text on paper or oat |

Brick is deliberately darker than the exploration artifact so small text and
button labels meet contrast requirements. Use paper text on brick and plum.
Use ink text on celery and ube.

## Typography

- SF Rounded carries screen titles, recipe names, and short section headings.
- SF Pro carries body copy, controls, ingredients, metadata, and cooking
  instructions.
- Long cooking instructions prioritize distance legibility over personality.
- Hierarchy comes from size and weight, not tracked uppercase labels.
- Body copy uses semantic Dynamic Type styles with scaled custom sizes where
  the approved hierarchy requires them.

## Shape and spacing

- Circular icon controls are at least 44 points.
- Primary controls and fields use 14 to 16-point continuous corners.
- Prominent images and grouped surfaces use 18 to 22-point continuous corners.
- Sheets use the native presentation shape and drag indicator.
- Use 8, 12, 16, 24, and 32-point spacing roles, with varied rhythm between
  compact controls, sections, and cooking content.
- Prefer dividers and open lists to wrapping every section in a card.

## Components

### Buttons

- Primary: brick fill, paper label, full width when it advances the task.
- Secondary: oat fill, ink label.
- Quiet: text-only for cancellation or optional paths.
- Destructive actions use the system destructive role.
- Press feedback lasts 150 to 200 milliseconds and respects Reduce Motion.

### Navigation

- Home and All Recipes share a native segmented control.
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
- Focus Mode uses plum with paper text and celery progress.
- One instruction owns the screen. Timers are large and stateful.
- No food photography or library controls appear in Focus Mode.

## Information architecture

### First run

- Launch directly into one dedicated, full-screen welcome surface on paper.
  Do not reveal or soften the library behind it, and do not require a passive
  feature tour.
- Use the same fried-egg mark as the installed app icon; do not invent a
  secondary onboarding logo.
- Continue with Apple, Sign in with Google, and guest entry are the initial
  account choices. State the ten-recipe guest limit and that later sign-in
  preserves recipes.
- An empty Home or All Recipes view leads directly to adding the first recipe.
  Share Extension guidance stays contextual beside that action.

### Home

- Import Inbox entry with an attention count
- Watch saved recipes entry
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
- Verify small text at WCAG AA contrast or better.
- Capture the primary atlas destinations at the project simulator size and
  compare hierarchy, spacing, state, and content rather than HTML pixel values.
