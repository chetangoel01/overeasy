# Import Inbox Review Navigation Design

## Problem

Completing a recipe review does not produce a clean inbox transition. A
reviewed item can remain visible, and returning to Home can leave the Import
Inbox entry point unable to open its destination again.

The current Library navigation stores workspace and recipe destinations in
separate optional values. Review completion updates the recipe and import job
while the Import Inbox and Recipe Detail destinations are both active. The
underlying inbox can also dismiss itself when its actionable count becomes
zero. Those independent mutations can leave route state stale even when the
stored recipe and job were updated successfully.

## Approved Behavior

- Tapping **Mark reviewed** persists the reviewed recipe and resolves its
  normal import job atomically.
- If other actionable imports remain, Recipe Detail closes and Import Inbox
  remains visible without the reviewed row.
- If no actionable imports remain, navigation resets to Library Home.
- The Import Inbox card can be opened again after leaving the inbox.
- A persistence failure leaves Recipe Detail visible and presents the existing
  library error instead of navigating away.
- Re-import candidates continue to use their existing accept-or-keep recovery
  flow and are not silently completed by **Mark reviewed**.

## Approach

Use one Library navigation path whose route enum represents workspace and
recipe-detail destinations. Home pushes Import Inbox, Import Inbox pushes the
recipe review, and successful review completion rewrites the path according to
the remaining actionable job count.

This replaces competing optional destination bindings and removes the
Import Inbox view's implicit self-dismissal. Navigation becomes an explicit
result of the successful domain mutation:

1. Complete the recipe and related normal import jobs.
2. Recompute actionable imports from the updated view model.
3. Keep only the Import Inbox route when items remain.
4. Clear the path and select Library Home when the inbox becomes empty.

## Rejected Alternatives

### Clear the existing optional bindings manually

This is a smaller diff, but it preserves two independent sources of navigation
truth. Ordering between SwiftUI binding updates and the inbox's automatic
dismissal would remain fragile.

### Present recipe review as a sheet

A sheet makes dismissal simple but breaks the app's native drill-in navigation
and left-edge back behavior. It also creates a one-off presentation model for
recipes opened from the inbox.

## Testing

- Add view-model coverage proving review completion removes only the matching
  normal review job and reports failure without mutating navigation inputs.
- Add Library navigation coverage for the two approved outcomes:
  remaining items return to Import Inbox; the last item returns to Home.
- Add a UI regression that opens Import Inbox, reviews a recipe, confirms the
  row disappears, returns to Home when appropriate, and verifies the inbox
  entry point can be opened again when actionable items remain.
- Run focused tests first, then the complete app unit target and a simulator
  build.
- Validate the real interaction on **Overeasy - iPhone 16 Pro**.

