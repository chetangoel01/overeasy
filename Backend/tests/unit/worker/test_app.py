import ast
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import pytest
from billiard.exceptions import SoftTimeLimitExceeded
from redis.exceptions import ConnectionError as RedisConnectionError
from sqlalchemy.exc import TimeoutError as SQLAlchemyTimeoutError

from ladle.acquisition.errors import ProviderTransientError
from ladle.cache.claims import ClaimLost
from ladle.config import Settings
from ladle.imports.dispatcher import PROCESS_IMPORT_TASK
from ladle.imports.maintenance import RELEASE_EXPIRED_RESERVATIONS_TASK
from ladle.privacy.retention import RETENTION_SWEEP_TASK
from ladle.worker.app import (
    celery_app,
    configure_worker_logging,
    create_celery_app,
    record_worker_heartbeat,
)
from ladle.worker.tasks import is_retryable_import_failure, retry_countdown

BACKEND = Path(__file__).parents[3]


def test_free_acquirer_runtime_builder_returns_the_configured_acquirer() -> None:
    from ladle.acquisition.free import FreeAcquirer
    from ladle.worker.runtime import _free_acquirer

    built = _free_acquirer(Settings(_env_file=None))

    assert isinstance(built, FreeAcquirer)


def test_creator_search_runtime_builder_preserves_configured_bounds() -> None:
    from pydantic import SecretStr

    from ladle.acquisition.search import SparseTextEnricher
    from ladle.worker.runtime import _creator_search

    built = _creator_search(
        Settings(
            openrouter_api_key=SecretStr("search-key"),
            creator_search_maximum_queries=4,
            creator_search_maximum_results=9,
            _env_file=None,
        )
    )

    assert isinstance(built, SparseTextEnricher)
    assert built._maximum_queries == 4
    assert built._maximum_candidates == 9


def test_creator_search_runtime_builder_respects_explicit_disable() -> None:
    from pydantic import SecretStr

    from ladle.worker.runtime import _creator_search

    built = _creator_search(
        Settings(
            openrouter_api_key=SecretStr("search-key"),
            creator_search_enabled=False,
            _env_file=None,
        )
    )

    assert built is None


def test_enabled_creator_search_requires_its_openrouter_key() -> None:
    from ladle.worker.runtime import _creator_search

    with pytest.raises(RuntimeError, match="creator search requires an OpenRouter"):
        _creator_search(
            Settings(
                creator_search_enabled=True,
                openrouter_api_key=None,
                _env_file=None,
            )
        )


def test_nutrition_runtime_builder_preserves_configured_bounds() -> None:
    from pydantic import SecretStr

    from ladle.nutrition.calculator import NutritionCalculator
    from ladle.worker.runtime import _nutrition_calculator

    built = _nutrition_calculator(
        Settings(
            usda_api_key=SecretStr("food-key"),
            usda_maximum_candidates=7,
            _env_file=None,
        )
    )

    assert isinstance(built, NutritionCalculator)
    assert built._source._maximum_candidates == 7


def test_nutrition_runtime_builder_respects_explicit_disable() -> None:
    from ladle.worker.runtime import _nutrition_calculator

    assert (
        _nutrition_calculator(Settings(usda_nutrition_enabled=False, _env_file=None))
        is None
    )


def test_enabled_nutrition_requires_a_usda_key() -> None:
    from ladle.worker.runtime import _nutrition_calculator

    with pytest.raises(RuntimeError, match="nutrition requires a USDA API key"):
        _nutrition_calculator(
            Settings(
                usda_nutrition_enabled=True,
                usda_api_key=None,
                _env_file=None,
            )
        )


def test_nutrition_service_uses_gemini_normalization_and_usda() -> None:
    from pydantic import SecretStr

    from ladle.nutrition.service import RecipeNutritionService
    from ladle.worker.runtime import _nutrition_service

    built = _nutrition_service(
        Settings(
            openrouter_api_key=SecretStr("model-key"),
            usda_api_key=SecretStr("food-key"),
            nutrition_normalization_model_id="google/gemini-3.7-flash",
            _env_file=None,
        ),
        usage=None,
    )

    assert isinstance(built, RecipeNutritionService)
    assert built._normalizer._model_id == "google/gemini-3.7-flash"


