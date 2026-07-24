FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.8.22 /uv /uvx /bin/

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    UV_NO_DEV=1

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY . .
RUN uv sync --frozen --no-dev
RUN useradd --create-home --uid 10001 ladle \
    && chown -R ladle:ladle /app

USER ladle

EXPOSE 4111

CMD ["/app/.venv/bin/uvicorn", "ladle.api.app:app", "--host", "0.0.0.0", "--port", "4111"]
