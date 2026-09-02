"""Why the backfill gave up, in the operator's own words.

The first production run estimated 13 recipes and then reported "no estimate
returned" for the remaining 9 — recipes that had estimated fine locally. The
client treated every non-200 alike and never retried, so a rate limit after a
burst of requests was indistinguishable from a model that declined. These
tests pin both halves of the fix: the retry, and a reason specific enough to
tell those two apart.
"""

from collections.abc import Callable
from types import SimpleNamespace
from typing import cast

import anthropic
import httpx
import httpx2

from ladle.admin.backfill_times import (
    AnthropicTimeEstimateClient,
    EstimateOutcome,
    EvidenceStep,
    EvidenceTimer,
    OpenRouterTimeEstimateClient,
    RecipeTimeEvidence,
    TimeEstimate,
)

Handler = Callable[[httpx.Request], httpx.Response]


def evidence() -> RecipeTimeEvidence:
    return RecipeTimeEvidence(
        title="Lemon Orzo",
        description="No times anywhere in the caption.",
        ingredients=["2 cups orzo"],
        steps=[
            EvidenceStep(
                order_index=0,
                instruction="Simmer the orzo until tender.",
                timers=[EvidenceTimer(label="Simmer", duration_seconds=600)],
            )
        ],
    )


def client(
    handler: Handler, *, sleep: Callable[[float], None]
) -> OpenRouterTimeEstimateClient:
    return OpenRouterTimeEstimateClient(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        api_key="test-key",
        base_url="https://openrouter.test/api/v1",
        sleep=sleep,
    )


def answer(minutes: int, *, finish_reason: str = "stop") -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "choices": [
                {
                    "finish_reason": finish_reason,
                    "message": {"content": f'{{"totalMinutes": {minutes}}}'},
                }
            ]
        },
    )


def ask(
    handler: Handler,
    *,
    sleep: Callable[[float], None],
) -> EstimateOutcome:
    return client(handler, sleep=sleep).estimate(
        model="test-model",
        max_tokens=256,
        evidence=evidence(),
    )


def test_rate_limit_is_retried_and_the_answer_still_arrives() -> None:
    responses = iter(
        [
            httpx.Response(429, headers={"Retry-After": "0"}),
            httpx.Response(429, headers={"Retry-After": "0"}),
            answer(25),
        ]
    )
    delays: list[float] = []

    outcome = ask(lambda request: next(responses), sleep=delays.append)

    assert outcome.estimate is not None
    assert outcome.estimate.total_minutes == 25
    assert outcome.failure is None
    # The server's own Retry-After is honoured rather than a fixed backoff.
    assert delays == [0.0, 0.0]


def test_exhausted_rate_limit_says_so_rather_than_blaming_the_model() -> None:
    attempts = 0
    delays: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        del request
        nonlocal attempts
        attempts += 1
        return httpx.Response(429)

    outcome = ask(handler, sleep=delays.append)

    assert outcome.estimate is None
    assert outcome.failure == "provider 429 after 3 attempts"
    assert attempts == 3
    # Exponential where the server offers no Retry-After of its own.
    assert delays == [2.0, 4.0]


def test_server_error_is_retried_and_then_named() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        del request
        nonlocal attempts
        attempts += 1
        return httpx.Response(502)

    outcome = ask(handler, sleep=lambda seconds: None)

    assert outcome.failure == "provider 502"
    assert attempts == 3


def test_a_server_error_that_clears_is_not_a_failure() -> None:
    responses = iter([httpx.Response(503), answer(40)])

    outcome = ask(lambda request: next(responses), sleep=lambda seconds: None)

    assert outcome.estimate is not None
    assert outcome.estimate.total_minutes == 40


def test_other_client_errors_are_not_retried() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        del request
        nonlocal attempts
        attempts += 1
        return httpx.Response(400)

    outcome = ask(handler, sleep=lambda seconds: None)

    assert outcome.failure == "provider 400"
    # A malformed request will be malformed the next two times as well.
    assert attempts == 1


def test_transport_failure_names_the_exception() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        raise httpx.ConnectError("no route", request=request)

    outcome = ask(handler, sleep=lambda seconds: None)

    assert outcome.failure == "request failed (ConnectError)"
    assert attempts == 3


def test_a_transport_failure_that_clears_is_retried_into_an_answer() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise httpx.ReadTimeout("slow", request=request)
        return answer(30)

    outcome = ask(handler, sleep=lambda seconds: None)

    assert outcome.estimate is not None
    assert outcome.estimate.total_minutes == 30


def test_an_unreadable_reply_is_distinguished_from_a_provider_failure() -> None:
    outcome = ask(
        lambda request: httpx.Response(200, json={"choices": []}),
        sleep=lambda seconds: None,
    )

    assert outcome.estimate is None
    assert outcome.failure == "no estimate in reply"


def test_a_truncated_reply_is_not_read_as_an_estimate() -> None:
    outcome = ask(
        lambda request: answer(25, finish_reason="length"),
        sleep=lambda seconds: None,
    )

    assert outcome.failure == "no estimate in reply"


def test_a_null_content_body_is_a_reply_with_no_estimate() -> None:
    # A content filter answers 200 with a null body. Reading that as text
    # raised outside the handled tuple, which aborted the whole run.
    outcome = ask(
        lambda request: httpx.Response(
            200,
            json={"choices": [{"finish_reason": "stop", "message": {"content": None}}]},
        ),
        sleep=lambda seconds: None,
    )

    assert outcome.estimate is None
    assert outcome.failure == "no estimate in reply"


def test_the_anthropic_client_honours_the_providers_retry_after() -> None:
    """The other provider meets the same rate limiter.

    Its SDK carries the response on the exception, from a different httpx
    distribution than ours, which is why the shared helper takes the header
    value rather than a response object.
    """
    delays: list[float] = []
    attempts = 0

    def parse(**arguments: object) -> object:
        nonlocal attempts
        attempts += 1
        if attempts <= 2:
            raise anthropic.RateLimitError(
                "slow down",
                response=httpx2.Response(
                    429,
                    headers={"Retry-After": "3"},
                    request=httpx2.Request("POST", "https://api.anthropic.test/v1"),
                ),
                body=None,
            )
        return SimpleNamespace(
            stop_reason="end_turn",
            parsed_output=TimeEstimate(total_minutes=35),
        )

    client = AnthropicTimeEstimateClient(
        cast(
            anthropic.Anthropic, SimpleNamespace(messages=SimpleNamespace(parse=parse))
        ),
        sleep=delays.append,
    )

    outcome = client.estimate(model="m", max_tokens=256, evidence=evidence())

    assert outcome.estimate is not None
    assert outcome.estimate.total_minutes == 35
    assert delays == [3.0, 3.0]


def test_the_anthropic_client_names_an_exhausted_rate_limit() -> None:
    def parse(**arguments: object) -> object:
        raise anthropic.RateLimitError(
            "slow down",
            response=httpx2.Response(
                429,
                request=httpx2.Request("POST", "https://api.anthropic.test/v1"),
            ),
            body=None,
        )

    client = AnthropicTimeEstimateClient(
        cast(
            anthropic.Anthropic, SimpleNamespace(messages=SimpleNamespace(parse=parse))
        ),
        sleep=lambda seconds: None,
    )

    outcome = client.estimate(model="m", max_tokens=256, evidence=evidence())

    assert outcome.failure == "provider 429 after 3 attempts"
