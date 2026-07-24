import json
from pathlib import Path
from uuid import uuid4

import httpx
from pydantic import SecretStr

from ladle.acquisition.models import SourceVideoDescriptor
from ladle.acquisition.soscripted import SoScriptedClient

FIXTURE = (
    Path(__file__).parents[2]
    / "fixtures"
    / "providers"
    / "soscripted"
    / "transcript.json"
)


def test_synchronous_transcript_contract_and_bearer_auth() -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/api/public/transcribe"
        assert request.headers["authorization"] == "Bearer soscripted-secret"
        assert json.loads(request.content) == {
            "url": "https://www.youtube.com/watch?v=recipe-video"
        }
        return httpx.Response(200, json=json.loads(FIXTURE.read_text()))

    source = SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="youtube",
        platform_video_id="recipe-video",
        canonical_url="https://www.youtube.com/watch?v=recipe-video",
        source_revision="1",
    )
    client = SoScriptedClient(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        api_key=SecretStr("soscripted-secret"),
        base_url="https://soscripted.com/api/public",
        sleeper=lambda _: None,
    )

    result = client.transcript(source, job_id=uuid4())

    assert result.segments[0].text == "Add two cups of orzo."
    assert result.segments[0].generated
    assert result.billed_units == 1
