import json
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
from pydantic import SecretStr

from ladle.acquisition.errors import ProviderAuthenticationError
from ladle.acquisition.models import SourceVideoDescriptor
from ladle.acquisition.supadata import SupadataClient

FIXTURES = Path(__file__).parents[2] / "fixtures" / "providers" / "supadata"


def source() -> SourceVideoDescriptor:
    return SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="youtube",
        platform_video_id="recipe-video",
        canonical_url="https://www.youtube.com/watch?v=recipe-video",
        source_revision="1",
    )


def test_metadata_native_transcript_and_async_visual_contracts() -> None:
    requests: list[httpx.Request] = []
    poll_count = 0

    def respond(request: httpx.Request) -> httpx.Response:
        nonlocal poll_count
        requests.append(request)
        assert request.headers["x-api-key"] == "supadata-secret"
        if request.url.path == "/v1/metadata":
            return httpx.Response(
                200,
                json=json.loads((FIXTURES / "metadata.json").read_text()),
                headers={"x-billable-requests": "1"},
            )
        if request.url.path == "/v1/transcript":
            assert request.url.params["mode"] == "native"
            return httpx.Response(
                200,
                json=json.loads((FIXTURES / "transcript.json").read_text()),
                headers={"x-billable-requests": "1"},
            )
        if request.url.path == "/v1/extract" and request.method == "POST":
            body = json.loads(request.content)
            assert body["url"] == source().canonical_url
            assert body["schema"]["required"] == ["observations"]
            return httpx.Response(
                202,
                json={"jobId": "extract-job-1"},
                headers={"x-billable-requests": "3"},
            )
        if request.url.path == "/v1/extract/extract-job-1":
            poll_count += 1
            if poll_count == 1:
                return httpx.Response(200, json={"status": "active"})
            return httpx.Response(
                200,
                json=json.loads((FIXTURES / "extract-completed.json").read_text()),
            )
        raise AssertionError(f"unexpected request: {request.method} {request.url}")

    client = SupadataClient(
        http=httpx.Client(
            transport=httpx.MockTransport(respond),
            base_url="https://api.supadata.ai",
        ),
        api_key=SecretStr("supadata-secret"),
        base_url="https://api.supadata.ai/v1",
        poll_attempts=3,
        sleeper=lambda _: None,
    )

    metadata = client.metadata(source(), job_id=uuid4())
    transcript = client.transcript(source(), job_id=uuid4(), mode="native")
    visual = client.visual(source(), job_id=uuid4())

    assert metadata.title == "One-Pot Lemon Orzo"
    assert metadata.creator_name == "Ladle Kitchen"
    assert metadata.thumbnail_url == "https://images.example/recipe.jpg"
    assert transcript.language == "en"
    assert transcript.segments[0].start_seconds == 1
    assert not transcript.segments[0].generated
    assert visual.observations[0].text == "2 cups orzo"
    assert visual.external_job_id == "extract-job-1"
    assert visual.billed_units == 3
    assert poll_count == 2


def test_authentication_error_is_typed_without_exposing_key() -> None:
    client = SupadataClient(
        http=httpx.Client(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(401, json={"error": "unauthorized"})
            )
        ),
        api_key=SecretStr("never-log-me"),
        base_url="https://api.supadata.ai/v1",
        sleeper=lambda _: None,
    )

    with pytest.raises(ProviderAuthenticationError) as error:
        client.metadata(source(), job_id=uuid4())

    assert "never-log-me" not in str(error.value)
