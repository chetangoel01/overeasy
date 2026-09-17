from pathlib import Path

BACKEND = Path(__file__).parents[3]


def test_alert_policy_covers_required_failures_and_never_seen_processes() -> None:
    rules = (BACKEND / "deploy" / "observability" / "prometheus-rules.yaml").read_text()

    for alert in (
        "LadleElevatedAPI5xx",
        "LadleElevatedRateLimiting",
        "LadleQueueBacklog",
        "LadleJobsStuckParsing",
        "LadleWorkerAbsent",
        "LadleBeatAbsent",
        "LadleClaimChurn",
        "LadleProviderAuthenticationFailure",
        "LadleProviderQuotaFailure",
        "LadleProviderSpendWarning",
        "LadleDependencyUnavailable",
        "LadleMigrationMismatch",
    ):
        assert f"alert: {alert}" in rules
    assert "absent(ladle_worker_last_seen_timestamp_seconds)" in rules
    assert "absent(ladle_beat_last_seen_timestamp_seconds)" in rules
