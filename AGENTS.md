# Ladle Development Workflow

## Preserve known-good versions

- Work on a `codex/` feature branch; keep `main` as the stable integration branch.
- Make task-sized commits after a coherent change-set is verified.
- Do not combine unrelated changes in one commit.
- Do not rewrite or discard known-good history unless the user explicitly requests it.
- Leave the branch clean at checkpoints so any good version can be recovered by commit.

## Image sourcing preference

- Search online first when the product needs ordinary photographic or illustrative imagery.
- Use a suitable source with clear licensing and retain source attribution details when required.
- Do not generate replacement imagery unless the user explicitly requests image generation.

## Clarify fuzzy product intent before implementation

- Before changing product behavior or design, identify any detail that has more than one materially different interpretation.
- When the request uses open-ended language such as "explore," "maybe," "fix," or "alternate view," ask focused clarifying questions and wait for the answers before editing code.
- Do not treat permission to explore as permission to select and implement a product direction on the user's behalf.
- Briefly restate the resolved direction before implementation so the user can correct it.
- Make independent assumptions only for low-impact implementation details that do not change the user-visible concept or interaction.

## Keep implementations concise

- Prefer the fewest lines that preserve clarity, correctness, and maintainability.
- Remove duplication, unnecessary abstraction, boilerplate, and dead code.
- Keep control flow direct and responsibilities easy to follow.
- Do not reduce line count at the expense of readability, safety, accessibility, tests, or required behavior.

## Document every coherent change

- Add or update a concise human-readable companion document for every screen, feature, or coherent behavior change.
- Record its purpose, user-visible behavior, important decisions, affected components, and verification.
- Write enough for a human or replacement agent to resume the work without reconstructing intent from code.
- Keep the document near related plans or verification records and update an existing relevant document instead of creating duplicates.

## Verification before commits

- Add a failing test before production behavior, then verify red-green-refactor.
- Run the narrow tests for the changed behavior.
- Run `swift test --package-path Packages/LadleCore` for shared domain changes.
- Run the relevant `xcodebuild test` target for app or UI behavior, using the
  `LadleAllTests` scheme (tests are disabled on the default `Ladle` scheme).
- Run a full Ladle app and Share Extension build at milestone checkpoints.
- Run `git diff --check` before every commit. This checks whitespace errors and conflict markers; it does not replace tests or compilation.
- Commit only after the relevant tests pass.
