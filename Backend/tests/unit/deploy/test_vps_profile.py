import re
import stat
from pathlib import Path
from typing import Any

import yaml

BACKEND = Path(__file__).parents[3]
PROFILE = BACKEND / "deploy" / "vps" / "docker-compose.yml"
CADDYFILE = PROFILE.parent / "Caddyfile"
PROVISION = PROFILE.parent / "provision.sh"
HARDEN_SSH = PROFILE.parent / "harden-ssh.sh"
DOCKER_USER_RULES = PROFILE.parent / "ladle-docker-user.rules"

EXPECTED_SERVICES = {
    "postgres",
    "redis",
    "minio",
    "minio-init",
    "caddy",
    "edge",
    "migrate",
    "api",
    "worker-egress",
    "worker",
    "beat",
}


class ComposeLoader(yaml.SafeLoader):
    pass


def _construct_reset(
    loader: ComposeLoader, node: yaml.nodes.Node
) -> list[object] | dict[str, object] | str:
    if isinstance(node, yaml.nodes.SequenceNode):
        return loader.construct_sequence(node)
    if isinstance(node, yaml.nodes.MappingNode):
        return loader.construct_mapping(node)
    return loader.construct_scalar(node)


ComposeLoader.add_constructor("!reset", _construct_reset)


def _profile() -> dict[str, Any]:
    loaded = yaml.load(PROFILE.read_text(), Loader=ComposeLoader)
    assert isinstance(loaded, dict)
    return loaded


def _memory_mib(limit: str) -> int:
    match = re.fullmatch(r"(\d+)([gm])", limit)
    assert match is not None
    value, unit = match.groups()
    return int(value) * (1024 if unit == "g" else 1)


def _heredoc(text: str, marker: str) -> str:
    openers = (f"<<'{marker}'\n", f"<<{marker}\n")
    opener = next((candidate for candidate in openers if candidate in text), None)
    assert opener is not None
    body = text.split(opener, maxsplit=1)[1]
    return body.split(f"\n{marker}", maxsplit=1)[0]


def test_vps_profile_files_exist() -> None:
    assert PROFILE.is_file()
    assert CADDYFILE.is_file()


def test_vps_profile_exposes_only_the_guarded_tls_edge() -> None:
    profile_text = PROFILE.read_text()
    services = _profile()["services"]

    assert set(services) == EXPECTED_SERVICES
    assert services["caddy"]["ports"] == [
        "80:80",
        "443:443",
        "443:443/udp",
    ]
    for name, service in services.items():
        if name != "caddy":
            assert service.get("ports", []) == [], name
    for name in ("api", "minio", "edge"):
        assert services[name]["ports"] == []
    assert profile_text.count("ports: !reset []") >= 3


def test_caddy_requires_the_key_except_for_signed_object_paths() -> None:
    caddy = CADDYFILE.read_text()

    assert "api.ladle.app" not in caddy
    assert "{$LADLE_PUBLIC_HOSTNAME}" in caddy
    assert "@private path /ladle-private/*" in caddy
    assert ("@authorized header X-Ladle-Tunnel-Key {$LADLE_TUNNEL_ACCESS_KEY}") in caddy
    assert "reverse_proxy @private edge:8082" in caddy
    assert "reverse_proxy @authorized edge:8082" in caddy
    assert "respond 404" in caddy
    assert caddy.index("@private path") < caddy.index("@authorized header")
    assert caddy.index("@authorized header") < caddy.index("respond 404")
    assert caddy.count("header_up Host {http.request.host}") == 2
    assert "X-Forwarded-For and X-Forwarded-Proto" in caddy


def test_vps_profile_uses_pinned_reusable_edge_images() -> None:
    services = _profile()["services"]
    caddy_image = services["caddy"]["image"]

    assert re.fullmatch(r"caddy:[^@]+@sha256:[0-9a-f]{64}", caddy_image)
    assert services["edge"]["build"] == {
        "context": "./deploy/mac-mini",
        "dockerfile": "edge.Dockerfile",
    }
    assert services["worker-egress"]["build"] == {
        "context": "./deploy/mac-mini",
        "dockerfile": "egress.Dockerfile",
    }
    assert not (PROFILE.parent / "edge.Dockerfile").exists()
    assert not (PROFILE.parent / "nginx.conf").exists()
    assert not (PROFILE.parent / "egress.Dockerfile").exists()
    assert not (PROFILE.parent / "worker-egress.sh").exists()


