from pathlib import Path

BACKEND = Path(__file__).parents[3]


def test_mac_mini_profile_is_private_bounded_and_non_media() -> None:
    profile = (BACKEND / "deploy" / "mac-mini" / "docker-compose.yml").read_text()

    for service in (
        "postgres",
        "redis",
        "minio",
        "minio-init",
        "edge",
        "api",
        "worker-egress",
        "worker",
        "beat",
    ):
        assert f"  {service}:" in profile
    assert profile.count("restart: unless-stopped") == 7
    assert 'LADLE_RATE_LIMITING_ENABLED: "true"' in profile
    assert "LADLE_RATE_LIMIT_REDIS_URL: redis://redis:6379/2" in profile
    assert 'LADLE_DURABLE_METRICS_ENABLED: "true"' in profile
    assert 'LADLE_OBJECT_STORAGE_ENABLED: "false"' in profile
    assert 'LADLE_AUDIO_TRANSCRIPTION_ENABLED: "false"' in profile
    assert 'LADLE_FRAME_ANALYSIS_ENABLED: "false"' in profile
    assert 'LADLE_SERVER_MEDIA_FALLBACK_ENABLED: "false"' in profile
    assert "max-size: 10m" in profile
    assert "max-file: 3" in profile
    assert 'profiles: ["object-storage-disabled"]' in profile
    assert 'command: ["/bin/true"]' in profile
    assert "depends_on: !reset {}" in profile
    assert "127.0.0.1:4112:8080" in profile
    assert "127.0.0.1:4113:8081" in profile
    assert "ports: !reset []" in profile
    assert "LADLE_RATE_LIMIT_TRUSTED_PROXY_CIDRS: 172.30.0.2/32" in profile
    assert "network_mode: service:worker-egress" in profile
    assert "NET_ADMIN" in profile
    assert "privileged: true" not in profile


def test_mac_mini_edge_enforces_body_limit_and_preserves_proxy_protocol_ip() -> None:
    config = (BACKEND / "deploy" / "mac-mini" / "nginx.conf").read_text()

    assert "listen 8080 proxy_protocol" in config
    assert "listen 8081" in config
    assert "real_ip_header proxy_protocol" in config
    assert "proxy_set_header X-Forwarded-For $remote_addr" in config
    assert "client_max_body_size 1m" in config
    assert "error_page 413" in config
    assert '"code":"invalidRequest"' in config
    assert "server api:4111" in config
    assert "proxy_pass http://ladle_api" in config


def test_mac_mini_worker_egress_allows_dependencies_and_public_https_only() -> None:
    dockerfile = (BACKEND / "deploy" / "mac-mini" / "egress.Dockerfile").read_text()
    policy = (BACKEND / "deploy" / "mac-mini" / "worker-egress.sh").read_text()

    assert "@sha256:" in dockerfile
    assert "iptables=1.8.13-r0" in dockerfile
    assert "postgres_ip=" in policy
    assert "redis_ip=" in policy
    assert "--dport 5432" in policy
    assert "--dport 6379" in policy
    assert "--dport 443" in policy
    for blocked in (
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
    ):
        assert blocked in policy
    assert "ip6tables" in policy
    assert "WORKER_UID:-10001" in policy
    assert '--uid-owner "$worker_uid"' in policy
    assert "REJECT" in policy


def test_mac_mini_deploy_script_generates_secrets_and_runs_migrations() -> None:
    script = (BACKEND / "deploy" / "mac-mini" / "deploy.sh").read_text()

    assert "umask 077" in script
    assert "openssl rand -hex 32" in script
    assert "LADLE_JWT_SIGNING_SECRET" in script
    assert "LADLE_DATA_ENCRYPTION_KEY" in script
    assert "LADLE_METRICS_AUTH_TOKEN" in script
    assert "LADLE_INSTALL_MEDIA_TOOLS false" in script
    assert "compose stop minio" in script
    assert 'PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.orbstack/bin:$PATH"' in script
    assert "docker-compose.yml" in script
    assert "deploy/mac-mini/docker-compose.yml" in script
    assert "migrate" in script
    assert "health/ready" in script
    assert "--proxy-protocol=2" in script
    assert "--tls-terminated-tcp=443" in script


def test_ci_scans_and_retains_sboms_for_mac_infrastructure_images() -> None:
    workflow = (BACKEND.parent / ".github" / "workflows" / "backend-ci.yml").read_text()

    assert "Build Mac worker egress gateway" in workflow
    assert "Load pinned Mac ingress edge" in workflow
    assert "Scan Mac worker egress gateway" in workflow
    assert "Scan Mac ingress edge" in workflow
    assert "Generate Mac worker egress SBOM" in workflow
    assert "Generate Mac ingress edge SBOM" in workflow
    assert "ladle-mac-infrastructure-sboms" in workflow
