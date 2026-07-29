# Asset catalog scale slots

## Purpose

Keep the bundled Overeasy mark and sample recipe photography in the standard
universal image-set shape expected by Xcode.

## User-visible behavior

The existing 1× PNG remains the source image for each asset. Empty 2× and 3×
slots are declared explicitly; no image content, names, or runtime lookup
behavior changes.

## Important decisions

- Preserve the existing PNG files without resampling or generating variants.
- Keep the metadata change separate from Library interaction work.
- Apply the same universal scale structure to all seven affected image sets.

## Affected components

- `OvereasyMark.imageset`
- `RecipeBurger.imageset`
- `RecipeChicken.imageset`
- `RecipeCookies.imageset`
- `RecipeOrzo.imageset`
- `RecipeToast.imageset`
- `RecipeUdon.imageset`

## Verification

- Validate each `Contents.json` file with `jq`.
- Build the Ladle app and embedded Share Extension.
- Run `git diff --check` before committing.