def test_vps_profile_keeps_state_private_and_bounded() -> None:
    profile_text = PROFILE.read_text()
    profile = _profile()
    services = profile["services"]

    environment = services["api"]["environment"]
    assert environment["LADLE_ENVIRONMENT"] == "development"
    assert environment["LADLE_OBJECT_STORAGE_ENABLED"] == "true"
    assert environment["LADLE_OBJECT_STORAGE_ENDPOINT_URL"] == "http://minio:9000"
    assert environment["LADLE_OBJECT_STORAGE_PUBLIC_ENDPOINT_URL"] == (
        "https://${LADLE_PUBLIC_HOSTNAME}"
    )
    assert environment["LADLE_OBJECT_STORAGE_ADDRESSING_STYLE"] == "path"
    assert environment["LADLE_AUDIO_TRANSCRIPTION_ENABLED"] == "false"
    assert environment["LADLE_FRAME_ANALYSIS_ENABLED"] == "false"
    assert environment["LADLE_SERVER_MEDIA_FALLBACK_ENABLED"] == "false"
    assert environment["LADLE_RATE_LIMIT_TRUSTED_PROXY_CIDRS"] == ("172.31.0.3/32")

    assert services["worker"]["network_mode"] == "service:worker-egress"
    assert services["worker"]["volumes"] == []
    assert services["worker-egress"]["cap_add"] == ["NET_ADMIN"]
    for name, service in services.items():
        assert service.get("privileged") is not True, name
        if name != "worker-egress":
            assert "NET_ADMIN" not in service.get("cap_add", []), name
        assert service["logging"] == {
            "driver": "json-file",
            "options": {"max-size": "10m", "max-file": 3},
        }
        assert service["pids_limit"] > 0
        assert service["mem_limit"]
        assert service["cpus"] > 0
    assert (
        sum(_memory_mib(service["mem_limit"]) for service in services.values())
        <= 7 * 1024
    )
    for name in ("postgres", "redis", "minio", "caddy", "edge", "worker-egress"):
        assert services[name]["read_only"] is True
        assert "ALL" in services[name]["cap_drop"]
        assert "no-new-privileges:true" in services[name]["security_opt"]

    assert "privileged: true" not in profile_text
    assert "read_only: true" in profile_text
    assert "max-size: 10m" in profile_text
    assert "max-file: 3" in profile_text


def test_vps_profile_separates_raw_and_url_encoded_database_passwords() -> None:
    services = _profile()["services"]
    raw_password = services["postgres"]["environment"]["POSTGRES_PASSWORD"]
    database_url = services["api"]["environment"]["LADLE_DATABASE_URL"]

    assert raw_password == ("${LADLE_DATABASE_PASSWORD:?set LADLE_DATABASE_PASSWORD}")
    assert (
        "${LADLE_DATABASE_PASSWORD_URL_ENCODED:?"
        "set LADLE_DATABASE_PASSWORD_URL_ENCODED}"
    ) in database_url
    assert "${LADLE_DATABASE_PASSWORD:?" not in database_url


def test_vps_profile_bounds_redis_below_its_container_limit() -> None:
    redis = _profile()["services"]["redis"]

    assert redis["command"] == [
        "redis-server",
        "--appendonly",
        "yes",
        "--appendfsync",
        "everysec",
        "--save",
        "60",
        "1",
        "--maxmemory",
        "192mb",
        "--maxmemory-policy",
        "noeviction",
        "--stop-writes-on-bgsave-error",
        "yes",
    ]
    assert _memory_mib(redis["mem_limit"]) == 384


def test_vps_profile_omits_media_tools_from_python_images() -> None:
    services = _profile()["services"]
    root_build = {
        "context": ".",
        "args": {"INSTALL_MEDIA_TOOLS": "false"},
    }

    for name in ("minio-init", "migrate", "api", "worker", "beat"):
        assert services[name]["build"] == root_build


