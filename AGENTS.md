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

## Required Claude Fable consultation

Consult Claude Fable twice for every coherent tracked-file change-set:

1. Before editing, ask Fable to review the intended change, affected files, product constraints, and proposed verification.
2. After implementation and verification, ask Fable to review the actual diff before committing.

Use Claude in read-only mode. A suitable invocation is:

```bash
claude -p \
  --model fable \
  --permission-mode plan \
  --allowedTools "Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*)" \
  "<review prompt>"
```

Fable must never edit repository files. Address feedback concerning correctness, safety, data integrity, concurrency, API contracts, or approved product behavior before committing. If feedback is intentionally not adopted, record the reason in the task notes or commit context.

A coherent change-set may contain multiple mechanical edits that implement one already-reviewed behavior. A new behavior, materially revised approach, or unrelated fix requires a new pre-change consultation.

## Verification before commits

- Add a failing test before production behavior, then verify red-green-refactor.
- Run the narrow tests for the changed behavior.
- Run `swift test --package-path Packages/LadleCore` for shared domain changes.
- Run the relevant `xcodebuild test` target for app or UI behavior.
- Run a full Ladle app and Share Extension build at milestone checkpoints.
- Run `git diff --check` before every commit. This checks whitespace errors and conflict markers; it does not replace tests, compilation, or Fable review.
- Commit only after the relevant tests pass and the post-change Fable review has been resolved.
