# Chaos Readiness Regression and the k6 Start Race

## Purpose

The weekly `load-and-chaos` job in `.github/workflows/backend-ci.yml` has been
red since the 2026-08-31 scheduled run: its chaos step waited the full 120 s
for `http://127.0.0.1:42112/health/ready` and never saw a 200, after passing
on 2026-08-24. PR #53 recorded the commit bracket and stopped there. This
finds the commit, fixes it, guards it, and closes the separate race in the
same job's k6 step.

## What was wrong

Every runtime container of the chaos stack died at startup, before the API
existed:

```
pydantic_core._pydantic_core.ValidationError: 1 validation error for Settings
  Value error, worker timing must satisfy heartbeat*2 < claim lease, longest
  provider timeout < soft task limit < hard task limit < broker visibility <
  stale-job timeout < recipe reservation, and hard task limit < provider
  budget reservation
```

`deploy/chaos/docker-compose.chaos.yml` shrinks the worker timings so a broker
outage resolves inside the drill: every provider timeout at 10 s under a 12 s
soft task limit. `90414ed` (`feat: calculate recipe nutrition from USDA data`,
2026-08-24, on `codex/extraction-accuracy`, merged into `main` by `9141edb`)
added `usda_timeout_seconds` to `Settings.validate_worker_timing`'s longest
provider timeout with a default of 15 s and no pin in the overlay. 15 is not
below 12, so `Settings()` raised in `ladle.api.app`, `ladle.worker.app` and
beat alike, and `migrate` and `minio-init` — which build no timing — kept
exiting 0.

Nothing in CI said so. From `7ce3cc9` (2026-08-26) `api`, `worker` and `beat`
carry `restart: unless-stopped`, so `docker compose up -d` reported the three
crash-looping containers as `Started`, and the test's timeout was the only
line in the log. PR #53's candidate list only held commits on `main`'s
first-parent line that touch stack files; the culprit is one of 194 commits in
the bracket and sits on the merged feature branch.

## Bisect

Predicate: build the environment the chaos stack hands the `api` container
(`docker compose -f docker-compose.yml -f deploy/chaos/docker-compose.chaos.yml
-p ladle-chaos-recovery config`, with the two variables the test exports) and
construct `Settings()` under it. `git bisect run` over `ec5b97a..93e8236`:

| Commit | Result |
| --- | --- |
| `a89705f` fix: clarify health and media failures | bad |
| `7c558ff` Require clarification for fuzzy product intent | bad |
| `b1f9a4b` docs: plan Gemini 3.7 live imports | bad |
| `6ba6cfa` docs: record text-only pipeline verification | bad |
| `a4d66b8` feat: find creator recipes from sparse shares | good |
| `34cab87` feat: verify disputed recipe fields | bad |
| `90414ed` feat: calculate recipe nutrition from USDA data | **first bad** |
| `4789012` fix: ground extracted nutrition in source text | good |

`git log -S usda_timeout_seconds -- Backend/ladle/config.py` names the same
commit and no other.

Both ends were then run as the real stack — the chaos test's own Compose
files, project name and environment, with `LADLE_INSTALL_MEDIA_TOOLS=false`
to skip the ffmpeg apt layer that fake-mode readiness never touches — on
Docker Desktop 29.6.2 with Compose v5.3.1, polling `/health/ready` for 150 s:

| Commit | `/health/ready` | Containers |
| --- | --- | --- |
| `4789012` | 200 after 11 s, every check `ready` | all up |
| `90414ed` | never answered (connection refused for 152 s) | `api` Exited (1), `worker` Exited (2), `beat` Exited (2) on the `ValidationError` above; `migrate` and `minio-init` Exited (0) |
| `origin/main` (`be2f99b`) | never answered (connection refused for 180 s) | `api`, `worker`, `beat` `Restarting` on the same error |

## Decisions

- **Pin `LADLE_USDA_TIMEOUT_SECONDS: "10"` in the overlay**, next to the other
  provider timeouts. The overlay is the one place that decides the drill's
  timings, so it is where the missing value belongs; the default is right for
  production and was not touched.
- **Guard the overlay in `tests/unit/deploy/test_local_stack_policy.py`.**
  The new test builds `Settings` from the overlay's pins alone (the base
  Compose environment sets no timing variable, and the suite's autouse fixture
  clears `LADLE_*`), so a provider timeout that joins the validator without a
  pin fails the unit suite on the pull request instead of the next Monday's
  scheduled run. It was red on `origin/main` before the pin and green after.
