import pytest

from ladle.observability.metrics import MetricsRegistry


def test_product_metrics_use_only_bounded_labels_and_render_prometheus_text() -> None:
    metrics = MetricsRegistry()

    metrics.record_cache("hit")
    metrics.record_cache("follower")
    metrics.record_provider("supadata", "success")
    metrics.record_provider("soscripted", "fallback")
    metrics.record_job("ready", "youtube")
    metrics.record_sync("success")

    rendered = metrics.render()
    assert 'ladle_cache_total{disposition="hit"} 1' in rendered
    assert 'ladle_cache_total{disposition="follower"} 1' in rendered
    assert 'ladle_provider_total{outcome="success",provider="supadata"} 1' in rendered
    assert 'ladle_import_jobs_total{source="youtube",status="ready"} 1' in rendered
    assert 'ladle_sync_total{outcome="success"} 1' in rendered
    assert "user" not in rendered


@pytest.mark.parametrize(
    ("method", "values"),
    [
        ("record_cache", ("user-controlled-value",)),
        ("record_provider", ("unknown-provider", "success")),
        ("record_job", ("ready", "user-123")),
        ("record_sync", ("user-123",)),
    ],
)
def test_metrics_reject_unbounded_label_values(
    method: str,
    values: tuple[str, ...],
) -> None:
    metrics = MetricsRegistry()

    with pytest.raises(ValueError):
        getattr(metrics, method)(*values)
