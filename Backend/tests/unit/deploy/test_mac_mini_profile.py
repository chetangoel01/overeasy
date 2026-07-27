from pathlib import Path

BACKEND = Path(__file__).parents[3]


def test_mac_mini_profile_is_private_bounded_and_non_media() -> None:
    profile = (BACKEND / "deploy" / "mac-mini" / "docker-compose.yml").read_text()

    for service in ("postgres", "redis", "minio", "api", "worker", "beat"):
        assert f"  {service}:" in profile
    assert profile.count("restart: unless-stopped") == 6
    assert 'LADLE_RATE_LIMITING_ENABLED: "true"' in profile
    assert 'LADLE_DURABLE_METRICS_ENABLED: "true"' in profile
    assert 'LADLE_AUDIO_TRANSCRIPTION_ENABLED: "false"' in profile
    assert 'LADLE_FRAME_ANALYSIS_ENABLED: "false"' in profile
    assert 'LADLE_SERVER_MEDIA_FALLBACK_ENABLED: "false"' in profile
    assert "max-size: 10m" in profile
    assert "max-file: 3" in profile
    assert "ports:" not in profile


def test_mac_mini_deploy_script_generates_secrets_and_runs_migrations() -> None:
    script = (BACKEND / "deploy" / "mac-mini" / "deploy.sh").read_text()

    assert "umask 077" in script
    assert "openssl rand -hex 32" in script
    assert "LADLE_JWT_SIGNING_SECRET" in script
    assert "LADLE_DATA_ENCRYPTION_KEY" in script
    assert "LADLE_METRICS_AUTH_TOKEN" in script
    assert "LADLE_INSTALL_MEDIA_TOOLS false" in script
    assert 'PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.orbstack/bin:$PATH"' in script
    assert "docker-compose.yml" in script
    assert "deploy/mac-mini/docker-compose.yml" in script
    assert "migrate" in script
    assert "health/ready" in script