def test_nutrition_service_requires_openrouter_for_normalization() -> None:
    from pydantic import SecretStr

    from ladle.worker.runtime import _nutrition_service

    with pytest.raises(RuntimeError, match="normalization requires an OpenRouter"):
        _nutrition_service(
            Settings(
                openrouter_api_key=None,
                usda_api_key=SecretStr("food-key"),
                _env_file=None,
            ),
            usage=None,
        )


def test_recipe_verifier_runtime_builder_uses_extraction_model() -> None:
    from pydantic import SecretStr

    from ladle.extraction.verification import TargetedRecipeVerifier
    from ladle.worker.runtime import _recipe_verifier

    built = _recipe_verifier(
        Settings(
            openrouter_api_key=SecretStr("verify-key"),
            openrouter_model_id="quality-model",
            _env_file=None,
        ),
        usage=None,
    )

    assert isinstance(built, TargetedRecipeVerifier)
    assert built._model_id == "quality-model"


def test_recipe_verifier_runtime_builder_respects_explicit_disable() -> None:
    from ladle.worker.runtime import _recipe_verifier

    assert (
        _recipe_verifier(
            Settings(recipe_verification_enabled=False, _env_file=None),
            usage=None,
        )
        is None
    )


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class RecordingMetrics:
    values: list[tuple[str, float]] = field(default_factory=list)

    def set_operational(self, name: str, value: float) -> None:
        self.values.append((name, value))


def test_worker_uses_late_ack_and_long_visibility_timeout() -> None:
    app = create_celery_app(
        Settings(
            celery_broker_url="redis://127.0.0.1:6379/0",
            celery_result_backend="redis://127.0.0.1:6379/1",
            celery_visibility_timeout_seconds=1800,
            celery_task_soft_time_limit_seconds=1200,
            celery_task_time_limit_seconds=1260,
        )
    )

    assert app.conf.task_acks_late is True
    assert app.conf.task_reject_on_worker_lost is True
    assert app.conf.broker_transport_options["visibility_timeout"] == 1800
    assert app.conf.task_soft_time_limit == 1200
    assert app.conf.task_time_limit == 1260
    assert app.conf.worker_prefetch_multiplier == 1
    assert app.conf.broker_connection_retry_on_startup is True
    assert app.conf.task_default_delivery_mode == "persistent"
    assert app.conf.task_annotations[PROCESS_IMPORT_TASK] == {
        "max_retries": 3,
    }
    assert app.conf.task_serializer == "json"
    assert app.conf.accept_content == ["json"]


def test_live_runtime_constructs_no_visual_provider_or_thumbnail_observer() -> None:
    runtime = ast.parse((BACKEND / "ladle/worker/runtime.py").read_text())
    calls = [node for node in ast.walk(runtime) if isinstance(node, ast.Call)]

    assert not any(
        isinstance(call.func, ast.Name)
        and call.func.id in {"VisionObserver", "VisionVisualProvider", "FrameSampler"}
        for call in calls
    )
    for call in calls:
        if isinstance(call.func, ast.Name) and call.func.id == "ProviderChain":
            assert "vision" not in {keyword.arg for keyword in call.keywords}
        if isinstance(call.func, ast.Name) and call.func.id == "ImportOrchestrator":
            assert "thumbnail_observer" not in {
                keyword.arg for keyword in call.keywords
            }


def test_worker_retry_backoff_is_bounded_and_jittered() -> None:
    first = retry_countdown(
        retry_number=1,
        base_seconds=5,
        maximum_seconds=60,
        jitter_seconds=3,
        jitter=lambda upper: upper,
    )
    late = retry_countdown(
        retry_number=10,
        base_seconds=5,
        maximum_seconds=60,
        jitter_seconds=3,
        jitter=lambda upper: upper,
    )

    assert first == 8
    assert late == 63


def test_worker_retries_only_explicit_transient_failures() -> None:
    retryable = (
        TimeoutError(),
        ConnectionError(),
        RedisConnectionError(),
        SQLAlchemyTimeoutError(),
        SoftTimeLimitExceeded(),
        ProviderTransientError(),
        ClaimLost(),
    )
    terminal = (
        ValueError("malformed job"),
        RuntimeError("broken invariant"),
    )

    assert all(is_retryable_import_failure(error) for error in retryable)
    assert not any(is_retryable_import_failure(error) for error in terminal)


