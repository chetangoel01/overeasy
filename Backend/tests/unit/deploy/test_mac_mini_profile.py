from pathlib import Path

BACKEND = Path(__file__).parents[3]


def test_mac_mini_profile_is_private_bounded_and_hosts_thumbnails() -> None:
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
    assert profile.count("restart: unless-stopped") == 8
    assert 'LADLE_RATE_LIMITING_ENABLED: "true"' in profile
    assert "LADLE_RATE_LIMIT_REDIS_URL: redis://redis:6379/2" in profile
    assert 'LADLE_DURABLE_METRICS_ENABLED: "true"' in profile
    assert 'LADLE_OBJECT_STORAGE_ENABLED: "true"' in profile
    assert "LADLE_OBJECT_STORAGE_ENDPOINT_URL: http://minio:9000" in profile
    assert (
        "LADLE_OBJECT_STORAGE_PUBLIC_ENDPOINT_URL: "
        "${LADLE_OBJECT_STORAGE_PUBLIC_ENDPOINT_URL:?set by deploy.sh}"
    ) in profile
    assert "LADLE_OBJECT_STORAGE_ADDRESSING_STYLE: path" in profile
    assert (
        "LADLE_OBJECT_STORAGE_ACCESS_KEY: "
        "${LADLE_OBJECT_STORAGE_ACCESS_KEY:?set by deploy.sh}"
    ) in profile
    assert (
        "LADLE_OBJECT_STORAGE_SECRET_KEY: "
        "${LADLE_OBJECT_STORAGE_SECRET_KEY:?set by deploy.sh}"
    ) in profile
    assert 'LADLE_AUDIO_TRANSCRIPTION_ENABLED: "false"' in profile
    assert 'LADLE_FRAME_ANALYSIS_ENABLED: "false"' in profile
    assert 'LADLE_SERVER_MEDIA_FALLBACK_ENABLED: "false"' in profile
    assert "max-size: 10m" in profile
    assert "max-file: 3" in profile
    assert 'profiles: ["object-storage-disabled"]' not in profile
    assert 'command: ["/bin/true"]' not in profile
    assert "depends_on: !reset {}" not in profile
    assert (
        "MINIO_ROOT_USER: "
        "${LADLE_OBJECT_STORAGE_ACCESS_KEY:?set by deploy.sh}"
    ) in profile
    assert (
        "MINIO_ROOT_PASSWORD: "
        "${LADLE_OBJECT_STORAGE_SECRET_KEY:?set by deploy.sh}"
    ) in profile
    assert "127.0.0.1:4112:8080" in profile
    assert "127.0.0.1:4113:8081" in profile
    assert "127.0.0.1:4114:8082" in profile
    assert profile.count("host-publish: {}") == 2
    assert profile.count("internal: true") == 1
    assert "ports: !reset []" in profile
    assert "LADLE_RATE_LIMIT_TRUSTED_PROXY_CIDRS: 172.30.0.2/32" in profile
    assert "network_mode: service:worker-egress" in profile
    assert profile.count("volumes: !reset []") == 2
    assert (
        "LADLE_OBJECT_STORAGE_LIFECYCLE_PATH: "
        "/app/deploy/object-storage-lifecycle.json"
    ) in profile
    assert "MINIO_HOST: minio" in profile
    assert "NET_ADMIN" in profile
    assert "privileged: true" not in profile


def test_mac_mini_edge_enforces_body_limit_and_preserves_proxy_protocol_ip() -> None:
    dockerfile = (BACKEND / "deploy" / "mac-mini" / "edge.Dockerfile").read_text()
    config = (BACKEND / "deploy" / "mac-mini" / "nginx.conf").read_text()

    assert "@sha256:" in dockerfile
    assert "COPY --chown=101:101 --chmod=0444 nginx.conf" in dockerfile
    assert "listen 8080 proxy_protocol" in config
    assert "listen 8081" in config
    assert "listen 8082" in config
    assert "real_ip_header proxy_protocol" in config
    assert "proxy_set_header X-Forwarded-For $remote_addr" in config
    assert config.count("proxy_set_header X-Forwarded-Proto https") == 2
    assert 'proxy_set_header X-Ladle-Tunnel-Key ""' in config
    assert 'proxy_set_header ngrok-skip-browser-warning ""' in config
    assert (
        'add_header Strict-Transport-Security "max-age=63072000; '
        'includeSubDomains; preload" always;'
    ) in config
    for hidden in ("/openapi.json", "/docs", "/redoc", "/metrics"):
        assert config.count(f"location = {hidden}") == 2
    assert "client_max_body_size 1m" in config
    assert "error_page 413" in config
    assert '"code":"invalidRequest"' in config
    assert "server api:4111" in config
    assert "proxy_pass http://ladle_api" in config
    assert "upstream ladle_thumbnails" in config
    assert "location /ladle-private/" in config
    assert "proxy_pass http://ladle_thumbnails" in config
    assert "proxy_set_header Host $host" in config


