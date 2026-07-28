import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path
from typing import Any

import pytest
import yaml

BACKEND = Path(__file__).parents[3]
PROFILE = BACKEND / "deploy" / "vps" / "docker-compose.yml"
CADDYFILE = PROFILE.parent / "Caddyfile"
PROVISION = PROFILE.parent / "provision.sh"
HARDEN_SSH = PROFILE.parent / "harden-ssh.sh"
DOCKER_USER_RULES = PROFILE.parent / "ladle-docker-user.rules"
HOST_VALIDATION = PROFILE.parent / "host-validation.sh"
PUSH = PROFILE.parent / "push.sh"
DEPLOY = PROFILE.parent / "deploy.sh"
INITIALIZE_ENV = PROFILE.parent / "initialize-env.sh"
SET_SECRET = PROFILE.parent / "set-secret.sh"
DEPLOYMENT_LIB = PROFILE.parent / "deployment-lib.sh"
PROGRESS_LOG = "/var/log/ladle/setup.log"

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


def _run_validation(
    function: str,
    *arguments: str | Path,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "/bin/sh",
            "-c",
            f'. "$1"; shift; {function} "$@"',
            "test",
            str(HOST_VALIDATION),
            *(str(argument) for argument in arguments),
        ],
        check=False,
        capture_output=True,
        input=input_text,
        text=True,
    )


def _run_deployment_library(
    function: str,
    *arguments: str | Path,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "/bin/sh",
            "-c",
            f'. "$1"; shift; {function} "$@"',
            "test",
            str(DEPLOYMENT_LIB),
            *(str(argument) for argument in arguments),
        ],
        check=False,
        capture_output=True,
        input=input_text,
        text=True,
    )


def _run_library_script(
    script: str,
    *arguments: str | Path,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "/bin/sh",
            "-c",
            f'. "$1"; shift; {script}',
            "test",
            str(DEPLOYMENT_LIB),
            *(str(argument) for argument in arguments),
        ],
        check=False,
        capture_output=True,
        env={**os.environ, **(env or {})},
        text=True,
    )


def _write_fake_flock(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import fcntl
import sys

arguments = sys.argv[1:]
nonblocking = arguments[0] == "-n"
descriptor = int(arguments[-1])
operation = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
try:
    fcntl.flock(descriptor, operation)
except BlockingIOError:
    raise SystemExit(1)
"""
    )
    path.chmod(0o755)


def _staging_environment() -> str:
    return "\n".join(
        (
            "LADLE_PUBLIC_HOSTNAME=api.ladle.app",
            "LADLE_DATABASE_PASSWORD=abc123",
            "LADLE_DATABASE_PASSWORD_URL_ENCODED=abc123",
            "LADLE_WORKER_PROVIDER_MODE=fake",
            "LADLE_JWT_SIGNING_SECRET=jwt123",
            "LADLE_DATA_ENCRYPTION_KEY=data123",
            "LADLE_METRICS_AUTH_TOKEN=metrics123",
            "LADLE_OBJECT_STORAGE_ACCESS_KEY=access123",
            "LADLE_OBJECT_STORAGE_SECRET_KEY=storage123",
            "LADLE_TUNNEL_ACCESS_KEY=tunnel123",
            "",
        )
    )


def _write_fake_iptables(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

state_path = Path(sys.argv[0]).with_suffix(".json")
state = (
    json.loads(state_path.read_text())
    if state_path.exists()
    else {"chains": {"FORWARD": []}, "failed": False}
)
args = sys.argv[1:]
command = " ".join(args)
if (
    os.environ.get("FAKE_FAIL_PROGRAM") == Path(sys.argv[0]).name
    and os.environ.get("FAKE_FAIL_MATCH", "") in command
    and not state["failed"]
):
    state["failed"] = True
    state_path.write_text(json.dumps(state))
    raise SystemExit(1)

chains = state["chains"]
operation = args[0]
chain = args[1]
if operation == "-nL":
    status = 0 if chain in chains else 1
elif operation == "-N":
    chains[chain] = []
    status = 0
elif operation == "-F":
    chains[chain] = []
    status = 0
elif operation in {"-C", "-D", "-I"}:
    jump = ["-j", args[-1]]
    rules = chains.setdefault(chain, [])
    if operation == "-C":
        status = 0 if jump in rules else 1
    elif operation == "-D":
        if jump not in rules:
            status = 1
        else:
            rules.remove(jump)
            status = 0
    else:
        rules.insert(0, jump)
        status = 0
elif operation == "-A":
    chains.setdefault(chain, []).append(args[2:])
    status = 0
else:
    raise SystemExit(f"unsupported fake iptables command: {command}")

state_path.write_text(json.dumps(state))
raise SystemExit(status)
"""
    )
    path.chmod(0o755)


def _firewall_harness(tmp_path: Path) -> tuple[Path, Path, Path]:
    tmp_path.mkdir(parents=True)
    fake_ipv4 = tmp_path / "iptables-v4"
    fake_ipv6 = tmp_path / "iptables-v6"
    _write_fake_iptables(fake_ipv4)
    _write_fake_iptables(fake_ipv6)
    rendered = _run_validation(
        "render_docker_firewall",
        DOCKER_USER_RULES,
        "ens4",
        "ens6",
    )
    assert rendered.returncode == 0, rendered.stderr
    script = tmp_path / "ladle-docker-user-firewall"
    script.write_text(
        rendered.stdout.replace("/usr/sbin/ip6tables", str(fake_ipv6)).replace(
            "/usr/sbin/iptables", str(fake_ipv4)
        )
    )
    script.chmod(0o755)
    return script, fake_ipv4.with_suffix(".json"), fake_ipv6.with_suffix(".json")


def _run_firewall(
    script: Path,
    *,
    fail_program: str = "",
    fail_match: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(script)],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "FAKE_FAIL_PROGRAM": fail_program,
            "FAKE_FAIL_MATCH": fail_match,
        },
        text=True,
    )


def _firewall_state(path: Path) -> dict[str, Any]:
    loaded = json.loads(path.read_text())
    assert isinstance(loaded, dict)
    return loaded


def _docker_user_hooks(state: dict[str, Any]) -> list[str]:
    chains = state["chains"]
    return [rule[1] for rule in chains["DOCKER-USER"] if rule[0] == "-j"]


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


