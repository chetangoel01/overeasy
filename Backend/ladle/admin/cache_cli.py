import argparse
from collections.abc import Sequence
from typing import Any, cast

import httpx
from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from ladle.clock import Clock, SystemClock
from ladle.config import Settings
from ladle.db.models import (
    ExtractionCache,
    NegativeExtractionCache,
    SourceVideo,
)
from ladle.db.session import build_engine, build_session_factory
from ladle.imports.thumbnail_backfill import ThumbnailBackfillService
from ladle.imports.thumbnails import OEmbedThumbnailFetcher
from ladle.worker.runtime import runtime_object_storage


class CacheAdministrator:
    def __init__(self, *, clock: Clock) -> None:
        self._clock = clock

    def invalidate(
        self,
        database: Session,
        *,
        platform: str,
        platform_video_id: str,
    ) -> int:
        source_id = database.scalar(
            select(SourceVideo.id).where(
                SourceVideo.platform == platform,
                SourceVideo.platform_video_id == platform_video_id,
            )
        )
        if source_id is None:
            return 0
        result = database.execute(
            update(ExtractionCache)
            .where(
                ExtractionCache.source_video_id == source_id,
                ExtractionCache.invalidated_at.is_(None),
            )
            .values(invalidated_at=self._clock.now())
        )
        database.execute(
            delete(NegativeExtractionCache).where(
                NegativeExtractionCache.source_video_id == source_id
            )
        )
        return int(cast(Any, result).rowcount or 0)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Manage Ladle extraction cache")
    subparsers = parser.add_subparsers(dest="command", required=True)
    invalidate = subparsers.add_parser("invalidate")
    invalidate.add_argument(
        "--platform",
        required=True,
        choices=("youtube", "tiktok", "instagram"),
    )
    invalidate.add_argument("--video-id", required=True)
    subparsers.add_parser(
        "backfill-thumbnails",
        help="copy legacy provider thumbnails into private object storage",
    )
    arguments = parser.parse_args(argv)

    settings = Settings()
    sessions = build_session_factory(build_engine(settings.database_url))
    if arguments.command == "backfill-thumbnails":
        storage = runtime_object_storage()
        if storage is None:
            parser.error("object storage must be enabled for thumbnail backfill")
        with (
            httpx.Client(
                timeout=httpx.Timeout(connect=5.0, read=15.0, write=15.0, pool=5.0),
                follow_redirects=False,
            ) as http,
            sessions.begin() as database,
        ):
            count = ThumbnailBackfillService(
                fetcher=OEmbedThumbnailFetcher(
                    http=http,
                    storage=storage,
                )
            ).run(database)
        print(f"backfilled {count} cache thumbnails")
        return 0
    with sessions.begin() as database:
        count = CacheAdministrator(clock=SystemClock()).invalidate(
            database,
            platform=arguments.platform,
            platform_video_id=arguments.video_id,
        )
    print(f"invalidated {count} cache entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