def test_production_worker_installs_sink_boundary_json_logging(
    monkeypatch,
) -> None:
    settings = Settings(_env_file=None)
    settings.environment = "production"
    settings.log_level = "WARNING"
    configured: list[str] = []
    monkeypatch.setattr(
        "ladle.worker.app.configure_structured_logging",
        lambda *, level: configured.append(level),
    )

    configure_worker_logging(settings=settings)

    assert configured == ["WARNING"]


def test_celery_heartbeat_updates_idle_worker_liveness() -> None:
    now = datetime(2026, 7, 26, 20, 0, tzinfo=UTC)
    metrics = RecordingMetrics()

    record_worker_heartbeat(
        metrics=metrics,  # type: ignore[arg-type]
        clock=FrozenClock(now),
    )

    assert metrics.values == [
        ("ladle_worker_last_seen_timestamp_seconds", now.timestamp())
    ]


def test_abandoned_imports_are_swept_on_a_schedule() -> None:
    """The sweep only reclaims stranded jobs if something actually runs it."""

    app = create_celery_app(Settings(import_maintenance_interval_seconds=120))

    entry = app.conf.beat_schedule["release-expired-reservations"]
    assert entry["task"] == RELEASE_EXPIRED_RESERVATIONS_TASK
    assert entry["schedule"] == 120.0
    # A backlog of sweeps is redundant: the next one sees everything the
    # expired ones would have.
    assert entry["options"]["expires"] == 120


def test_sweep_task_is_registered_on_the_worker() -> None:
    # Imported for its registration side effect, which is the thing at risk:
    # a scheduled task the worker never registered is silently never run.
    import ladle.worker.tasks  # noqa: F401

    assert RELEASE_EXPIRED_RESERVATIONS_TASK in celery_app.tasks


def test_privacy_retention_and_object_cleanup_run_on_a_schedule() -> None:
    app = create_celery_app(Settings(retention_maintenance_interval_seconds=7200))

    entry = app.conf.beat_schedule["privacy-retention-sweep"]
    assert entry["task"] == RETENTION_SWEEP_TASK
    assert entry["schedule"] == 7200.0
    assert entry["options"]["expires"] == 7200

    import ladle.worker.tasks  # noqa: F401

    assert RETENTION_SWEEP_TASK in celery_app.tasks


def test_the_worker_connects_its_log_formatter_outside_production() -> None:
    """The gate that kept the redacting formatter off the deployed worker.

    `configure_worker_logging` itself was fixed to follow the setting, but the
    signal that calls it was still connected only when environment ==
    "production". The VPS runs the documented development exception, so worker
    output never went through sink-boundary redaction at all.
    """

    import importlib

    from celery.signals import setup_logging

    import ladle.worker.app as worker_app

    # The suite runs with the default environment, which is "development" —
    # exactly the case the old gate excluded.
    assert worker_app._worker_settings.environment != "production"
    importlib.reload(worker_app)

    assert setup_logging.has_listeners(), (
        "setup_logging must have a receiver, or worker output never reaches "
        "the redacting formatter"
    )


def test_the_heartbeat_also_leaves_a_file_the_health_check_can_stat(
    tmp_path,
) -> None:
    # An 11-second `celery inspect ping` was being spent to learn what this
    # file answers in microseconds.
    from ladle.worker.app import record_worker_heartbeat

    beacon = tmp_path / "worker-heartbeat"
    metrics = RecordingMetrics()

    record_worker_heartbeat(metrics=metrics, beacon=beacon)

    assert beacon.exists()


def test_a_missing_beacon_directory_never_kills_the_worker(tmp_path) -> None:
    # Liveness bookkeeping must not be able to take down the process it
    # reports on, so an unwritable path is swallowed.
    from ladle.worker.app import record_worker_heartbeat

    metrics = RecordingMetrics()
    record_worker_heartbeat(
        metrics=metrics, beacon=tmp_path / "no" / "such" / "dir" / "f"
    )

    assert metrics.values, "the gauge must still be written"
