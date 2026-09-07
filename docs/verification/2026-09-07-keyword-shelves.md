# Shelves the corpus decides

Date: September 7, 2026
Issue: [#101](https://github.com/chetangoel01/recipe-app/issues/101), split
out of [#87](https://github.com/chetangoel01/recipe-app/issues/87)
Status: **built and verified on the review simulator.**

Stacked on the iOS filter ([#120](docs/verification/2026-09-07-filter-model.md),
`feat/filter-model`), which is stacked on the backend tags
([#105](2026-09-07-recipe-tags.md), `feat/recipe-tags`), which is stacked on
the nutrition skips (#104). #105 gave a recipe its keywords and said what
they were for; this is what spends them.

## Purpose

Discover's two shelves ([#29](2026-09-02-discover-long-press-test.md)) are
the ranked feed under another order: "New to Overeasy" is `sort=newest` and
"Quick dinners" is `max_total_minutes=30`. Neither says anything about what
the recipes *are*, because until #105 nothing stored did.

Now every recipe carries keywords from a curated list of twenty-five, and a
keyword with enough behind it is a shelf a cook understands: **One pot**,
**Weeknight**, **High protein**. The list of shelves is not a list anybody
maintains — it is a query, so it follows the corpus.

## What the cook sees

- **The two rails first, then the keyword shelves.** The rails are this
  app's own promises about the feed and stay where a returning cook left
  them. How many shelves follow depends on what the corpus holds that week.
- **A shelf is titled in words**, never in a raw keyword: "One pot", not
  `onePot`. Same spelling as the filter menu's row for the same keyword,
  because tapping "See all" turns the one into the other.
- **No caption on a keyword shelf.** A rail's title is a promise about an
  ordering and needs a line explaining it ("Thirty minutes or less, start to
  finish"). "Soup" explains itself, and a sentence under it would be filler.
- **"See all" is new, and only on a keyword shelf.** A keyword is a filter,
  so the row has somewhere to go: the ranked list below becomes the rest of
  the shelf. "New to Overeasy" is an ordering nothing in the app can ask for
  a second time, so it keeps having no destination —
  [DESIGN.md](../../DESIGN.md) is updated to say so.
- **A vegetarian is offered vegetarian shelves.** Not vegetarian cards under
  a title chosen for somebody else: the diet decides *which* keywords have
  enough behind them as well as what is on each one. In the demo library
  that is visible — three of the six dishes are weeknight dinners, only two
  of those are vegetarian, and choosing Vegetarian takes the shelf away
  rather than leaving a row of two.

## The shape of it

**Server composes, client renders.** Which keywords are worth a shelf is a
fact about the whole corpus, and a page of thirty rows cannot answer it. The
client asks once and draws what it is handed.

- **`GET /v1/recipes/discover/shelves`** → `DiscoverShelvesDTO`, a list of
  `{keyword, title, items}`. Declared *before* `/discover/{source_video_id}`
  in `routes/recipes.py`: FastAPI matches in declaration order, and the other
  way round "shelves" is parsed as a source ID and a path that exists answers
  422. It takes the same `diet`, `cuisine`, `keyword` and `ingredient`
  parameters as the feed — spelled once now, as `DietQuery` and friends, and
  shared by both routes — plus `limit`, the size of one shelf.
- **`RecipeRepository.discover_shelves`** is two steps. First, count the
  distinct *sources* behind every curated keyword, over exactly the rows the
  ranked list would serve this cook and under exactly the filter they are
  browsing with, keeping the keywords that clear the floor. Then ask
  `discover` for each survivor's own first page, so a shelf is ranked,
  grouped by source and resolved through the extraction cache by the same
  code as the list beneath it.
- **The eligibility conditions are now one function**, `_discover_conditions`,
  shared by the page and the count. They have to agree: a keyword counted
  over rows the feed would not serve — a source this cook already saved, an
  extraction that never became ready — makes a shelf that arrives a card
  short of the floor it was supposed to clear.
- **`DiscoverFilter.required_keyword`** is how a shelf's own keyword is added
  to the cook's filter. It could not go in `keywords`: those combine with
  *or*, so folding it in would widen the feed at the moment it is meant to
  narrow. A cook browsing "One pot" who is offered a "Budget" shelf gets the
  dishes that are both.
- **`KEYWORD_TITLES` lives in `contracts/tags.py`**, beside the vocabulary it
  names, and `RecipeKeyword.shelf_title` reads it. Not `.title`: `StrEnum` is
  a `str`, and a property by that name would quietly shadow `str.title()` for
  every tag in the codebase.

## Decisions

- **The floor and the cap are settings, not constants.**
  `LADLE_DISCOVER_SHELF_MINIMUM_RECIPES` (3) and
  `LADLE_DISCOVER_SHELF_MAXIMUM_COUNT` (6). Both are judgements about the
  size of a corpus of about eighty sources that is still growing, and both
  will want moving before the shelves read well. A shelf of one recipe reads
  as a mistake; a screen of shelves is a filing cabinet rather than something
  to browse.
- **Ordered by count, ties broken by the vocabulary.** Counting first is what
  makes the shelves follow the corpus. The tiebreak is the vocabulary because
  every other list of tags in this codebase is in vocabulary order, and
  because *some* total order is needed or the shelves would shuffle between
  requests. The sort is done in Python over at most twenty-five rows: a SQL
  `CASE` spelling out the order would be a second copy of the enum.
- **Proposals cannot appear, and nothing had to be written to keep them
  out.** An unreviewed keyword lives in `recipe_keyword_proposals`, which
  this query does not touch. That is what the separate table buys — the rule
  is a fact about the schema rather than a line in the query that could be
  deleted. The test seeds three recipes with a proposal and drops the floor
  to one, which would clear it three times over.
- **The title travels on the wire.** The client already has words for a
  keyword — the filter menu needs them offline, and the Recipes tab filters
  locally — but a shelf is drawn from the DTO's title, so a keyword promoted
  after a build shipped still draws a shelf. That build simply cannot offer
  to filter by it, which is what `RemoteDiscoverShelfDTO.recipeKeyword`
  returning nil means, and what hides "See all".
- **"See all" replaces the keywords and keeps everything else.** The shelf
  was composed under the diet, the cuisines and the ingredient terms that
  were already on, so leaving those alone is what makes the list agree with
  the row that was tapped. The keywords are replaced, not added to, for the
  same *or* reason as above.
- **A shelf for a keyword the cook is filtering on hides itself.** This is a
  display rule on the client (`DiscoverViewModel.visibleShelves`), beside the
  two that were already there — hidden under a search, dropped under three
  cards. The server still composes it, and deliberately: which keywords make
  shelves is a fact about the corpus, and teaching the query about what is
  redundant on one screen would put a layout decision in SQL.
- **A shelf can still come back short, and that is the client's problem.**
  The count is over ranked rows; a source whose extraction cache went stale
  is ranked and then dropped. The server only refuses to send an empty shelf.
  Below three cards the client hides it, which is the rule the rails have had
  since #29.
- **The demo service composes shelves itself.** In a UI run `DemoDiscoverService`
  *is* the server, so it applies the same floor, the same order and the
  cook's filter first. Without that a UI run would show two rails and no
  shelves, which is not the screen.
- **A shelf costs one query per shelf.** Six shelves is a count query plus
  six `discover` calls, each of which resolves its own cache rows. That is
  the same shape as a page of thirty and is fine at this size; batching the
  cache lookups is the obvious first move if it stops being fine.

## Verification

Docker was up, so the backend suite is real.

`uv run pytest` from `Backend/`:

```
984 passed, 10 warnings in 27.29s
```

`ruff format --check .` → `353 files already formatted`. `ruff check .` →
`All checks passed!`. `mypy --strict ladle` → `Success: no issues found in
129 source files`.

New there: `tests/api/test_discover_shelves.py` (11 cases over eight seeded
dishes — the ordering and its tiebreak, the floor and the cap moved through
`Settings`, the diet applied to which shelves exist and to what is on one,
the conjunction with a browsing keyword, an unreviewed proposal that cannot
appear, a bounded page, a source the cook already saved failing to hold a
shelf up, and the route not being read as a source ID), two title cases in
`tests/contracts/test_tags.py`, and `discover-shelves.json` in the golden
round-trip.

`swift test --package-path Packages/LadleCore`:

```
Test run with 72 tests in 11 suites passed after 0.020 seconds.
```

New there: `shelvesFixtureCarriesAKeywordAndTheWordsToHeadItWith`,
`aShelfForAPromotedKeywordStillDrawsWithoutItsFilter` and
`showingOneShelfReplacesTheKeywordsAndKeepsEverythingElse`.

`xcodebuild test` on `LadleAllTests`, on a simulator created for the run
(iPhone 17 Pro, iOS 26.5). Unit bundle:

```
Executed 479 tests, with 1 test skipped and 0 failures (0 unexpected)
```

New there: five cases in `DiscoverViewModelTests` (the shelves arrive named
and sit after the rails, the filter rides on them, a shelf for a filtered
keyword hides, a failed shelves request costs neither the rails nor the feed,
and the demo composes them the way the server would) and
`testSeeAllOnAShelfPutsItsKeywordInTheSharedFilter` in
`RecipeFilterStoreTests`.

`LadleUITests` in slices, because a long run on this shared machine keeps
being killed part-way:

```
DiscoverInteractionUITests                 7 passed (123.711s)
testSeeAllOnAKeywordShelfNarrowsTheList... 1 passed (11.613s)
RecipesFilterMenuUITests + ProfileSheet…   see below
```

The new UI case is the one path no unit test reaches: the button in a
shelf's header. It scrolls the Weeknight shelf onto the screen, taps "See
all", and finds the "Weeknight" pill under Discover's header, the shelf gone
and the meat dish out of the list.

The whitespace check is clean on every commit.

## Known gaps

- **A keyword shelf carries no artwork of its own** — it is the same card as
  every other shelf. That is deliberate for now; a shelf with a colour or an
  icon per keyword would be twenty-five more decisions.
- **Nothing shows a recipe its own keywords.** #120 left this open and it is
  still open: the tags decode, travel through an edit and now compose
  shelves, but no screen lists them on a recipe.
- **The shelves are not part of a deep link.** "See all" sets the filter in
  the running app; nothing outside it can open Discover on a shelf.
- **Six shelves is six ranked queries.** See the cost note above.
