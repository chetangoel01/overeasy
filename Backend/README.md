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
`LADLE_ENVIRONMENT=production`. External provider credentials are optional;
unconfigured providers are skipped by the acquisition chain.

## Local stack

```bash
docker compose up -d --build
curl --fail http://127.0.0.1:4111/health/live
curl --fail http://127.0.0.1:4111/health/ready
```

Readiness checks PostgreSQL, Redis, and the private object-storage bucket.
Prometheus-format bounded-label counters are available at `/metrics`. Run
`scripts/check_secrets.sh` before publishing a deployment artifact.

Apple sign-in remains disabled until `LADLE_APPLE_ENABLED=true` and the team
ID, key ID, private key, and bundle ID are supplied. Live extraction workers
likewise require Supadata, SoScripted, and Anthropic credentials; none belong
in the repository or iOS application.
