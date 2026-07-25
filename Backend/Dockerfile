FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.8.22 /uv /uvx /bin/

# yt-dlp reads public metadata and captions; ffmpeg downsamples audio before
# it is sent for transcription, which is most of what keeps that call cheap.
RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*

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
