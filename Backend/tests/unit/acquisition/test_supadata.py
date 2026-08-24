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


def test_metadata_and_native_transcript_contracts() -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
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

    assert metadata.title == "One-Pot Lemon Orzo"
    assert metadata.creator_name == "Ladle Kitchen"
    assert metadata.thumbnail_url == "https://images.example/recipe.jpg"
    assert transcript.language == "en"
    assert transcript.segments[0].start_seconds == 1
    assert not transcript.segments[0].generated
    assert [request.url.path for request in requests] == [
        "/v1/metadata",
        "/v1/transcript",
    ]


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