def test_vps_profile_uses_named_state_and_a_fixed_internal_edge() -> None:
    profile = _profile()
    services = profile["services"]

    assert set(profile["volumes"]) == {
        "ladle-postgres",
        "ladle-redis",
        "ladle-minio",
        "ladle-caddy-data",
        "ladle-caddy-config",
    }
    assert services["postgres"]["volumes"] == [
        "ladle-postgres:/var/lib/postgresql/data"
    ]
    assert services["redis"]["volumes"] == ["ladle-redis:/data"]
    assert services["minio"]["volumes"] == ["ladle-minio:/data"]
    assert services["caddy"]["volumes"] == [
        "./deploy/vps/Caddyfile:/etc/caddy/Caddyfile:ro",
        "ladle-caddy-data:/data",
        "ladle-caddy-config:/config",
    ]

    edge = profile["networks"]["edge"]
    assert edge["internal"] is True
    assert edge["ipam"]["config"] == [{"subnet": "172.31.0.0/24"}]
    expected_addresses = {
        "caddy": "172.31.0.2",
        "edge": "172.31.0.3",
        "api": "172.31.0.4",
        "minio": "172.31.0.5",
    }
    for name, address in expected_addresses.items():
        assert services[name]["networks"]["edge"]["ipv4_address"] == address


def test_vps_profile_requires_secrets_without_embedding_them() -> None:
    profile = PROFILE.read_text()

    for variable in (
        "LADLE_PUBLIC_HOSTNAME",
        "LADLE_TUNNEL_ACCESS_KEY",
        "LADLE_DATABASE_PASSWORD",
        "LADLE_DATABASE_PASSWORD_URL_ENCODED",
        "LADLE_JWT_SIGNING_SECRET",
        "LADLE_DATA_ENCRYPTION_KEY",
        "LADLE_METRICS_AUTH_TOKEN",
        "LADLE_OBJECT_STORAGE_ACCESS_KEY",
        "LADLE_OBJECT_STORAGE_SECRET_KEY",
    ):
        assert f"${{{variable}:?" in profile
    for insecure_default in (
        "change-me-development-only-signing-secret",
        "change-me-development-only",
        "local-metrics-token-not-for-production",
        "ladle-local-secret",
    ):
        assert insecure_default not in profile


def test_docker_context_includes_only_vps_runtime_assets() -> None:
    dockerignore = (BACKEND / ".dockerignore").read_text()

    assert "!deploy/vps/" in dockerignore
    assert "!deploy/vps/docker-compose.yml" in dockerignore
    assert "!deploy/vps/Caddyfile" in dockerignore
    assert dockerignore.index("docker-compose*") < dockerignore.index(
        "!deploy/vps/docker-compose.yml"
    )


def test_vps_provisioning_uses_the_signed_official_docker_repository() -> None:
    provision = PROVISION.read_text()

    assert provision.startswith("#!/bin/sh\nset -eu\numask 077\n")
    assert ". /etc/os-release" in provision
    assert '"${ID:-}" != "ubuntu"' in provision
    assert '"${VERSION_ID:-}" != "26.04"' in provision
    assert "https://download.docker.com/linux/ubuntu/gpg" in provision
    assert "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" in provision
    assert "/etc/apt/keyrings/docker.gpg" in provision
    assert "/etc/apt/sources.list.d/docker.sources" in provision
    for field in ("Types: deb", "URIs:", "Suites:", "Architectures:", "Signed-By:"):
        assert field in provision
    for package in (
        "docker-ce",
        "docker-ce-cli",
        "containerd.io",
        "docker-buildx-plugin",
        "docker-compose-plugin",
    ):
        assert package in provision
    assert provision.index("docker-compose-plugin") < provision.index(
        "systemctl enable --now docker.service"
    )

    unsafe = provision.lower()
    assert "get.docker.com" not in unsafe
    assert not re.search(r"curl[^\n]*\|\s*(?:ba)?sh", unsafe)
    assert "docker system prune" not in unsafe
    assert "rm -rf /var/lib/docker" not in unsafe


def test_vps_host_scripts_are_executable() -> None:
    for script in (PROVISION, HARDEN_SSH, DOCKER_USER_RULES):
        assert script.stat().st_mode & stat.S_IXUSR, script


