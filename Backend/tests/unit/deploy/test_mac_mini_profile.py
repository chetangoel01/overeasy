from pathlib import Path

BACKEND = Path(__file__).parents[3]


def test_mac_mini_profile_is_private_and_carries_no_default_credentials() -> None:
    profile = (BACKEND / "deploy" / "mac-mini" / "docker-compose.yml").read_text()

    # Nothing is published beyond loopback, and the base file's ports are reset.
    assert "127.0.0.1:4112:8080" in profile
    assert "127.0.0.1:4113:8081" in profile
    assert "127.0.0.1:4114:8082" in profile
    assert "ports: !reset []" in profile
    # The worker has no network of its own: it leaves through the egress gate.
    assert "network_mode: service:worker-egress" in profile
    assert "privileged: true" not in profile
    # Rate limits key on the client address, so the one trusted proxy is pinned.
    assert 'LADLE_RATE_LIMITING_ENABLED: "true"' in profile
    assert "LADLE_RATE_LIMIT_TRUSTED_PROXY_CIDRS: 172.30.0.2/32" in profile
    # Storage credentials come from deploy.sh or the stack does not start.
    for variable in (
        "LADLE_OBJECT_STORAGE_ACCESS_KEY",
        "LADLE_OBJECT_STORAGE_SECRET_KEY",
    ):
        assert f"{variable}: ${{{variable}:?set by deploy.sh}}" in profile
    assert (
        "MINIO_ROOT_USER: ${LADLE_OBJECT_STORAGE_ACCESS_KEY:?set by deploy.sh}"
    ) in profile
    assert (
        "MINIO_ROOT_PASSWORD: ${LADLE_OBJECT_STORAGE_SECRET_KEY:?set by deploy.sh}"
    ) in profile


def test_mac_mini_edge_hides_diagnostics_limits_bodies_and_keeps_the_client_ip() -> (
    None
):
    dockerfile = (BACKEND / "deploy" / "mac-mini" / "edge.Dockerfile").read_text()
    config = (BACKEND / "deploy" / "mac-mini" / "nginx.conf").read_text()

    assert "@sha256:" in dockerfile
    # The rate limiter sees the real client, never a header the client chose.
    assert "listen 8080 proxy_protocol" in config
    assert "real_ip_header proxy_protocol" in config
    assert "proxy_set_header X-Forwarded-For $remote_addr" in config
    # The tunnel key stops at the edge instead of reaching application logs.
    assert 'proxy_set_header X-Ladle-Tunnel-Key ""' in config
    assert (
        'add_header Strict-Transport-Security "max-age=63072000; '
        'includeSubDomains; preload" always;'
    ) in config
    # Both public listeners hide the diagnostics, not just the first.
    for hidden in ("/openapi.json", "/docs", "/redoc", "/metrics"):
        assert config.count(f"location = {hidden}") == 2
    assert "client_max_body_size 1m" in config
    assert "error_page 413" in config
    assert '"code":"invalidRequest"' in config


def test_mac_mini_worker_egress_allows_dependencies_and_public_https_only() -> None:
    dockerfile = (BACKEND / "deploy" / "mac-mini" / "egress.Dockerfile").read_text()
    policy = (BACKEND / "deploy" / "mac-mini" / "worker-egress.sh").read_text()

    assert "@sha256:" in dockerfile
    assert "iptables=" in dockerfile
    assert "postgres_ip=" in policy
    assert "redis_ip=" in policy
    assert "minio_ip=" in policy
    assert "--dport 5432" in policy
    assert "--dport 6379" in policy
    assert "--dport 9000" in policy
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
