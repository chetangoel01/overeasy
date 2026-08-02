# Agent design skills handoff

## Purpose

Make the shared design and motion guidance installed for backend-scoped coding
agents reproducible and available to both Codex-compatible and Claude-compatible
agent discovery.

## Resulting behavior

- Eight skills from `emilkowalski/skills` are installed under
  `Backend/.agents/skills`:
  `animation-vocabulary`, `apple-design`, `emil-design-eng`,
  `find-animation-opportunities`, `improve-animations`, `pick-ui-library`,
  `prototype`, and `review-animations`.
- `Backend/.claude/skills` exposes the same skill directories through relative
  symlinks. The files under `Backend/.agents/skills` remain the canonical local
  copies, so the two agent integrations cannot drift independently.
- `Backend/skills-lock.json` records the upstream repository, source path, and
  computed hash for every installed skill.
- No Ladle application, backend runtime, build, or deployment behavior changed.

## Important decisions and affected components

- The installation is scoped to `Backend`, matching the location selected when
  the skills were installed. Agents operating elsewhere in the repository may
  not discover these project-local skills automatically.
- The Claude entries are symlinks rather than duplicated content. Preserve
  their relative targets if the repository is moved or cloned.
- Future upgrades should use the same skill installer so the canonical copies,
  compatibility symlinks, and lockfile hashes are updated together.
- A future contributor should review upstream skill changes before accepting a
  lockfile refresh because these files are executable agent instructions.

## Verification

- Confirmed all eight lockfile entries have a corresponding canonical
  `SKILL.md`.
- Confirmed all eight Claude compatibility symlinks resolve to their matching
  canonical skill directories.
- Ran `git diff --check` before commit.
- Application tests and builds were not run because this change contains only
  agent instruction files, symlinks, the generated lockfile, and this handoff.

## Resume point

The installation is complete; there is no unfinished application work in this
change. If these skills were intended to apply repository-wide instead of only
inside `Backend`, reinstall or deliberately relocate them at the repository
root and update this document in the same change. Do not keep two independent
copies.