def test_vps_provisioning_installs_persistent_host_firewalls_safely() -> None:
    provision = PROVISION.read_text()

    assert 'if [ "$(id -u)" -ne 0 ]; then' in provision
    for path in (
        "/opt/ladle/releases",
        "/etc/ladle",
        "/var/backups/ladle",
        "/var/lib/ladle",
        "/etc/iptables/rules.v4",
        "/etc/iptables/rules.v6",
    ):
        assert path in provision

    ipv4 = _heredoc(provision, "LADLE_IPV4_RULES")
    ipv6 = _heredoc(provision, "LADLE_IPV6_RULES")
    for rules in (ipv4, ipv6):
        assert ":INPUT DROP" in rules
        assert ":OUTPUT ACCEPT" in rules
        assert "-i lo -j ACCEPT" in rules
        assert "--ctstate ESTABLISHED,RELATED -j ACCEPT" in rules
        assert "--dports 22,80,443" in rules
        assert rules.index("--ctstate ESTABLISHED,RELATED") < rules.index(
            "--dports 22,80,443"
        )
        assert rules.index("--dports 22,80,443") < rules.index("COMMIT")
        assert ":DOCKER-USER" in rules
        assert ":LADLE_DOCKER_PUBLIC_A" in rules
        assert "-A FORWARD -j DOCKER-USER" in rules
        assert "-A DOCKER-USER -j LADLE_DOCKER_PUBLIC_A" in rules
        assert "-A DOCKER-USER -j RETURN" in rules
        assert rules.index("-A DOCKER-USER -j LADLE_DOCKER_PUBLIC_A") < rules.index(
            "-A DOCKER-USER -j RETURN"
        )
        assert "--ctorigdstport 80" in rules
        assert "--ctorigdstport 443" in rules
        assert (
            "-i $public_interface -p udp -m conntrack --ctstate NEW --ctorigdstport 443"
        ) in rules
        docker_reject = rules.index(
            "-i $public_interface -m conntrack --ctstate NEW -j REJECT"
        )
        docker_return = rules.index("-A LADLE_DOCKER_PUBLIC_A -j RETURN")
        assert docker_reject < docker_return
    assert "-p icmp -j ACCEPT" in ipv4
    assert "-p ipv6-icmp -j ACCEPT" in ipv6

    # Reruns update only Ladle's live chain; a full restore would erase
    # Docker-owned chains and interrupt running containers.
    assert "apply_host_firewall /usr/sbin/iptables icmp" in provision
    assert "apply_host_firewall /usr/sbin/ip6tables ipv6-icmp" in provision
    assert "iptables-restore" not in provision
    assert "ip6tables-restore" not in provision
    assert "LADLE_HOST_INPUT_A" in provision
    assert "LADLE_HOST_INPUT_B" in provision
    assert '-F "$next_chain"' in provision
    assert "-F INPUT" not in provision
    assert "-F FORWARD" not in provision
    live_drop = provision.index('-A "$next_chain" -j DROP')
    live_hook = provision.index('-I INPUT 1 -j "$next_chain"')
    old_unhook = provision.index('-D INPUT -j "$active_chain"')
    assert live_drop < live_hook < old_unhook
    assert provision.rindex("LADLE_IPV6_RULES") < provision.index(
        "systemctl enable --now docker.service"
    )
    assert provision.index("public_interface=$(") < provision.index("LADLE_IPV4_RULES")
    assert "Requires=netfilter-persistent.service" in provision
    assert "After=netfilter-persistent.service" in provision
    assert provision.index("Requires=netfilter-persistent.service") < provision.index(
        "systemctl enable --now docker.service"
    )


