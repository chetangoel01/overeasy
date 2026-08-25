import json
import re
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from scripts import serve_pipeline_validator

TOOLS = Path(__file__).resolve().parents[3] / "tools"


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


def test_results_page_embeds_five_safe_complete_recipe_records() -> None:
    page = TOOLS / "pipeline-results.html"
    html = page.read_text()
    match = re.search(
        r'<script id="pipeline-results-data" type="application/json">(.*?)</script>',
        html,
        re.DOTALL,
    )

    assert '<meta name="viewport"' in html
    assert "<main" in html and "<nav" in html
    assert "@media (prefers-reduced-motion: reduce)" in html
    assert '<script src=' not in html
    assert "sk-or-v1" not in html
    assert match is not None
    records = json.loads(match.group(1))
    assert len(records) == 5
    assert {record["sourceURL"] for record in records} == {
        "https://www.tiktok.com/@zachs.foods/video/7612708181004799263",
        "https://www.tiktok.com/@iankyo/video/7436430114910506271",
        "https://www.tiktok.com/@alexcookjoy/video/7574621199519567136",
        "https://www.tiktok.com/@foodiligence/video/7581152180174966030",
        "https://www.instagram.com/p/DbbHIKHM3xr/",
    }
    assert sum(float(record["knownCostUSD"]) for record in records) == pytest.approx(
        0.0783865776875
    )
    for record in records:
        recipe = record["recipe"]
        assert recipe["servings"]
        assert recipe["servings_basis"] in {"stated", "estimatedFromYield"}
        assert recipe["review_status"] in {"ready", "needsReview"}
        assert recipe["ingredients"]
        assert recipe["steps"]
        assert record["processSeconds"] > 0


def test_validator_page_has_accessible_safe_live_pipeline_contract() -> None:
    html = (TOOLS / "pipeline-validator.html").read_text()

    assert '<meta name="viewport"' in html
    assert "<main" in html and "<form" in html
    assert '<label for="source-url"' in html
    assert 'id="source-url"' in html and 'type="url"' in html
    assert 'id="run-validation"' in html and 'type="submit"' in html
    assert 'aria-live="polite"' in html
    for output_id in (
        "stage-status",
        "servings-output",
        "servings-basis",
        "ingredients-output",
        "steps-output",
        "uncertainties-output",
        "nutrition-output",
        "calories-output",
        "protein-output",
        "carbohydrates-output",
        "fat-output",
        "whole-recipe-nutrition",
        "nutrition-evidence",
    ):
        assert f'id="{output_id}"' in html
    assert "api/validate" in html and "api/jobs/" in html
    assert "AbortController" in html
    assert "location.protocol === 'file:'" in html
    assert "textContent" in html
    assert "innerHTML" not in html
    assert '<script src=' not in html
    assert "sk-or-v1" not in html


def test_both_pages_render_nutrition_and_visible_blockers() -> None:
    validator = (TOOLS / "pipeline-validator.html").read_text()
    results = (TOOLS / "pipeline-results.html").read_text()

    for html in (validator, results):
        assert "Calories" in html
        assert "Protein" in html
        assert "Carbohydrates" in html
        assert "Fat" in html
        assert "Per serving" in html
        assert "Whole recipe" in html
        assert "nutrition" in html
        assert "needsReview" in html


def test_server_serves_both_html_pages_without_secrets() -> None:
    with TestClient(
        serve_pipeline_validator.create_app(service(SuccessfulRunner()))
    ) as client:
        validator = client.get("/")
        results = client.get("/pipeline-results.html")

    assert validator.status_code == results.status_code == 200
    assert validator.headers["content-type"].startswith("text/html")
    assert results.headers["content-type"].startswith("text/html")
    assert "sk-or-v1" not in validator.text + results.text
