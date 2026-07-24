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
