FROM python:3.12.13-slim-bookworm@sha256:d50fb7611f86d04a3b0471b46d7557818d88983fc3136726336b2a4c657aa30b

COPY --from=ghcr.io/astral-sh/uv:0.8.22@sha256:9874eb7afe5ca16c363fe80b294fe700e460df29a55532bbfea234a0f12eddb1 /uv /uvx /bin/

# yt-dlp reads public metadata and captions; ffmpeg downsamples audio before
# it is sent for transcription, which is most of what keeps that call cheap.
ARG DEBIAN_SNAPSHOT=20260713T000000Z
ARG CA_CERTIFICATES_VERSION=20230311+deb12u1
ARG FFMPEG_VERSION=7:5.1.9-0+deb12u1
RUN sed -i \
        -e "s|http://deb.debian.org/debian$|https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|" \
        -e "s|http://deb.debian.org/debian-security$|https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|" \
        -e "/^Components: main$/a Check-Valid-Until: no" \
        /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        ca-certificates=${CA_CERTIFICATES_VERSION} \
        ffmpeg=${FFMPEG_VERSION} \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    UV_NO_DEV=1 \
    HOME=/tmp/ladle \
    XDG_CACHE_HOME=/tmp/ladle/cache

COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/tmp/ladle/cache/uv \
    uv sync --frozen --no-dev --no-install-project

COPY . .
RUN --mount=type=cache,target=/tmp/ladle/cache/uv \
    uv sync --frozen --no-dev
RUN useradd --create-home --uid 10001 ladle \
    && chown -R ladle:ladle /app

USER ladle

EXPOSE 4111

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/app/.venv/bin/python", "-c", "import os, urllib.request; urllib.request.urlopen(f\"http://127.0.0.1:{os.environ.get('PORT', '4111')}/health/ready\", timeout=3)"]

CMD ["/app/.venv/bin/python", "-m", "ladle.api"]