def test_docker_key_validation_rejects_an_appended_primary(tmp_path: Path) -> None:
    trusted = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
    metadata = tmp_path / "docker-key.colons"
    trusted_bundle = (
        "pub:-:4096:1:8D81803C0EBFCD88:0:0:::::scESC::::::23::0:\n"
        f"fpr:::::::::{trusted}:\n"
        "sub:-:4096:1:AAAAAAAAAAAAAAAA:0:0:::::e::::::23:\n"
        "fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\n"
    )
    metadata.write_text(trusted_bundle)
    assert (
        _run_validation("docker_key_metadata_is_trusted", metadata, trusted).returncode
        == 0
    )

    metadata.write_text(
        trusted_bundle
        + "pub:-:4096:1:BBBBBBBBBBBBBBBB:0:0:::::sc::::::23::0:\n"
        + "fpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:\n"
    )
    assert (
        _run_validation("docker_key_metadata_is_trusted", metadata, trusted).returncode
        != 0
    )


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
    for rules, public_interface in (
        (ipv4, "$ipv4_public_interface"),
        (ipv6, "$ipv6_public_interface"),
    ):
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
            f"-i {public_interface} -p udp -m conntrack --ctstate NEW "
            "--ctorigdstport 443"
        ) in rules
        docker_reject = rules.index(
            f"-i {public_interface} -m conntrack --ctstate NEW -j REJECT"
        )
        docker_return = rules.index("-A LADLE_DOCKER_PUBLIC_A -j RETURN")
        assert docker_reject < docker_return
    assert "-p icmp -j ACCEPT" in ipv4
    assert "-p ipv6-icmp -j ACCEPT" in ipv6

    # Reruns update only Ladle's live chain; a full restore would erase
    # Docker-owned chains and interrupt running containers.
    assert "apply_host_firewall /usr/sbin/iptables icmp" in provision
    assert "apply_host_firewall /usr/sbin/ip6tables ipv6-icmp" in provision
    assert "/usr/sbin/iptables-restore --test" in provision
    assert "/usr/sbin/ip6tables-restore --test" in provision
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
    assert provision.index("ipv4_public_interface=$(") < provision.index(
        "LADLE_IPV4_RULES"
    )
    assert provision.index("ipv6_public_interface=$(") < provision.index(
        "LADLE_IPV4_RULES"
    )
    assert "Requires=netfilter-persistent.service" in provision
    assert "After=netfilter-persistent.service" in provision
    assert provision.index("Requires=netfilter-persistent.service") < provision.index(
        "systemctl enable --now docker.service"
    )


def test_docker_user_firewall_blocks_unexpected_public_container_ports() -> None:
    provision = PROVISION.read_text()
    rules = DOCKER_USER_RULES.read_text()

    assert "@PUBLIC_IPV4_INTERFACE@" in rules
    assert "@PUBLIC_IPV6_INTERFACE@" in rules
    assert "/usr/local/sbin/ladle-docker-user-firewall" in provision
    assert "After=docker.service" in provision
    assert "ExecStart=/usr/local/sbin/ladle-docker-user-firewall" in provision
    assert "systemctl enable ladle-docker-user-firewall.service" in provision
    assert "systemctl restart ladle-docker-user-firewall.service" in provision
    assert 'apply_rules /usr/sbin/iptables "$ipv4_public_interface"' in rules
    assert 'apply_rules /usr/sbin/ip6tables "$ipv6_public_interface"' in rules
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


def test_docker_user_firewall_recovers_and_fails_closed(tmp_path: Path) -> None:
    script, ipv4_path, ipv6_path = _firewall_harness(tmp_path / "normal")

    assert _run_firewall(script).returncode == 0
    first_ipv4 = _firewall_state(ipv4_path)
    first_ipv6 = _firewall_state(ipv6_path)
    assert _docker_user_hooks(first_ipv4) == ["LADLE_DOCKER_PUBLIC_A"]
    assert _docker_user_hooks(first_ipv6) == ["LADLE_DOCKER_PUBLIC_A"]
    assert any("ens4" in rule for rule in first_ipv4["chains"]["LADLE_DOCKER_PUBLIC_A"])
    assert any("ens6" in rule for rule in first_ipv6["chains"]["LADLE_DOCKER_PUBLIC_A"])

    assert _run_firewall(script).returncode == 0
    second_ipv4 = _firewall_state(ipv4_path)
    assert _docker_user_hooks(second_ipv4) == ["LADLE_DOCKER_PUBLIC_B"]

    # Recover deterministically when an interrupted prior run left both
    # equivalent owned hooks installed.
    chains = second_ipv4["chains"]
    chains["LADLE_DOCKER_PUBLIC_A"] = list(chains["LADLE_DOCKER_PUBLIC_B"])
    chains["DOCKER-USER"].insert(0, ["-j", "LADLE_DOCKER_PUBLIC_A"])
    ipv4_path.write_text(json.dumps(second_ipv4))
    assert _run_firewall(script).returncode == 0
    assert _docker_user_hooks(_firewall_state(ipv4_path)) == ["LADLE_DOCKER_PUBLIC_B"]

    before_script, before_ipv4_path, _ = _firewall_harness(tmp_path / "before-hook")
    assert _run_firewall(before_script).returncode == 0
    failed_before = _run_firewall(
        before_script,
        fail_program="iptables-v4",
        fail_match=(
            "-A LADLE_DOCKER_PUBLIC_B -i ens4 -m conntrack --ctstate NEW -j REJECT"
        ),
    )
    assert failed_before.returncode != 0
    assert _docker_user_hooks(_firewall_state(before_ipv4_path)) == [
        "LADLE_DOCKER_PUBLIC_A"
    ]

    after_script, after_ipv4_path, _ = _firewall_harness(tmp_path / "after-hook")
    assert _run_firewall(after_script).returncode == 0
    failed_after = _run_firewall(
        after_script,
        fail_program="iptables-v4",
        fail_match="-D DOCKER-USER -j LADLE_DOCKER_PUBLIC_A",
    )
    assert failed_after.returncode != 0
    after_state = _firewall_state(after_ipv4_path)
    assert _docker_user_hooks(after_state) == [
        "LADLE_DOCKER_PUBLIC_B",
        "LADLE_DOCKER_PUBLIC_A",
    ]
    assert (
        after_state["chains"]["LADLE_DOCKER_PUBLIC_A"]
        == after_state["chains"]["LADLE_DOCKER_PUBLIC_B"]
    )


def test_split_public_interfaces_render_for_their_own_family() -> None:
    ipv4 = _run_validation(
        "public_interface_from_routes",
        input_text="default via 135.148.42.1 dev ens4 proto dhcp\n",
    )
    ipv6 = _run_validation(
        "public_interface_from_routes",
        input_text="default via fe80::1 dev ens6 proto ra metric 100\n",
    )
    assert ipv4.returncode == 0
    assert ipv4.stdout.strip() == "ens4"
    assert ipv6.returncode == 0
    assert ipv6.stdout.strip() == "ens6"
    assert (
        _run_validation("public_interface_from_routes", input_text="").returncode != 0
    )

    rendered = _run_validation(
        "render_docker_firewall",
        DOCKER_USER_RULES,
        "ens4",
        "ens6",
    )
    assert rendered.returncode == 0
    assert "ipv4_public_interface='ens4'" in rendered.stdout
    assert "ipv6_public_interface='ens6'" in rendered.stdout
    assert 'apply_rules /usr/sbin/iptables "$ipv4_public_interface"' in rendered.stdout
    assert 'apply_rules /usr/sbin/ip6tables "$ipv6_public_interface"' in rendered.stdout


def test_authorized_keys_are_parsed_by_openssh(tmp_path: Path) -> None:
    ssh_keygen = shutil.which("ssh-keygen")
    if ssh_keygen is None:
        pytest.skip("ssh-keygen is unavailable")

    private_key = tmp_path / "id_ed25519"
    subprocess.run(
        [ssh_keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(private_key)],
        check=True,
    )
    public_key = private_key.with_suffix(".pub").read_text().strip()
    authorized_keys = tmp_path / "authorized_keys"

    for valid_content in (
        f"{public_key}\n",
        f'restrict,from="192.0.2.10" {public_key}\n',
    ):
        authorized_keys.write_text(valid_content)
        assert (
            _run_validation("authorized_keys_has_valid_key", authorized_keys).returncode
            == 0
        )

    authorized_keys.write_text("ssh-ed25519 A\n")
    assert (
        _run_validation("authorized_keys_has_valid_key", authorized_keys).returncode
        != 0
    )