- **Make the chaos test say what happened.** On a readiness timeout it now
  prints the last answer it got from `/health/ready`, `docker compose ps -a`
  and the tail of the `api`, `worker` and `beat` logs, best effort, before
  raising. The 2026-08-31 log would have shown the traceback.
- **Poll `/health/ready` before k6.** `up -d` returns when the containers
  exist; k6's `setup()` then reached a cold API and died on a null body
  (2026-08-17 and 2026-08-24). The first cut was `docker compose up --build
  --wait --wait-timeout 300`, which passed locally on Compose v5.3.1 and
  failed on the first dispatch of the branch
  ([33595966182](https://github.com/chetangoel01/recipe-app/actions/runs/33595966182))
  with `container backend-beat-1 has no healthcheck configured`, 20 s after
  `api` and `worker` were healthy: `beat` carries `healthcheck: disable: true`
  on purpose, Docker stores that as a `NONE` test, and the runner's Compose
  2.38.2 only falls back to "running" for a container with no healthcheck
  config at all (`isServiceHealthy` in `pkg/compose/convergence.go`). The step
  now starts the stack with `up -d --build` and polls
  `http://127.0.0.1:4112/health/ready` for up to 300 s, the way the chaos test
  and the `api` container's own healthcheck do; a 200 there means the
  migrations, the broker, the worker's ping and object storage all answer,
  which is everything `setup()` needs, on any Compose. The `EXIT` trap prints
  `ps -a` and the `api`/`worker` logs on a non-zero exit before tearing the
  stack down, and `test_ci_policy` asserts the poll sits between `up` and k6.
- Not changed: `restart: unless-stopped` on the local stack (it is what a
  developer wants), the k6 thresholds, and the `secrets` job, whose full-history
  gitleaks scan is red on every scheduled and dispatched run for the reasons
  PR #53 recorded.

## Verification

Apple Silicon Mac, Docker Desktop 29.6.2, Compose v5.3.1, on
`fix/chaos-readiness` over `dff9680`–`edcdc15`.

| Check | Result |
| --- | --- |
| `uv run ruff format --check .`, `uv run ruff check .`, `uv run mypy --strict ladle` | clean |
| `uv run pytest tests/unit/deploy -n0` before the pin | `test_chaos_overlay_pins_keep_the_worker_timing_valid` fails on the `ValidationError` |
| `uv run pytest tests/unit/deploy -n0` after the pin | 43 passed |
| `uv run pytest -q` (the CI selection) | 828 passed in 22 s |
| `LADLE_RUN_CHAOS=1 uv run pytest -q -m chaos -n0` | 2 passed in 174 s; the first run of either scenario against the Compose file with `restart: unless-stopped` and `--concurrency=1` |
| The k6 step's exact script, redirected by `COMPOSE_PROJECT_NAME`/`COMPOSE_FILE` onto a port-isolated copy of the stack | stack up, poll returned, k6 ran warm: `load user created` 100%, checks 100%, `http_req_failed` 0% over 1478 requests; the latency thresholds failed (p95 20.6 s) with the Mac's 1-minute load average at 436 at the time, against p95 390 ms for the same profile on the same stack at 01:44 on an idle machine |
| `git diff --check` | clean |

The local k6 numbers only show that `setup()` gets its tokens once the poll
returns; the runner's capacity is a different machine.

## CI

Two dispatches of this branch with
`gh workflow run backend-ci.yml --ref fix/chaos-readiness`:

| Run | Commit | `load-and-chaos` | Chaos drill | k6 step | `quality` | `image` | `secrets` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [33595966182](https://github.com/chetangoel01/recipe-app/actions/runs/33595966182) | `b894ff2` | failure | success, the first since 2026-08-24 | failure: Compose 2.38.2 rejected `--wait` on `beat`'s disabled healthcheck | success | success | failure, pre-existing |
| [33642049418](https://github.com/chetangoel01/recipe-app/actions/runs/33642049418) | `edcdc15` | **success** | success, 2 passed in 216 s | success: 2584 requests, checks 100%, `http_req_failed` 0%, p(95) 718 ms, p(99) 886 ms, 63 s from `up` to `down` | success | success | failure, pre-existing |

Both runs' overall conclusion is `failure` because of `secrets` alone: its
full-history gitleaks scan is red on every scheduled and dispatched run for
the false-positive reasons PR #53 recorded, and it is untouched here. The
pull-request run at `edcdc15`
([33642055892](https://github.com/chetangoel01/recipe-app/actions/runs/33642055892))
is green on `quality`, `image` and `secrets`; `load-and-chaos` only runs on
`schedule` and `workflow_dispatch`.
