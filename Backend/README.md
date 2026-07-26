# Ladle Backend

The Ladle backend is a Python 3.12 FastAPI application with Celery workers.
It is developed and locked with [uv](https://docs.astral.sh/uv/).

## Local toolchain

```bash
uv sync --all-groups
uv run pytest -q
uv run ruff format --check .
uv run ruff check .
uv run mypy ladle
```

Copy `.env.example` to an ignored `.env` for local development. Replace the
development-only signing and encryption placeholders before setting
`LADLE_ENVIRONMENT=production`. Local Compose uses deterministic fake
providers. Live workers require the configured extraction provider credential;
Supadata and SoScripted are optional URL-transcript fallbacks.

See [`docs/integration-reference.md`](docs/integration-reference.md) for the
repository/runtime path map, complete API reference and examples, provider
fallback behavior, iOS connection setup, and PostgreSQL data dictionary.

## Local stack

```bash
docker compose up -d --build
curl --fail http://127.0.0.1:4112/health/live
curl --fail http://127.0.0.1:4112/health/ready
```

Readiness checks PostgreSQL, Redis, and the private object-storage bucket.
Prometheus-format bounded-label counters are available at `/metrics`. Run
`scripts/check_secrets.sh` before publishing a deployment artifact.

Apple sign-in remains disabled until `LADLE_APPLE_ENABLED=true` and the team
ID, key ID, private key, and bundle ID are supplied. Provider credentials and
optional browser cookies belong only on the worker, never in the repository or
iOS application.
