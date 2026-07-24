import os
from uuid import uuid4

import httpx
import pytest
from pydantic import SecretStr

from ladle.acquisition.models import SourceVideoDescriptor
from ladle.acquisition.soscripted import SoScriptedClient
from ladle.acquisition.supadata import SupadataClient

PUBLIC_VIDEO = SourceVideoDescriptor(
    source_video_id=uuid4(),
    platform="youtube",
    platform_video_id="dQw4w9WgXcQ",
    canonical_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    source_revision="live-smoke",
)


@pytest.mark.live_provider
def test_supadata_reports_metadata_and_native_transcript_capabilities() -> None:
    key = os.environ.get("LADLE_SUPADATA_API_KEY")
    if not key:
        pytest.skip("LADLE_SUPADATA_API_KEY is not configured")
    with httpx.Client(timeout=30) as http:
        client = SupadataClient(
            http=http,
            api_key=SecretStr(key),
            base_url=os.environ.get(
                "LADLE_SUPADATA_BASE_URL",
                "https://api.supadata.ai/v1",
            ),
        )
        metadata = client.metadata(PUBLIC_VIDEO, job_id=uuid4())
        transcript = client.transcript(
            PUBLIC_VIDEO,
            job_id=uuid4(),
            mode="native",
        )
    assert metadata.title
    assert transcript.segments


@pytest.mark.live_provider
def test_soscripted_reports_transcript_capability() -> None:
    key = os.environ.get("LADLE_SOSCRIPTED_API_KEY")
    if not key:
        pytest.skip("LADLE_SOSCRIPTED_API_KEY is not configured")
    with httpx.Client(timeout=600) as http:
        client = SoScriptedClient(
            http=http,
            api_key=SecretStr(key),
            base_url=os.environ.get(
                "LADLE_SOSCRIPTED_BASE_URL",
                "https://soscripted.com/api/public",
            ),
        )
        transcript = client.transcript(PUBLIC_VIDEO, job_id=uuid4())
    assert transcript.segments
