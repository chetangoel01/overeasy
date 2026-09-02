# Ladle

register: product

## Product Purpose

Native iPhone recipe workspace. Turns scattered social-video links (TikTok,
Instagram, YouTube) into structured recipes that are easy to save, review, and
cook from at the counter. The core loop: share a link, get a clean recipe,
cook it hands-messy with big type and per-step focus.

## Users

Home cooks who save recipe videos and never find them again. They use the app
in two modes: browsing/triage (couch, one thumb) and cooking (phone propped on
the kitchen counter, bright light, wet or floury hands, glancing from a
distance). The cooking mode drives the design: high contrast,
oversized type, 44pt-plus hit targets.

## Brand and tone

Practical, direct, unfussy. The voice is a competent friend, not a magazine.
Copy is short, concrete, and never exclamatory. One signature metaphor
("rescued from the scroll") is reserved for the welcome screen only.

## Visual direction

Native-first SwiftUI using the approved Porcelain & Graphite system. Cool
neutral surfaces keep the library quiet enough for food photography to lead;
graphite creates a high-contrast cooking ground; signal red is reserved for
actions and attention. SF Pro uses familiar iOS weights and widths. Hierarchy
comes from content, size, spacing, and native navigation rather than branded
chrome or explanatory cards.

## Anti-references

- The "AI recipe app" default: cream background + terracotta accents + system
  serif (New York) headlines + tracked uppercase eyebrows. This app had that
  look and is deliberately moving off it.
- Cozy pantry, deli-counter, kraft-paper, or illustrated food metaphors —
  with one deliberate exception. Each row of the recipe detail's ingredient
  list leads with a watercolour of that ingredient. It is identification, not
  atmosphere: at the counter it says what to reach for before the words are
  read. It appears nowhere else, it is never decoration around type, and an
  ingredient the set cannot name honestly gets a neutral badge rather than
  the nearest picture.
- Editorial food-magazine styling (Fraunces/Playfair serifs, italic accents).
- Shouty coaching copy ("DO THIS NOW", exclamation marks).

## Strategic principles

- The tool disappears into the task: standard iOS affordances, no invented
  controls.
- First-run identity is explicit and inclusive: a dedicated welcome screen
  offers Apple, Google, and a clearly limited guest path before entering the
  library.
- Honesty in data: conservative amounts may be inferred when the dish and
  standard technique support them, but every estimate is labeled inline.
  Blocking review is reserved for recipes that remain mostly unmeasured.
- Discovery uses aggregate saves of public recipe-video sources. It never
  exposes the identity of the cook who saved a recipe or their private edits.
- Demo/fixture content must be indistinguishable from real recipes; a
  placeholder ingredient is a bug.