def test_ssh_marker_is_bound_to_the_target_user(tmp_path: Path) -> None:
    marker = tmp_path / "verified"
    marker.write_text("LADLE_SSH_KEY_LOGIN_VERIFIED_V2 user=ubuntu\n")

    assert _run_validation("ssh_marker_matches_user", marker, "ubuntu").returncode == 0
    assert _run_validation("ssh_marker_matches_user", marker, "deploy").returncode != 0


def test_ssh_policy_validators_reject_auth_fallback_and_nested_match(
    tmp_path: Path,
) -> None:
    hardened = "\n".join(
        (
            "permitrootlogin no",
            "passwordauthentication no",
            "kbdinteractiveauthentication no",
            "pubkeyauthentication yes",
            "authenticationmethods publickey",
        )
    )
    assert (
        _run_validation(
            "effective_sshd_output_is_hardened", input_text=f"{hardened}\n"
        ).returncode
        == 0
    )
    fallback = hardened.replace(
        "authenticationmethods publickey",
        "authenticationmethods publickey,password",
    )
    assert (
        _run_validation(
            "effective_sshd_output_is_hardened", input_text=f"{fallback}\n"
        ).returncode
        != 0
    )

    include_dir = tmp_path / "sshd_config.d"
    include_dir.mkdir()
    main = tmp_path / "sshd_config"
    included = include_dir / "cloud.conf"
    main.write_text(f"Include {include_dir}/*.conf\nPasswordAuthentication no\n")
    included.write_text("# Match User nobody\nUseDNS no\n")
    assert _run_validation("sshd_config_tree_has_no_match", main).returncode == 0

    nested = tmp_path / "nested.conf"
    included.write_text(f"Include {nested}\n")
    nested.write_text("Match User ubuntu\n    PasswordAuthentication yes\n")
    assert _run_validation("sshd_config_tree_has_no_match", main).returncode != 0


