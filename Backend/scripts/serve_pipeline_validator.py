"""Serve a localhost-only browser harness for the live recipe pipeline.

Run ``python scripts/serve_pipeline_validator.py`` from ``Backend``. API keys
are read from ``LADLE_OPENROUTER_API_KEY`` and ``LADLE_USDA_API_KEY`` or asked
for without echoing. They are never sent to the browser.
"""

from __future__ import annotations

import argparse
import copy
import getpass
import os
import threading
import time
import uuid
import webbrowser
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Protocol, cast

import uvicorn
from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse, Response

from ladle.acquisition.models import SourceVideoDescriptor
from ladle.acquisition.provider_chain import ProviderChain
from ladle.config import Settings
from ladle.extraction.evidence_gate import require_recipe_evidence
from ladle.imports.source_identity import (
    InvalidSourceURL,
    SourceIdentityParser,
    UnsupportedSource,
)
from ladle.usage.ledger import NullProviderUsageSink
from ladle.worker.runtime import _audio_transcriber, _creator_search, _free_acquirer
from scripts.eval_extraction import VerificationUsage, _case_usage, _pipeline

MODEL_ID = "google/gemini-3.7-flash"
TOOLS = Path(__file__).resolve().parent.parent / "tools"
Progress = Callable[[str, str], None]


class InvalidValidationURL(Exception):
    """The submitted URL is not a supported public video URL."""


class ValidationBusy(Exception):
    """A paid validation is already queued or running."""


class ValidationRunner(Protocol):
    def run(self, url: str, progress: Progress) -> dict[str, Any]: ...


class JobExecutor(Protocol):
    def submit(self, function: Callable[[], None]) -> object: ...


class ValidationJobService:
    """Own the single-spend job queue and its browser-safe state."""

    def __init__(
        self,
        *,
        runner: ValidationRunner,
        executor: JobExecutor | None = None,
        secret_values: tuple[str, ...] = (),
    ) -> None:
        self._runner = runner
        self._executor = executor or cast(
            JobExecutor, ThreadPoolExecutor(max_workers=1)
        )
        self._secret_values = tuple(value for value in secret_values if value)
        self._jobs: dict[str, dict[str, Any]] = {}
        self._active_job_id: str | None = None
        self._lock = threading.Lock()

    def submit(self, url: str) -> str:
        canonical_url = self._canonical_url(url)
        job_id = str(uuid.uuid4())
        with self._lock:
            if self._active_job_id is not None:
                raise ValidationBusy("one validation is already in progress")
            self._active_job_id = job_id
            self._jobs[job_id] = {
                "jobID": job_id,
                "status": "queued",
                "stage": "queued",
                "message": "Waiting to start",
                "sourceURL": canonical_url,
            }
        self._executor.submit(lambda: self._run(job_id, canonical_url))
        return job_id

    def status(self, job_id: str) -> dict[str, Any]:
        with self._lock:
            if job_id not in self._jobs:
                raise KeyError(job_id)
            return copy.deepcopy(self._jobs[job_id])

    def _run(self, job_id: str, url: str) -> None:
        self._update(job_id, status="running", stage="starting", message="Starting")

        def progress(stage: str, message: str) -> None:
            self._update(job_id, stage=stage, message=message)

        try:
            result = self._runner.run(url, progress)
        except Exception as error:  # the browser needs a typed terminal state
            message = str(error) or type(error).__name__
            for secret in self._secret_values:
                message = message.replace(secret, "[redacted]")
            self._update(
                job_id,
                status="failed",
                stage="failed",
                message="Validation failed",
                errorType=type(error).__name__,
                error=message[:1_000],
            )
        else:
            self._update(
                job_id,
                status="succeeded",
                stage="complete",
                message="Recipe ready",
                result=result,
            )
        finally:
            with self._lock:
                if self._active_job_id == job_id:
                    self._active_job_id = None

    def _update(self, job_id: str, **values: Any) -> None:
        with self._lock:
            self._jobs[job_id].update(values)

    @staticmethod
    def _canonical_url(url: str) -> str:
        if not isinstance(url, str) or not url.strip():
            raise InvalidValidationURL("enter a TikTok, Instagram, or YouTube URL")
        try:
            return SourceIdentityParser().parse(url.strip()).canonical_url
        except (InvalidSourceURL, UnsupportedSource) as error:
            raise InvalidValidationURL(str(error)) from error


