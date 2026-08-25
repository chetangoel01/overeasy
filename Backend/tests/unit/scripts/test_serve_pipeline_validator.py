from collections.abc import Callable
from typing import Any

import pytest
from fastapi.testclient import TestClient

from scripts import serve_pipeline_validator


class ImmediateExecutor:
    def submit(self, function: Callable[[], None]) -> None:
        function()


class HeldExecutor:
    def __init__(self) -> None:
        self.pending: list[Callable[[], None]] = []

    def submit(self, function: Callable[[], None]) -> None:
        self.pending.append(function)

    def run_next(self) -> None:
        self.pending.pop(0)()


class SuccessfulRunner:
    def __init__(self) -> None:
        self.urls: list[str] = []

    def run(
        self,
        url: str,
        progress: Callable[[str, str], None],
    ) -> dict[str, Any]:
        self.urls.append(url)
        progress("acquiring", "Reading creator evidence")
        progress("extracting", "Extracting with Gemini 3.7")
        return {
            "modelID": "google/gemini-3.7-flash",
            "recipe": {
                "title": "Test Noodles",
                "servings": "2",
                "servings_basis": "stated",
                "review_status": "ready",
                "ingredients": [],
                "steps": [],
                "uncertainties": [],
            },
        }


def service(
    runner: object,
    *,
    executor: object | None = None,
    secrets: tuple[str, ...] = (),
) -> serve_pipeline_validator.ValidationJobService:
    return serve_pipeline_validator.ValidationJobService(
        runner=runner,
        executor=executor or ImmediateExecutor(),
        secret_values=secrets,
    )


def test_valid_source_is_canonicalized_and_completed() -> None:
    runner = SuccessfulRunner()
    jobs = service(runner)

    job_id = jobs.submit(
        "https://www.tiktok.com/@cook/video/7612708181004799263?sender_device=pc"
    )

    assert runner.urls == [
        "https://www.tiktok.com/@cook/video/7612708181004799263"
    ]
    assert jobs.status(job_id) == {
        "jobID": job_id,
        "status": "succeeded",
        "stage": "complete",
        "message": "Recipe ready",
        "sourceURL": runner.urls[0],
        "result": {
            "modelID": "google/gemini-3.7-flash",
            "recipe": {
                "title": "Test Noodles",
                "servings": "2",
                "servings_basis": "stated",
                "review_status": "ready",
                "ingredients": [],
                "steps": [],
                "uncertainties": [],
            },
        },
    }


def test_invalid_source_is_rejected_before_job_creation() -> None:
    with pytest.raises(serve_pipeline_validator.InvalidValidationURL):
        service(SuccessfulRunner()).submit("https://example.com/not-a-recipe")


def test_only_one_validation_can_spend_at_a_time() -> None:
    executor = HeldExecutor()
    jobs = service(SuccessfulRunner(), executor=executor)
    first = jobs.submit("https://www.instagram.com/p/DbbHIKHM3xr/")

    with pytest.raises(serve_pipeline_validator.ValidationBusy):
        jobs.submit("https://www.instagram.com/p/AnotherPost/")

    executor.run_next()

    assert jobs.status(first)["status"] == "succeeded"
    assert jobs.submit("https://www.instagram.com/p/AnotherPost/")


def test_failure_is_typed_and_configured_secret_is_redacted() -> None:
    class FailingRunner:
        def run(
            self,
            url: str,
            progress: Callable[[str, str], None],
        ) -> dict[str, Any]:
            del url, progress
            raise RuntimeError("provider rejected sk-or-v1-test-secret")

    jobs = service(
        FailingRunner(),
        secrets=("sk-or-v1-test-secret",),
    )
    job_id = jobs.submit("https://www.instagram.com/p/DbbHIKHM3xr/")
    state = jobs.status(job_id)

    assert state["status"] == "failed"
    assert state["errorType"] == "RuntimeError"
    assert state["error"] == "provider rejected [redacted]"
    assert "sk-or-v1" not in str(state)


def test_api_admits_and_returns_job_state() -> None:
    jobs = service(SuccessfulRunner())
    with TestClient(serve_pipeline_validator.create_app(jobs)) as client:
        admitted = client.post(
            "/api/validate",
            json={"sourceURL": "https://www.instagram.com/p/DbbHIKHM3xr/"},
        )
        assert admitted.status_code == 202

        state = client.get(f"/api/jobs/{admitted.json()['jobID']}")

    assert state.status_code == 200
    assert state.json()["result"]["recipe"]["servings"] == "2"


@pytest.mark.parametrize(
    ("payload", "status"),
    [
        ({"sourceURL": "https://example.com/nope"}, 422),
        ({"sourceURL": ""}, 422),
        ({}, 422),
    ],
)
def test_api_returns_typed_invalid_input(payload: dict[str, str], status: int) -> None:
    with TestClient(
        serve_pipeline_validator.create_app(service(SuccessfulRunner()))
    ) as client:
        response = client.post("/api/validate", json=payload)

    assert response.status_code == status
    assert response.json()["error"] == "invalidSourceURL"