def test_openssh_reports_publickey_only_authentication(tmp_path: Path) -> None:
    ssh_keygen = shutil.which("ssh-keygen")
    sshd = shutil.which("sshd")
    if ssh_keygen is None or sshd is None:
        pytest.skip("ssh-keygen or sshd is unavailable")

    host_key = tmp_path / "ssh_host_ed25519_key"
    subprocess.run(
        [ssh_keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(host_key)],
        check=True,
    )
    config = tmp_path / "sshd_config"
    config.write_text(
        "\n".join(
            (
                f"HostKey {host_key}",
                "UsePAM no",
                "PermitRootLogin no",
                "PasswordAuthentication no",
                "KbdInteractiveAuthentication no",
                "PubkeyAuthentication yes",
                "AuthenticationMethods publickey",
                "",
            )
        )
    )
    effective = subprocess.run(
        [
            sshd,
            "-T",
            "-f",
            str(config),
            "-C",
            "user=ubuntu,host=localhost,addr=198.51.100.10,laddr=192.0.2.10,lport=22",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert effective.returncode == 0, effective.stderr
    assert (
        _run_validation(
            "effective_sshd_output_is_hardened",
            input_text=effective.stdout,
        ).returncode
        == 0
    )


def test_ssh_reload_transaction_keeps_disk_and_daemon_consistent(
    tmp_path: Path,
) -> None:
    harness = tmp_path / "reload-harness.sh"
    harness.write_text(
        """#!/bin/sh
set -eu
state_directory=$1
mode=$2
validation_library=$3
. "$validation_library"

disk_state=$state_directory/disk
daemon_state=$state_directory/daemon
result_state=$state_directory/result
printf '%s\\n' candidate >"$disk_state"
printf '%s\\n' prior >"$daemon_state"
configuration_pending=true
reload_calls=0

restore_previous() {
    if [ "$mode" = restore-failure ]; then
        return 1
    fi
    printf '%s\\n' prior >"$disk_state"
    configuration_pending=false
}
commit_candidate() {
    configuration_pending=false
}
validate_disk() {
    [ "$(cat "$disk_state")" = prior ]
}
reload_daemon() {
    reload_calls=$((reload_calls + 1))
    if { [ "$mode" = failure ] || [ "$mode" = restore-failure ]; } &&
        [ "$reload_calls" -eq 1 ]; then
        return 1
    fi
    cat "$disk_state" >"$daemon_state"
    if [ "$mode" = signal ] && [ "$reload_calls" -eq 1 ]; then
        kill -TERM "$$"
    fi
}
cleanup() {
    if [ "$configuration_pending" = true ]; then
        restore_previous || :
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

if [ "$mode" = before ]; then
    kill -TERM "$$"
fi
transaction_status=0
reload_ssh_transaction \
    reload_daemon restore_previous validate_disk commit_candidate ||
    transaction_status=$?
printf '%s\\n' "$transaction_status" >"$result_state"
"""
    )
    harness.chmod(0o755)

    def run(mode: str) -> tuple[subprocess.CompletedProcess[str], str, str, str]:
        state = tmp_path / mode
        state.mkdir()
        result = subprocess.run(
            [str(harness), str(state), mode, str(HOST_VALIDATION)],
            check=False,
            capture_output=True,
            text=True,
        )
        transaction = (state / "result").read_text().strip()
        return (
            result,
            (state / "disk").read_text().strip(),
            (state / "daemon").read_text().strip(),
            transaction,
        )

    before = tmp_path / "before"
    before.mkdir()
    interrupted_before = subprocess.run(
        [str(harness), str(before), "before", str(HOST_VALIDATION)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert interrupted_before.returncode != 0
    assert (before / "disk").read_text().strip() == "prior"
    assert (before / "daemon").read_text().strip() == "prior"

    signal_result, signal_disk, signal_daemon, signal_status = run("signal")
    assert signal_result.returncode == 0
    assert signal_status == "3"
    assert signal_disk == signal_daemon == "candidate"

    failure_result, failure_disk, failure_daemon, failure_status = run("failure")
    assert failure_result.returncode == 0
    assert failure_status == "1"
    assert failure_disk == failure_daemon == "prior"

    failed_restore, restore_disk, restore_daemon, restore_status = run(
        "restore-failure"
    )
    assert failed_restore.returncode == 0
    assert restore_status == "2"
    assert restore_disk == "candidate"
    assert restore_daemon == "prior"


def test_ssh_hardening_requires_verified_key_access_before_auth_changes() -> None:
    harden = HARDEN_SSH.read_text()
    validation = HOST_VALIDATION.read_text()

    assert harden.startswith("#!/bin/sh\nset -eu\numask 077\n")
    assert 'if [ "$(id -u)" -ne 0 ]; then' in harden
    assert "LADLE_SSH_KEY_LOGIN_VERIFIED_V2 user=" in validation
    assert 'case "$marker_path" in' in harden
    assert '-f "$marker_path"' in harden
    assert '-L "$marker_path"' in harden
    assert 'readlink -f -- "$marker_path"' in harden
    assert 'stat -c "%u:%a" -- "$marker_path"' in harden
    assert '"0:600"' in harden
    assert 'ssh_marker_matches_user "$marker_path" "$target_user"' in harden

    assert "authorized_keys" in harden
    assert "ssh-keygen" in validation
    assert 'if [ "$target_uid" -eq 0 ]; then' in harden
    marker_gate = harden.index('ssh_marker_matches_user "$marker_path" "$target_user"')
    key_gate = harden.index("authorized_keys", marker_gate)
    auth_change = harden.index("PasswordAuthentication no")
    assert marker_gate < key_gate < auth_change


def test_ssh_hardening_is_atomic_and_preserves_the_active_session() -> None:
    harden = HARDEN_SSH.read_text()
    validation = HOST_VALIDATION.read_text()

    for setting in (
        "PermitRootLogin no",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "ChallengeResponseAuthentication no",
        "AuthenticationMethods publickey",
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
        "authenticationmethods publickey",
    ):
        assert effective_setting in validation
    assert 'validate_effective_contexts "$target_user"' in harden
    assert "validate_effective_contexts root" in harden
    assert "SSH_CONNECTION" in harden
    assert "--preserve-env=SSH_CONNECTION" in harden
    assert "198.51.100.10" in harden
    assert "2001:db8::10" in harden
    assert "sshd_config_tree_has_no_match" in harden
    assert "manual audit" in harden
    assert "systemctl reload ssh" in harden
    assert harden.index("/usr/sbin/sshd -t") < harden.index("systemctl reload ssh")
    assert harden.index("/usr/sbin/sshd -T") < harden.index("systemctl reload ssh")
    assert "Keep session A open" in harden
    assert "separate session B" in harden
    assert "public-key" in harden
    assert "restore_previous_dropin" in harden
    assert "reload_ssh_transaction" in harden
    assert "ssh_reload_signal_pending=true" in validation
    assert validation.index("ssh_reload_signal_pending=true") < validation.index(
        '"$ssh_reload_command"'
    )
    restore = harden[
        harden.index("restore_previous_dropin()") : harden.index(
            "\nconfiguration_pending=true"
        )
    ]
    assert 'mv -f -- "$dropin_previous" "$dropin" || return 1' in restore
    assert 'rm -f -- "$dropin" || return 1' in restore
    assert restore.index('mv -f -- "$dropin_previous" "$dropin"') < restore.index(
        "dropin_previous="
    )
    assert restore.index('rm -f -- "$dropin"') < restore.index(
        "configuration_pending=false"
    )
    cleanup = harden[harden.index("cleanup()") : harden.index("\ntrap cleanup 0")]
    assert "if ! restore_previous_dropin; then" in cleanup
    assert '"Preserved backup: ${dropin_previous:-none}"' in cleanup
    assert '[ "$configuration_pending" = false ] &&' in cleanup

    unsafe = harden.lower()
    assert not re.search(r"\bsystemctl\s+(?:stop|restart)\s+ssh", unsafe)
    assert not re.search(r"^\s*(?:passwd|chpasswd)\b", unsafe, re.MULTILINE)
    assert "authorized_keys" in harden
    assert not re.search(r"\brm\b[^\n]*authorized_keys", unsafe)


def test_vps_host_installs_sensitive_files_atomically_and_repairs_restarts() -> None:
    provision = PROVISION.read_text()

    assert "install -d -o root -g root -m 0755 /opt/ladle/releases" in provision
    for atomic_file in (
        (
            "docker_key_gpg",
            'chmod 0644 "$docker_key_gpg"',
            'gpg --batch --with-colons --show-keys \\\n    "$docker_key_gpg"',
            'mv -f -- "$docker_key_gpg" /etc/apt/keyrings/docker.gpg',
        ),
        (
            "ipv4_rules_tmp",
            'chmod 0600 "$ipv4_rules_tmp"',
            '/usr/sbin/iptables-restore --test <"$ipv4_rules_tmp"',
            'mv -f -- "$ipv4_rules_tmp" /etc/iptables/rules.v4',
        ),
        (
            "ipv6_rules_tmp",
            'chmod 0600 "$ipv6_rules_tmp"',
            '/usr/sbin/ip6tables-restore --test <"$ipv6_rules_tmp"',
            'mv -f -- "$ipv6_rules_tmp" /etc/iptables/rules.v6',
        ),
    ):
        variable, permissions, validation, rename = atomic_file
        assert provision.index(permissions) < provision.index(validation)
        rename_index = provision.index(rename)
        assert provision.index(validation) < rename_index
        assert provision.index(f"{variable}=", rename_index) > rename_index
    assert not re.search(
        r"install[^\n]*docker_key_gpg[^\n]*/etc/apt/keyrings/docker\.gpg",
        provision,
    )
    assert not re.search(
        r"install[^\n]*(?:ipv4|ipv6)_rules_tmp[^\n]*/etc/iptables/rules\.v[46]",
        provision,
    )
    assert "PartOf=docker.service" in provision
    assert "ExecStartPost=/usr/local/sbin/ladle-docker-user-firewall" in provision


def test_vps_release_scripts_are_posix_executable_and_never_trace() -> None:
    scripts = (PUSH, DEPLOY, INITIALIZE_ENV, SET_SECRET, DEPLOYMENT_LIB)

    for script in scripts:
        text = script.read_text()
        assert text.startswith("#!/bin/sh\n"), script
        assert re.search(r"^set -eu$", text, re.MULTILINE), script
        assert "umask 077" in text, script
        assert script.stat().st_mode & stat.S_IXUSR, script
        assert "set -x" not in text, script


def test_push_refuses_dirty_state_and_transfers_only_the_exact_archive() -> None:
    push = PUSH.read_text()

    assert "git status --porcelain --untracked-files=all" in push
    assert "git rev-parse --verify HEAD^{commit}" in push
    assert "git archive --format=tar" in push
    assert "scp " in push
    assert "/opt/ladle/releases/$revision" in push
    assert ".ladle-revision" in push
    assert "tar -tf" in push
    assert "tar -tvf" in push
    assert "readlink -f" in push
    assert "mktemp -d /tmp/ladle-upload.XXXXXX" in push
    assert 'remote_archive="$remote_directory/release.tar"' in push
    assert 'stat -c "%u:%a" -- "$remote_directory"' in push
    assert "mktemp -d /opt/ladle/releases/.incoming-" in push
    assert "sudo -n mv -T --" in push
    assert 'sudo -n "$release/Backend/deploy/vps/initialize-env.sh"' in push
    assert 'sudo -n "$release/Backend/deploy/vps/deploy.sh" "$revision"' in push
    assert "rsync" not in push
    assert re.search(r"\bscp\s+-r\b", push) is None
    assert "git push" not in push
    assert "working tree" not in push.lower()

    for forbidden in (
        ".git",
        ".env",
        ".private",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
    ):
        assert forbidden in push

    cleanup = push[push.index("cleanup()") : push.index("\ntrap cleanup")]
    assert 'rm -f -- "$archive"' in cleanup
    assert "remote_prepared" in cleanup
    assert "rm -f -- '$remote_archive'" in cleanup


def test_push_makes_completed_releases_root_owned_and_immutable() -> None:
    push = PUSH.read_text()
    deploy = DEPLOY.read_text()

    assert 'sudo -n chown root:root "$releases_directory"' in push
    assert 'sudo -n chmod 0755 "$releases_directory"' in push
    assert "sudo -n mktemp /opt/ladle/releases/.archive-" in push
    assert "sudo -n mktemp -d /opt/ladle/releases/.incoming-" in push
    assert 'sudo -n chown -R root:root "$incoming"' in push
    assert 'sudo -n chmod -R go-w "$incoming"' in push
    assert 'find "$root_release" -xdev' in push
    assert "! -user root" in push
    assert "-perm /022" in push
    assert 'stat -c "%u:%a" -- "$root_release"' in deploy
    assert 'find "$root_release" -xdev' in deploy
    assert "release_root_is_safe" in deploy
    for relative_path in (
        "Backend/deploy/vps/initialize-env.sh",
        "Backend/deploy/vps/deploy.sh",
        "Backend/deploy/vps/deployment-lib.sh",
        "Backend/docker-compose.yml",
        "Backend/deploy/vps/docker-compose.yml",
    ):
        assert relative_path in push
        assert relative_path in deploy


def test_push_requires_noninteractive_sudo_before_remote_mutation() -> None:
    push = PUSH.read_text()

    preflight = push.index("sudo -n true")
    remote_temp = push.index("mktemp -d /tmp/ladle-upload.XXXXXX")
    upload = push.index('scp "$archive"')
    assert preflight < remote_temp < upload
    assert "Noninteractive sudo is required" in push
    assert re.search(r"^\s*sudo\s+(?!-n\b)", push, re.MULTILINE) is None


def test_push_dirty_refusal_happens_before_network_access(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    script_dir = repository / "Backend" / "deploy" / "vps"
    script_dir.mkdir(parents=True)
    copied_push = script_dir / "push.sh"
    copied_push.write_bytes(PUSH.read_bytes())
    copied_push.chmod(0o755)
    subprocess.run(["git", "init", "-q", repository], check=True)
    subprocess.run(["git", "-C", repository, "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            repository,
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-qm",
            "fixture",
        ],
        check=True,
    )
    (repository / "untracked-secret").write_text("not archived\n")

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for command in ("scp", "ssh"):
        fake = fake_bin / command
        fake.write_text("#!/bin/sh\nexit 99\n")
        fake.chmod(0o755)

    result = subprocess.run(
        [str(copied_push), "ubuntu@192.0.2.10"],
        check=False,
        capture_output=True,
        env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        text=True,
    )

    assert result.returncode != 0
    assert "dirty" in result.stderr.lower()
    assert "untracked-secret" not in result.stdout + result.stderr
    assert result.returncode != 99


def test_push_archive_excludes_untracked_and_control_paths(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    script_dir = repository / "Backend" / "deploy" / "vps"
    script_dir.mkdir(parents=True)
    copied_push = script_dir / "push.sh"
    copied_push.write_bytes(PUSH.read_bytes())
    copied_push.chmod(0o755)
    (repository / "tracked.txt").write_text("tracked\n")
    subprocess.run(["git", "init", "-q", repository], check=True)
    subprocess.run(["git", "-C", repository, "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            repository,
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-qm",
            "fixture",
        ],
        check=True,
    )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    uploaded = tmp_path / "uploaded.tar"
    fake_scp = fake_bin / "scp"
    fake_scp.write_text('#!/bin/sh\ncp -- "$1" "$LADLE_TEST_UPLOADED_ARCHIVE"\n')
    fake_scp.chmod(0o755)
    fake_ssh = fake_bin / "ssh"
    fake_ssh.write_text(
        """#!/bin/sh
case "$*" in
    *"mktemp -d /tmp/ladle-upload.XXXXXX"*)
        printf '%s\n' "$LADLE_TEST_REMOTE_DIRECTORY"
        ;;
esac
exit 0
"""
    )
    fake_ssh.chmod(0o755)
    remote_directory = "/tmp/ladle-upload.A1b2C3"

    result = subprocess.run(
        [str(copied_push), "ubuntu@192.0.2.10"],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "LADLE_TEST_UPLOADED_ARCHIVE": str(uploaded),
            "LADLE_TEST_REMOTE_DIRECTORY": remote_directory,
        },
        text=True,
    )

    assert result.returncode == 0, result.stderr
    listing = subprocess.run(
        ["tar", "-tf", uploaded],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    assert "tracked.txt" in listing
    assert ".git/" not in listing


def test_initialize_env_is_root_only_atomic_recoverable_and_complete() -> None:
    initialize = INITIALIZE_ENV.read_text()

    assert 'if [ "$(id -u)" -ne 0 ]; then' in initialize
    assert 'secret_group="ladle-secrets"' in initialize
    assert "groupadd --system" in initialize
    assert "/etc/ladle/ladle.env" in initialize
    assert "/etc/ladle/staging-access-key" in initialize
    assert "mktemp /etc/ladle/.ladle.env." in initialize
    assert "mktemp /etc/ladle/.staging-access-key." in initialize
    assert initialize.count("chmod 0640") >= 2
    assert initialize.count("chown root:") >= 2
    assert initialize.count("mv -f --") >= 2
    assert "openssl rand -hex" in initialize
    assert "LADLE_PUBLIC_HOSTNAME=${LADLE_PUBLIC_HOSTNAME:-api.ladle.app}" in initialize
    assert "LADLE_WORKER_PROVIDER_MODE=fake" in initialize
    for variable in (
        "LADLE_JWT_SIGNING_SECRET",
        "LADLE_DATA_ENCRYPTION_KEY",
        "LADLE_METRICS_AUTH_TOKEN",
        "LADLE_DATABASE_PASSWORD",
        "LADLE_DATABASE_PASSWORD_URL_ENCODED",
        "LADLE_OBJECT_STORAGE_ACCESS_KEY",
        "LADLE_OBJECT_STORAGE_SECRET_KEY",
        "LADLE_TUNNEL_ACCESS_KEY",
    ):
        assert variable in initialize
    assert "validate_staging_environment" in initialize
    assert "dotenv_value" in initialize
    assert "existing_tunnel_key" in initialize
    assert "printf '%s\\n' \"$tunnel_key\"" not in initialize
    assert "cat /etc/ladle" not in initialize
    assert ". /etc/ladle" not in initialize


def test_environment_library_validates_values_without_executing_them(
    tmp_path: Path,
) -> None:
    valid = tmp_path / "valid.env"
    valid.write_text(
        "LADLE_PUBLIC_HOSTNAME=api.ladle.app\n"
        "LADLE_WORKER_PROVIDER_MODE=fake\n"
        "LADLE_TUNNEL_ACCESS_KEY=0123abcdef\n"
    )
    assert (
        _run_deployment_library(
            "validate_env_file",
            valid,
        ).returncode
        == 0
    )
    value = _run_deployment_library(
        "dotenv_value",
        valid,
        "LADLE_TUNNEL_ACCESS_KEY",
    )
    assert value.returncode == 0
    assert value.stdout == "0123abcdef\n"

    for unsafe_content in (
        "LADLE_PUBLIC_HOSTNAME=$(touch /tmp/nope)\n",
        "LADLE_PUBLIC_HOSTNAME=api.ladle.app\nBROKEN\n",
        "LADLE_PUBLIC_HOSTNAME=first\nLADLE_PUBLIC_HOSTNAME=second\n",
        "LADLE_PUBLIC_HOSTNAME=api.ladle.app\r\n",
        "LADLE_PUBLIC_HOSTNAME=api ladle app\n",
    ):
        candidate = tmp_path / "unsafe.env"
        candidate.write_text(unsafe_content)
        assert _run_deployment_library("validate_env_file", candidate).returncode != 0


def test_set_secret_accepts_only_stdin_allowlisted_safe_values_atomically() -> None:
    script = SET_SECRET.read_text()
    library = DEPLOYMENT_LIB.read_text()

    assert 'if [ "$(id -u)" -ne 0 ]; then' in script
    assert 'case "$secret_name" in' in script
    for allowed in (
        "LADLE_OPENROUTER_API_KEY",
        "LADLE_SUPADATA_API_KEY",
        "LADLE_SOSCRIPTED_API_KEY",
    ):
        assert allowed in script
    assert "IFS= read -r DOTENV_STDIN_VALUE" in library
    assert "IFS= read -r dotenv_extra_line" in library
    assert "validate_dotenv_value" in library
    assert "mktemp /etc/ladle/.ladle.env." in script
    assert "chmod 0640" in script
    assert "chown root:" in script
    assert "mv -f --" in script
    assert "LADLE_WORKER_PROVIDER_MODE=live" in library
    assert script.index("LADLE_OPENROUTER_API_KEY") < script.index(
        "write_provider_secret_candidate"
    )
    assert "printf '%s\\n' \"$secret_value\"" not in script
    assert 'printf \'%s=%s\\n\' "$provider_name" "$provider_value"' in library
    assert "cat /etc/ladle" not in script
    assert ". /etc/ladle" not in script


def test_dotenv_value_validation_rejects_controls_and_shell_syntax() -> None:
    for value in ("sk-or-v1-abc_123", "token.with:/@+-safe"):
        assert _run_deployment_library("validate_dotenv_value", value).returncode == 0

    for value in (
        "",
        "two words",
        "value\nsecond",
        "value\r",
        "ümlaut",
        "$(id)",
        "quoted'value",
        "value#comment",
        "KEY=value",
        "value\\escape",
    ):
        result = _run_deployment_library("validate_dotenv_value", value)
        assert result.returncode != 0, repr(value)
        if value:
            assert value not in result.stdout + result.stderr


def test_secret_stdin_reader_accepts_one_safe_value_without_echoing_it() -> None:
    accepted = _run_deployment_library(
        "read_dotenv_stdin_value",
        input_text="sk-or-v1-safe_123\n",
    )
    assert accepted.returncode == 0
    assert accepted.stdout == ""
    assert accepted.stderr == ""

    for unsafe_input in (
        "",
        "\n",
        "first\nsecond\n",
        "first\n\n",
        "unsafe value\n",
        "unsafe\r\n",
        "ümlaut\n",
    ):
        rejected = _run_deployment_library(
            "read_dotenv_stdin_value",
            input_text=unsafe_input,
        )
        assert rejected.returncode != 0
        if unsafe_input.strip():
            assert unsafe_input.strip() not in rejected.stdout + rejected.stderr

    set_secret = SET_SECRET.read_text()
    assert "read_dotenv_stdin_value" in set_secret
    assert "secret_value=$DOTENV_STDIN_VALUE" in set_secret


def test_revision_validation_accepts_only_forty_lowercase_hex_characters() -> None:
    accepted = _run_deployment_library("validate_revision", "a" * 40)
    assert accepted.returncode == 0

    for rejected in (
        "a",
        "a" * 39,
        "a" * 41,
        "a" * 64,
        "A" * 40,
        ("a" * 39) + "-",
    ):
        assert _run_deployment_library("validate_revision", rejected).returncode != 0, (
            rejected
        )


def test_deploy_validates_exact_release_and_stable_project_before_mutation() -> None:
    deploy = DEPLOY.read_text()

    assert 'if [ "$(id -u)" -ne 0 ]; then' in deploy
    assert 'validate_revision "$revision"' in deploy
    assert 'release="/opt/ladle/releases/$revision"' in deploy
    assert '[ ! -L "$root_release" ]' in deploy
    assert 'readlink -f -- "$root_release"' in deploy
    assert ".ladle-revision" in deploy
    assert "revision_marker_matches" in deploy
    assert "/etc/ladle/ladle.env" in deploy
    assert "validate_env_metadata" in deploy
    assert "validate_staging_environment" in deploy
    assert "COMPOSE_PROJECT_NAME=ladle" in deploy
    assert "--project-name ladle" in deploy
    assert '--project-directory "$backend_directory"' in deploy
    assert "config --quiet" in deploy
    assert "flock -n" in DEPLOYMENT_LIB.read_text()
    assert ". /etc/ladle" not in deploy
    assert "cat /etc/ladle" not in deploy

    config = deploy.index("config --quiet")
    data = deploy.index("up -d --wait --wait-timeout", config)
    build = deploy.index("build migrate minio-init", data)
    bucket = deploy.index("run --rm minio-init", build)
    migrate = deploy.index("run --rm migrate", bucket)
    worker_pair = deploy.index("rollout_worker_pair", migrate)
    api = deploy.index("--no-deps api", worker_pair)
    beat = deploy.index("--force-recreate beat", api)
    edge = deploy.index("--no-deps edge", beat)
    caddy = deploy.index("--no-deps caddy", edge)
    assert config < data < build < bucket < migrate < worker_pair
    assert worker_pair < api < beat < edge < caddy


def test_deploy_waits_for_api_edge_worker_and_activates_last() -> None:
    deploy = DEPLOY.read_text()

    assert "wait_for_api_readiness" in deploy
    assert "http://127.0.0.1:4111/health/ready" in deploy
    assert "wait_for_edge_readiness" in deploy
    assert "http://edge:8082/health/ready" in deploy
    assert "wait_for_worker_ping" in deploy
    assert "inspect ping" in deploy
    assert "--timeout=10" in deploy
    assert "LADLE_HEALTH_ATTEMPTS" in deploy
    assert "sleep 2" in deploy
    assert 'activate_release "$release" /opt/ladle/current' in deploy

    activation = deploy.index('activate_release "$release" /opt/ladle/current')
    for gate in (
        "wait_for_api_readiness",
        "wait_for_edge_readiness",
        "wait_for_worker_ping",
    ):
        assert deploy.rindex(gate) < activation
    assert "deployment_phase" in deploy
    assert 'progress failure "$deployment_phase failed"' in deploy


def test_atomic_activation_preserves_current_until_called(tmp_path: Path) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    previous = releases / ("a" * 40)
    candidate = releases / ("b" * 40)
    previous.mkdir()
    candidate.mkdir()
    current = tmp_path / "current"
    current.symlink_to(previous)

    assert current.resolve() == previous
    activated = _run_deployment_library("activate_release", candidate, current)
    assert activated.returncode == 0, activated.stderr
    assert current.is_symlink()
    assert current.resolve() == candidate

    invalid_current = tmp_path / "invalid-current"
    invalid_current.write_text("do not replace\n")
    rejected = _run_deployment_library(
        "activate_release",
        previous,
        invalid_current,
    )
    assert rejected.returncode != 0
    assert invalid_current.read_text() == "do not replace\n"


def test_release_scripts_stream_sanitized_progress_to_a_private_server_log() -> None:
    library = DEPLOYMENT_LIB.read_text()
    push = PUSH.read_text()
    initialize = INITIALIZE_ENV.read_text()
    deploy = DEPLOY.read_text()

    assert PROGRESS_LOG in library
    assert "install -d -o root -g" in library
    assert "install -o root -g" in library
    assert "-m 0750" in library
    assert "-m 0640" in library
    assert 'printf "%s\\n" "$progress_line"' in library
    assert 'printf "%s\\n" "$progress_line" >>"$progress_log"' in library
    assert "validate_progress_text" in library
    assert "tee " not in library

    expected_order = (
        "archive",
        "upload",
        "environment",
        "compose-validation",
        "data-services",
        "image-build",
        "object-storage",
        "migrations",
        "service-rollout",
        "api-readiness",
        "edge-readiness",
        "worker-readiness",
        "beat-readiness",
        "activation",
        "success",
    )
    combined = "\n".join((push, initialize, deploy))
    positions = [combined.index(f'progress "{phase}"') for phase in expected_order]
    assert positions == sorted(positions)

    for secret_path in (
        "/etc/ladle/ladle.env",
        "/etc/ladle/staging-access-key",
    ):
        assert not re.search(
            rf"(?:cat|tee|sed\\s+-n|awk).*(?:{re.escape(secret_path)})",
            combined,
        )
    assert "docker compose config" not in library
    assert "setup.log" not in push
    remote_release = push[push.index("#!/bin/sh", 10) :]
    assert '"$release/Backend/deploy/vps/deployment-lib.sh"' in remote_release
    remote_progress = remote_release.index('. "$1"')
    remote_archive = remote_release.index(
        'progress "archive" "exact revision archive verified"'
    )
    remote_upload = remote_release.index(
        'progress "upload" "root-owned release installed"'
    )
    remote_initialize = remote_release.index(
        'sudo -n "$release/Backend/deploy/vps/initialize-env.sh"'
    )
    assert remote_progress < remote_archive < remote_upload < remote_initialize


def test_release_permission_boundary_requires_a_traversable_immutable_root(
    tmp_path: Path,
) -> None:
    release = tmp_path / "release"
    critical_paths = (
        "Backend/deploy/vps/initialize-env.sh",
        "Backend/deploy/vps/deploy.sh",
        "Backend/deploy/vps/deployment-lib.sh",
        "Backend/docker-compose.yml",
        "Backend/deploy/vps/docker-compose.yml",
    )
    for relative_path in critical_paths:
        target = release / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("#!/bin/sh\n")
        target.chmod(0o755 if target.suffix == ".sh" else 0o644)

    for unsafe_mode in (0o000, 0o700):
        release.chmod(unsafe_mode)
        result = _run_deployment_library(
            "release_directory_is_safe",
            release,
            str(os.getuid()),
        )
        assert result.returncode != 0

    release.chmod(0o755)
    safe = _run_deployment_library(
        "release_directory_is_safe",
        release,
        str(os.getuid()),
    )
    assert safe.returncode == 0, safe.stderr
    push = PUSH.read_text()
    assert push.index('sudo -n chmod 0755 "$incoming"') < push.index(
        'release_root_is_safe "$incoming"'
    )
    remote_validator = push[push.index("release_root_is_safe()") :]
    assert 'release_library="$root_release/Backend/deploy/vps/deployment-lib.sh"' in (
        remote_validator
    )
    assert '. "$release_library"' in remote_validator
    assert 'release_directory_is_safe "$root_release" 0' in remote_validator


def test_environment_lock_serializes_initializers_and_deploy_mutation(
    tmp_path: Path,
) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")
    lock = tmp_path / "environment.lock"
    lock.touch(mode=0o600)
    trace = tmp_path / "trace"
    runner = tmp_path / "lock-runner.sh"
    runner.write_text(
        f"""#!/bin/sh
set -eu
. "{DEPLOYMENT_LIB}"
acquire_environment_lock "$1" "$2"
printf 'start-%s\\n' "$3" >>"$4"
sleep 0.2
printf 'end-%s\\n' "$3" >>"$4"
"""
    )
    runner.chmod(0o755)
    command_env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}

    first = subprocess.Popen(
        [str(runner), str(lock), str(os.getuid()), "initializer", str(trace)],
        env=command_env,
    )
    second = subprocess.Popen(
        [str(runner), str(lock), str(os.getuid()), "deploy", str(trace)],
        env=command_env,
    )
    assert first.wait(timeout=5) == 0
    assert second.wait(timeout=5) == 0

    lines = trace.read_text().splitlines()
    assert lines in (
        ["start-initializer", "end-initializer", "start-deploy", "end-deploy"],
        ["start-deploy", "end-deploy", "start-initializer", "end-initializer"],
    )


def test_concurrent_provider_updates_preserve_both_secrets(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")
    lock = tmp_path / "environment.lock"
    lock.touch(mode=0o600)
    environment = tmp_path / "ladle.env"
    environment.write_text(_staging_environment())
    updater = tmp_path / "update.sh"
    updater.write_text(
        f"""#!/bin/sh
set -eu
umask 077
. "{DEPLOYMENT_LIB}"
acquire_environment_lock "$1" "$2"
candidate=$(mktemp "$3.candidate.XXXXXX")
write_provider_secret_candidate "$3" "$candidate" "$4" "$5"
sleep 0.1
mv -f -- "$candidate" "$3"
"""
    )
    updater.chmod(0o755)
    command_env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}

    first = subprocess.Popen(
        [
            str(updater),
            str(lock),
            str(os.getuid()),
            str(environment),
            "LADLE_SUPADATA_API_KEY",
            "supadata-value",
        ],
        env=command_env,
    )
    second = subprocess.Popen(
        [
            str(updater),
            str(lock),
            str(os.getuid()),
            str(environment),
            "LADLE_SOSCRIPTED_API_KEY",
            "soscripted-value",
        ],
        env=command_env,
    )
    assert first.wait(timeout=5) == 0
    assert second.wait(timeout=5) == 0
    final = environment.read_text()
    assert "LADLE_SUPADATA_API_KEY=supadata-value\n" in final
    assert "LADLE_SOSCRIPTED_API_KEY=soscripted-value\n" in final


def test_staging_environment_validation_enforces_cross_field_invariants(
    tmp_path: Path,
) -> None:
    environment = tmp_path / "ladle.env"
    environment.write_text(_staging_environment())
    assert (
        _run_deployment_library("validate_staging_environment", environment).returncode
        == 0
    )

    environment.write_text(
        _staging_environment().replace(
            "LADLE_DATABASE_PASSWORD_URL_ENCODED=abc123",
            "LADLE_DATABASE_PASSWORD_URL_ENCODED=different",
        )
    )
    assert (
        _run_deployment_library("validate_staging_environment", environment).returncode
        != 0
    )

    environment.write_text(
        _staging_environment().replace(
            "LADLE_WORKER_PROVIDER_MODE=fake",
            "LADLE_WORKER_PROVIDER_MODE=live",
        )
    )
    assert (
        _run_deployment_library("validate_staging_environment", environment).returncode
        != 0
    )

    candidate = tmp_path / "candidate.env"
    environment.write_text(_staging_environment())
    written = _run_deployment_library(
        "write_provider_secret_candidate",
        environment,
        candidate,
        "LADLE_OPENROUTER_API_KEY",
        "openrouter-value",
    )
    assert written.returncode == 0, written.stderr
    assert "LADLE_WORKER_PROVIDER_MODE=live\n" in candidate.read_text()
    assert (
        _run_deployment_library("validate_staging_environment", candidate).returncode
        == 0
    )


def test_environment_lock_is_shared_and_acquired_before_environment_reads() -> None:
    provision = PROVISION.read_text()
    initialize = INITIALIZE_ENV.read_text()
    set_secret = SET_SECRET.read_text()
    deploy = DEPLOY.read_text()

    assert "/var/lock/ladle-environment.lock" in provision
    assert "mode 0600" in provision
    assert "/var/lock/ladle-environment.lock" in initialize
    assert "/var/lock/ladle-environment.lock" in set_secret
    assert "/var/lock/ladle-environment.lock" in deploy
    assert initialize.index("acquire_environment_lock") < initialize.index(
        'if [ -e "$env_file" ]'
    )
    assert set_secret.index("acquire_environment_lock") < set_secret.index(
        'validate_env_metadata "$env_file"'
    )
    assert deploy.index("acquire_deployment_lock") < deploy.index(
        "acquire_environment_lock"
    )
    assert deploy.index("acquire_environment_lock") < deploy.index(
        'validate_env_metadata "$env_file"'
    )
    assert deploy.index("acquire_environment_lock") < deploy.index(
        "compose config --quiet"
    )


def test_deployment_state_flags_failure_without_changing_current(
    tmp_path: Path,
) -> None:
    state_directory = tmp_path / "state"
    state_directory.mkdir(mode=0o750)
    releases = tmp_path / "releases"
    releases.mkdir()
    previous = releases / ("a" * 40)
    candidate = releases / ("b" * 40)
    previous.mkdir(mode=0o755)
    candidate.mkdir(mode=0o755)
    current = tmp_path / "current"
    current.symlink_to(previous)
    state_file = state_directory / "deployment-state"

    deploying = _run_deployment_library(
        "write_deployment_state",
        state_directory,
        "deploying",
        candidate.name,
        "migrations",
        str(os.getuid()),
    )
    assert deploying.returncode == 0, deploying.stderr
    failed = _run_deployment_library(
        "write_deployment_state",
        state_directory,
        "failed",
        candidate.name,
        "migrations",
        str(os.getuid()),
    )
    assert failed.returncode == 0, failed.stderr

    assert current.resolve() == previous
    assert state_file.stat().st_mode & 0o777 == 0o644
    assert state_file.read_text() == (
        f"STATUS=failed\nREVISION={candidate.name}\nPHASE=migrations\n"
    )
    authoritative = _run_deployment_library(
        "deployment_state_matches_current",
        state_file,
        current,
        str(os.getuid()),
    )
    assert authoritative.returncode != 0


def test_deployment_state_becomes_active_only_after_activation(tmp_path: Path) -> None:
    state_directory = tmp_path / "state"
    state_directory.mkdir(mode=0o750)
    release = tmp_path / ("c" * 40)
    release.mkdir(mode=0o755)
    current = tmp_path / "current"
    state_file = state_directory / "deployment-state"

    assert (
        _run_deployment_library(
            "write_deployment_state",
            state_directory,
            "deploying",
            release.name,
            "activation",
            str(os.getuid()),
        ).returncode
        == 0
    )
    assert _run_deployment_library("activate_release", release, current).returncode == 0
    assert (
        _run_deployment_library(
            "write_deployment_state",
            state_directory,
            "active",
            release.name,
            "complete",
            str(os.getuid()),
        ).returncode
        == 0
    )
    authoritative = _run_deployment_library(
        "deployment_state_matches_current",
        state_file,
        current,
        str(os.getuid()),
    )
    assert authoritative.returncode == 0, authoritative.stderr
    state_file.chmod(0o666)
    unsafe = _run_deployment_library(
        "deployment_state_matches_current",
        state_file,
        current,
        str(os.getuid()),
    )
    assert unsafe.returncode != 0

    deploy = DEPLOY.read_text()
    assert deploy.index(
        'write_deployment_state "$state_directory" deploying'
    ) < deploy.index("compose up -d")
    assert deploy.index(
        'activate_release "$release" /opt/ladle/current'
    ) < deploy.index('write_deployment_state "$state_directory" active')
    assert 'write_deployment_state "$state_directory" failed' in deploy


def test_worker_rollout_command_order_and_failure_are_executable(
    tmp_path: Path,
) -> None:
    command_log = tmp_path / "commands"
    success = _run_library_script(
        """
command_log=$1
compose() { printf '%s\n' "$*" >>"$command_log"; }
rollout_worker_pair
""",
        command_log,
    )
    assert success.returncode == 0, success.stderr
    assert command_log.read_text().splitlines() == [
        "rm -f -s worker",
        "up -d --no-build --no-deps --wait --wait-timeout 120 worker-egress",
        (
            "up -d --no-build --no-deps --wait --wait-timeout 120 "
            "--force-recreate worker"
        ),
    ]

    command_log.write_text("")
    failed = _run_library_script(
        """
command_log=$1
compose() {
    printf '%s\n' "$*" >>"$command_log"
    case "$*" in *worker-egress) return 7 ;; esac
}
rollout_worker_pair
""",
        command_log,
    )
    assert failed.returncode != 0
    assert command_log.read_text().splitlines() == [
        "rm -f -s worker",
        "up -d --no-build --no-deps --wait --wait-timeout 120 worker-egress",
    ]


def test_beat_stability_gate_accepts_stable_and_rejects_restart(
    tmp_path: Path,
) -> None:
    stable_counter = tmp_path / "stable-counter"
    stable_counter.write_text("0")
    stable = _run_library_script(
        """
counter=$1
compose() {
    printf '%s\n' dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
}
docker() { printf '%s\n' 'true false 0'; }
sleep() { :; }
wait_for_beat_stability 3 1
""",
        stable_counter,
    )
    assert stable.returncode == 0, stable.stderr

    counter = tmp_path / "counter"
    counter.write_text("0")
    restarted = _run_library_script(
        """
counter=$1
compose() {
    printf '%s\n' dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
}
docker() {
    count=$(cat "$counter")
    count=$((count + 1))
    printf '%s\n' "$count" >"$counter"
    if [ "$count" -ge 2 ]; then
        printf '%s\n' 'true false 1'
    else
        printf '%s\n' 'true false 0'
    fi
}
sleep() { :; }
wait_for_beat_stability 3 1
""",
        counter,
    )
    assert restarted.returncode != 0
    deploy = DEPLOY.read_text()
    assert deploy.index("--force-recreate beat") < deploy.index(
        "wait_for_beat_stability"
    )
    assert deploy.index("wait_for_beat_stability") < deploy.index(
        'activate_release "$release" /opt/ladle/current'
    )


def test_beat_stability_gate_rejects_unbounded_settings() -> None:
    mock_commands = """
compose() {
    printf '%s\n' dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
}
docker() { printf '%s\n' 'true false 0'; }
sleep() { :; }
"""
    for checks, interval in ((2, 2), (21, 2), (3, 0), (3, 31)):
        result = _run_library_script(
            f"{mock_commands}\nwait_for_beat_stability {checks} {interval}\n"
        )
        assert result.returncode != 0, (checks, interval)