def test_docker_user_firewall_blocks_unexpected_public_container_ports() -> None:
    provision = PROVISION.read_text()
    rules = DOCKER_USER_RULES.read_text()

    assert "@PUBLIC_INTERFACE@" in rules
    assert "/usr/local/sbin/ladle-docker-user-firewall" in provision
    assert "After=docker.service" in provision
    assert "ExecStart=/usr/local/sbin/ladle-docker-user-firewall" in provision
    assert "systemctl enable ladle-docker-user-firewall.service" in provision
    assert "systemctl restart ladle-docker-user-firewall.service" in provision
    assert "apply_rules /usr/sbin/iptables" in rules
    assert "apply_rules /usr/sbin/ip6tables" in rules
    assert "LADLE_DOCKER_PUBLIC_A" in rules
    assert "LADLE_DOCKER_PUBLIC_B" in rules
    assert '-I DOCKER-USER 1 -j "$next_chain"' in rules
    assert "--ctstate ESTABLISHED,RELATED -j ACCEPT" in rules
    assert '-i "$public_interface" -p tcp' in rules
    assert '-i "$public_interface" -p udp' in rules
    for original_port in ("80", "443"):
        assert f"--ctorigdstport {original_port}" in rules
    assert "--dport 80" not in rules
    assert "--dport 443" not in rules
    assert '-i "$public_interface" -m conntrack --ctstate NEW -j REJECT' in rules

    reject = rules.index("--ctstate NEW -j REJECT")
    fallthrough = rules.index('-A "$next_chain" -j RETURN')
    hook = rules.index('-I DOCKER-USER 1 -j "$next_chain"')
    old_unhook = rules.index('-D DOCKER-USER -j "$active_chain"')
    assert reject < fallthrough < hook < old_unhook
    assert "-F DOCKER-USER" not in rules
    assert "-X DOCKER-USER" not in rules
    assert "-F FORWARD" not in rules


def test_ssh_hardening_requires_verified_key_access_before_auth_changes() -> None:
    harden = HARDEN_SSH.read_text()

    assert harden.startswith("#!/bin/sh\nset -eu\numask 077\n")
    assert 'if [ "$(id -u)" -ne 0 ]; then' in harden
    assert "LADLE_SSH_KEY_LOGIN_VERIFIED_V1" in harden
    assert 'case "$marker_path" in' in harden
    assert '-f "$marker_path"' in harden
    assert '-L "$marker_path"' in harden
    assert 'readlink -f -- "$marker_path"' in harden
    assert 'stat -c "%u:%a" -- "$marker_path"' in harden
    assert '"0:600"' in harden
    assert 'cmp -s -- "$marker_expected" "$marker_path"' in harden

    assert "authorized_keys" in harden
    assert "ssh-ed25519" in harden
    assert 'if [ "$target_uid" -eq 0 ]; then' in harden
    marker_gate = harden.index('cmp -s -- "$marker_expected" "$marker_path"')
    key_gate = harden.index("authorized_keys", marker_gate)
    auth_change = harden.index("PasswordAuthentication no")
    assert marker_gate < key_gate < auth_change


def test_ssh_hardening_is_atomic_and_preserves_the_active_session() -> None:
    harden = HARDEN_SSH.read_text()

    for setting in (
        "PermitRootLogin no",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "ChallengeResponseAuthentication no",
    ):
        assert setting in harden
    assert "/etc/ssh/sshd_config.d/00-ladle-hardening.conf" in harden
    assert "/usr/sbin/sshd -t" in harden
    assert "/usr/sbin/sshd -T" in harden
    for effective_setting in (
        "permitrootlogin no",
        "passwordauthentication no",
        "kbdinteractiveauthentication no",
        "pubkeyauthentication yes",
    ):
        assert effective_setting in harden
    assert 'validate_effective_configuration "$target_user"' in harden
    assert "validate_effective_configuration root" in harden
    assert "systemctl reload ssh" in harden
    assert harden.index("/usr/sbin/sshd -t") < harden.index("systemctl reload ssh")
    assert harden.index("/usr/sbin/sshd -T") < harden.index("systemctl reload ssh")
    assert "Keep session A open" in harden
    assert "separate session B" in harden
    assert "public-key" in harden
    assert "restore_previous_dropin" in harden

    unsafe = harden.lower()
    assert not re.search(r"\bsystemctl\s+(?:stop|restart)\s+ssh", unsafe)
    assert not re.search(r"^\s*(?:passwd|chpasswd)\b", unsafe, re.MULTILINE)
    assert "authorized_keys" in harden
    assert not re.search(r"\brm\b[^\n]*authorized_keys", unsafe)