def test_mac_mini_ngrok_launcher_requires_a_device_key() -> None:
    script = (BACKEND / "deploy" / "mac-mini" / "ngrok.sh").read_text()

    assert "openssl rand -hex 32" in script
    assert "chmod 600" in script
    assert "X-Ladle-Tunnel-Key" in script
    assert "x-ladle-tunnel-key" in script
    assert "--traffic-policy-file" in script
    assert "http://127.0.0.1:4114" in script
    assert "public_url" in script
    assert "req.url.path.startsWith('/ladle-private/')" in script
    assert "cat \"$access_key_file\"" not in script


def test_mac_mini_worker_egress_allows_dependencies_and_public_https_only() -> None:
    dockerfile = (BACKEND / "deploy" / "mac-mini" / "egress.Dockerfile").read_text()
    policy = (BACKEND / "deploy" / "mac-mini" / "worker-egress.sh").read_text()

    assert "@sha256:" in dockerfile
    assert "iptables=1.8.13-r0" in dockerfile
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


def test_mac_mini_deploy_script_generates_secrets_and_runs_migrations() -> None:
    script = (BACKEND / "deploy" / "mac-mini" / "deploy.sh").read_text()

    assert "umask 077" in script
    assert "openssl rand -hex 32" in script
    assert "LADLE_JWT_SIGNING_SECRET" in script
    assert "LADLE_DATA_ENCRYPTION_KEY" in script
    assert "LADLE_METRICS_AUTH_TOKEN" in script
    assert "LADLE_OBJECT_STORAGE_ACCESS_KEY" in script
    assert "LADLE_OBJECT_STORAGE_SECRET_KEY" in script
    assert "LADLE_OBJECT_STORAGE_PUBLIC_ENDPOINT_URL" in script
    assert "LADLE_INSTALL_MEDIA_TOOLS false" in script
    assert "compose stop minio" not in script
    assert "compose up -d postgres redis minio" in script
    assert "compose run --rm minio-init" in script
    assert "backfill-thumbnails" in script
    assert 'PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.orbstack/bin:$PATH"' in script
    assert "docker-compose.yml" in script
    assert "deploy/mac-mini/docker-compose.yml" in script
    assert "LADLE_MAC_MINI_DOCKER_CONTEXT" in script
    assert '--context "$LADLE_MAC_MINI_DOCKER_CONTEXT"' in script
    assert "migrate" in script
    assert "health/ready" in script
    assert '"$tailscale_bin" serve reset' in script
    assert "--proxy-protocol=2" in script
    assert "--tls-terminated-tcp=443" in script


def test_mac_mini_autostart_installer_starts_docker_at_login() -> None:
    installer = (BACKEND / "deploy" / "mac-mini" / "install-autostart.sh").read_text()
    launch_agent = (
        BACKEND / "deploy" / "mac-mini" / "com.ladle.docker-start.plist"
    ).read_text()

    assert "install -m 600" in installer
    assert "launchctl bootstrap" in installer
    assert "launchctl enable" in installer
    assert "<key>RunAtLoad</key>" in launch_agent
    assert "/Applications/Docker.app" in launch_agent


def test_mac_mini_local_operations_schedule_validated_backups_and_health() -> None:
    operations = (
        BACKEND / "deploy" / "mac-mini" / "local-operations.sh"
    ).read_text()
    installer = (
        BACKEND / "deploy" / "mac-mini" / "install-local-operations.sh"
    ).read_text()
    health_agent = (
        BACKEND / "deploy" / "mac-mini" / "com.ladle.health-watch.plist"
    ).read_text()
    backup_agent = (
        BACKEND / "deploy" / "mac-mini" / "com.ladle.database-backup.plist"
    ).read_text()

    assert "pg_dump -Fc" in operations
    assert "pg_restore --list" in operations
    assert "shasum -a 256" in operations
    assert "LADLE_BACKUP_RETENTION_DAYS" in operations
    assert "health/ready" in operations
    assert "LADLE_MINIMUM_FREE_DISK_GIB" in operations
    assert "docker_cli inspect" in operations
    assert "display notification" in operations
    assert "install -m 700" in installer
    assert "launchctl bootstrap" in installer
    assert "<integer>300</integer>" in health_agent
    assert "<key>StartCalendarInterval</key>" in backup_agent