class LivePipelineRunner:
    """Run the same acquisition, evidence gate, and Gemini pipeline as evals."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def run(self, url: str, progress: Progress) -> dict[str, Any]:
        started = time.perf_counter()
        identity = SourceIdentityParser().parse(url)
        source = SourceVideoDescriptor(
            source_video_id=uuid.uuid5(uuid.NAMESPACE_URL, url),
            platform=identity.platform.value,
            platform_video_id=identity.platform_video_id,
            canonical_url=identity.canonical_url,
            source_revision="pipeline-validator-v1",
        )
        job_id = uuid.uuid4()
        usage = NullProviderUsageSink()
        progress("acquiring", "Reading creator evidence")
        acquirer = ProviderChain(
            primary=None,
            fallback=None,
            free=_free_acquirer(self._settings),
            audio=_audio_transcriber(self._settings, usage=cast(Any, usage)),
            search=_creator_search(self._settings),
        )
        context = acquirer.acquire(source, job_id=job_id)
        progress("checking", "Checking recipe evidence")
        require_recipe_evidence(context)
        progress("extracting", "Extracting with Gemini 3.7 Flash")
        pipeline = _pipeline(self._settings, model_id=MODEL_ID)
        response, _extraction, template = pipeline.run(context)
        verification = (
            pipeline.verification_recorder.usage
            if pipeline.verification_recorder is not None
            else VerificationUsage()
        )
        return {
            "modelID": MODEL_ID,
            "elapsedSeconds": round(time.perf_counter() - started, 3),
            "acquisitionDiagnostics": context.diagnostics,
            "usage": _case_usage(response, verification),
            "recipe": template.model_dump(mode="json"),
        }


class DemoPipelineRunner:
    """Exercise the full UI without spending money or requiring credentials."""

    def run(self, url: str, progress: Progress) -> dict[str, Any]:
        for stage, message in (
            ("acquiring", "Reading creator evidence"),
            ("checking", "Checking recipe evidence"),
            ("extracting", "Extracting with Gemini 3.7 Flash"),
        ):
            progress(stage, message)
            time.sleep(0.2)
        return {
            "modelID": MODEL_ID,
            "elapsedSeconds": 0.6,
            "acquisitionDiagnostics": ["demoMode"],
            "usage": {"reportedCostUSD": "0", "reportedCostComplete": True},
            "recipe": {
                "title": "Chili Garlic Noodles",
                "description": "A deterministic preview of the validation UI.",
                "creator_name": "Ladle Test Kitchen",
                "original_url": url,
                "servings": "2",
                "servings_basis": "stated",
                "review_status": "ready",
                "total_minutes": 15,
                "ingredients": [
                    {"quantity_text": "8 oz", "name": "noodles"},
                    {"quantity_text": "2 tbsp", "name": "chili crisp"},
                    {"quantity_text": "2 cloves", "name": "garlic, minced"},
                ],
                "steps": [
                    {"instruction": "Cook the noodles until just tender."},
                    {"instruction": "Toss with chili crisp and garlic."},
                ],
                "uncertainties": [],
            },
        }


def create_app(jobs: ValidationJobService) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    @app.post("/api/validate")
    def validate(payload: dict[str, Any]) -> JSONResponse:
        source_url = payload.get("sourceURL")
        if not isinstance(source_url, str):
            return JSONResponse(
                {
                    "error": "invalidSourceURL",
                    "message": "enter a TikTok, Instagram, or YouTube URL",
                },
                status_code=422,
            )
        try:
            job_id = jobs.submit(source_url)
        except InvalidValidationURL as error:
            return JSONResponse(
                {"error": "invalidSourceURL", "message": str(error)},
                status_code=422,
            )
        except ValidationBusy as error:
            return JSONResponse(
                {"error": "validationBusy", "message": str(error)},
                status_code=409,
            )
        return JSONResponse({"jobID": job_id}, status_code=202)

    @app.get("/api/jobs/{job_id}")
    def job(job_id: str) -> JSONResponse:
        try:
            return JSONResponse(jobs.status(job_id))
        except KeyError:
            return JSONResponse(
                {"error": "jobNotFound", "message": "validation job not found"},
                status_code=404,
            )

    def page(name: str) -> Response:
        path = TOOLS / name
        if not path.is_file():
            return JSONResponse({"error": "pageNotBuilt"}, status_code=404)
        return FileResponse(path)

    @app.get("/")
    @app.get("/pipeline-validator.html")
    def validator_page() -> Response:
        return page("pipeline-validator.html")

    @app.get("/pipeline-results.html")
    def results_page() -> Response:
        return page("pipeline-results.html")

    return app


def _required_secret(name: str, prompt: str) -> str:
    value = os.getenv(name, "")
    if not value:
        value = getpass.getpass(prompt).strip()
    if not value:
        raise SystemExit(f"{name} is required")
    os.environ[name] = value
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument(
        "--demo",
        action="store_true",
        help="preview the interface without API calls",
    )
    args = parser.parse_args()
    secrets: tuple[str, ...] = ()
    runner: ValidationRunner
    if args.demo:
        runner = DemoPipelineRunner()
    else:
        openrouter = _required_secret(
            "LADLE_OPENROUTER_API_KEY", "OpenRouter API key: "
        )
        usda = _required_secret("LADLE_USDA_API_KEY", "USDA API key: ")
        settings = Settings(
            extraction_provider="openrouter",
            openrouter_model_id=MODEL_ID,
            openrouter_api_key=openrouter,
            usda_api_key=usda,
        )
        runner = LivePipelineRunner(settings)
        secrets = (openrouter, usda)
    app = create_app(ValidationJobService(runner=runner, secret_values=secrets))
    url = f"http://127.0.0.1:{args.port}/"
    if not args.no_open:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
