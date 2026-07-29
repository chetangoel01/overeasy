import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import pytest
import yaml

BACKEND = Path(__file__).parents[3]
PROFILE = BACKEND / "deploy" / "vps" / "docker-compose.yml"
GATEWAY = PROFILE.parent / "gateway"
GATEWAY_PROFILE = GATEWAY / "docker-compose.yml"
GATEWAY_CADDYFILE = GATEWAY / "Caddyfile"
GATEWAY_LADLE_ROUTE = GATEWAY / "routes" / "ladle.caddy"
GATEWAY_MANAGE = GATEWAY / "manage.sh"
PROVISION = PROFILE.parent / "provision.sh"
HARDEN_SSH = PROFILE.parent / "harden-ssh.sh"
DOCKER_USER_RULES = PROFILE.parent / "ladle-docker-user.rules"
HOST_VALIDATION = PROFILE.parent / "host-validation.sh"
PUSH = PROFILE.parent / "push.sh"
DEPLOY = PROFILE.parent / "deploy.sh"
INITIALIZE_ENV = PROFILE.parent / "initialize-env.sh"
SET_SECRET = PROFILE.parent / "set-secret.sh"
DEPLOYMENT_LIB = PROFILE.parent / "deployment-lib.sh"
OPERATIONS = PROFILE.parent / "operations.sh"
OPERATIONS_LAUNCHER = PROFILE.parent / "operations-launcher.sh"
INSTALL_OPERATIONS = PROFILE.parent / "install-operations.sh"
HEALTH_SERVICE = PROFILE.parent / "ladle-health.service"
HEALTH_TIMER = PROFILE.parent / "ladle-health.timer"
BACKUP_SERVICE = PROFILE.parent / "ladle-backup.service"
BACKUP_TIMER = PROFILE.parent / "ladle-backup.timer"
PROGRESS_LOG = "/var/log/ladle/setup.log"
RUNBOOK = BACKEND / "docs" / "deployment" / "vps.md"
BACKEND_README = BACKEND / "README.md"
ROOT_README = BACKEND.parent / "README.md"

EXPECTED_SERVICES = {
    "postgres",
    "redis",
    "minio",
    "minio-init",
    "edge",
    "migrate",
    "api",
    "worker-egress",
    "worker",
    "beat",
}


def test_vps_runbook_documents_staging_recovery_and_production_gates() -> None:
    assert RUNBOOK.exists(), "missing VPS runbook"
    runbook = RUNBOOK.read_text()
    lowered = runbook.casefold()

    for required in (
        "vps-8b0be574.vps.ovh.us",
        "135.148.42.60",
        "2604:2dc0:121::64f",
        "ubuntu 26.04",
        "fresh empty",
        "one-time password",
        "ovh kvm",
        "host-key fingerprint",
        "ssh-keygen",
        "ssh-copy-id",
        "preferredauthentications=publickey",
        "passwordauthentication=no",
        "api.ladle.app a    135.148.42.60",
        "api.ladle.app aaaa 2604:2dc0:121::64f",
        "standard input",
        "set-secret.sh ladle_openrouter_api_key",
        "./deploy/vps/push.sh ubuntu@135.148.42.60",
        "sudo ladle-operations status",
        "sudo ladle-operations logs",
        "sudo ladle-operations backup",
        "sudo tail -f /var/log/ladle/setup.log",
        "pg_restore",
        "postgres:16",
        "rollback",
        "key rotation",
        "systemd-analyze verify",
        "ladle_environment=development",
        "external postgresql restore",
        "off-host object state",
        "tls-credentialed postgresql and redis",
        "apple sign-in",
        "google sign-in",
        "app attest",
        "tracing",
        "real-device",
        "remove the staging gate",
        (
            "./deploy/vps/push.sh ubuntu@135.148.42.60 "
            "vps-8b0be574.vps.ovh.us"
        ),
    ):
        assert required in lowered

    assert "ovh snapshots are not database-aware backups" in lowered
    assert "--staging-access-key-file" in runbook
    assert '< "$PROVIDER_SECRET_FILE"' in runbook
    assert '> "$STAGING_KEY_TEMP"' in runbook
    assert "never prints the key" in lowered
    assert "fixed, sanitized phases" in lowered
    assert "never stream secrets or environment values" in lowered
    assert "keep the staging gate" in lowered
    assert "preferredauthentications=password" in lowered
    assert "pubkeyauthentication=no" in lowered
    assert "keep this password-authenticated session a open" in lowered
    assert "pg_restore --exit-on-error --no-owner --no-privileges" in lowered
    prose = " ".join(lowered.replace("`", "").split())
    assert "systemd-analyze is unavailable in the macos workspace" in prose
    assert "local tests do not validate real systemd unit syntax" in prose
    assert "ubuntu-side systemd-analyze verify" in prose
    assert (
        "after any reboot, reopen and retain a fresh password-authenticated session a"
    ) in prose
    assert "then prove a separate key-only session b" in prose
    assert lowered.count("preferredauthentications=password") >= 2
    assert "remove exactly its single trailing cr/lf" in prose
    assert "staging_key_temp" in lowered
    assert "perl -0pe" in lowered
    assert r"s/\r?\n\z//" in runbook

    initial_operations = lowered.split("after the first successful push", maxsplit=1)[
        1
    ].split("## retrieve the staging key", maxsplit=1)[0]
    assert "synchronously runs\n`ladle-backup.service`" in initial_operations
    assert "requires a validated backup" in initial_operations
    assert "health timer last" in initial_operations
    assert initial_operations.index("sudo ladle-operations health") < (
        initial_operations.index("sudo ladle-operations backup")
    )

    key_rotation = lowered.split("## ssh key rotation", maxsplit=1)[1].split(
        "## production promotion blockers", maxsplit=1
    )[0]
    new_default_identity = key_rotation.index(
        "identityfile ~/.ssh/ladle-ovh-staging-next"
    )
    ordinary_login = key_rotation.index("ssh ubuntu@135.148.42.60")
    old_key_removal = key_rotation.index("${editor:-vi} ~/.ssh/authorized_keys")
    assert new_default_identity < ordinary_login < old_key_removal
    server_fingerprints = key_rotation.index(
        "ssh-keygen -lf ~/.ssh/authorized_keys -e sha256", old_key_removal
    )
    ordinary_new_key = key_rotation.index(
        "ssh ubuntu@135.148.42.60 true", server_fingerprints
    )
    assert old_key_removal < server_fingerprints < ordinary_new_key
    post_removal = key_rotation[old_key_removal:]
    for required in (
        "self-contained",
        "separate terminal",
        'old_ssh_key="$home/.ssh/ladle-ovh-staging"',
        'new_ssh_key="$home/.ssh/ladle-ovh-staging-next"',
        'old_key_fingerprint=$(public_key_fingerprint "$old_ssh_key.pub")',
        'new_key_fingerprint=$(public_key_fingerprint "$new_ssh_key.pub")',
    ):
        assert required in post_removal
    assert post_removal.index("old_ssh_key=") < post_removal.index(
        "ssh-keygen -lf ~/.ssh/authorized_keys"
    )
    assert post_removal.index("new_ssh_key=") < post_removal.index(
        "ssh-keygen -lf ~/.ssh/authorized_keys"
    )
    assert key_rotation.count("(\n  set -eu\n  set -o pipefail") >= 2
    assert ': "${old_key_fingerprint:?' not in key_rotation
    assert ': "${new_key_fingerprint:?' not in key_rotation
    for required in (
        'ssh-keygen -lf "$1" -e sha256',
        'public_key_fingerprint "$old_ssh_key.pub"',
        'public_key_fingerprint "$new_ssh_key.pub"',
        "old_key_fingerprint",
        "new_key_fingerprint",
        "authorized_key_fingerprints",
        "cleanup_authorized_key_fingerprints",
        "trap cleanup_authorized_key_fingerprints 0",
        "trap 'exit 1' hup int term",
        'test -s "$authorized_key_fingerprints"',
        "grep -fxc --",
        "old fingerprint remains authorized",
        "new fingerprint is absent or duplicated",
        "keep both recovery sessions open",
    ):
        assert required in key_rotation
    assert "-f /dev/null" not in key_rotation
    assert "permission denied (publickey)" not in key_rotation

    restore_drill = lowered.split(
        "## empty-server postgresql 16 restore drill", maxsplit=1
    )[1].split("## deterministic rollback", maxsplit=1)[0]
    for required in (
        "sudo sh -eu -s",
        "created=false",
        "trap cleanup 0",
        "trap 'exit 1' hup int term",
        "refusing stale ladle-restore-drill container",
        'while [ "$attempt" -le 60 ]',
        "--no-owner --no-privileges",
    ):
        assert required in restore_drill
    stale_guard = restore_drill.index('if docker container inspect "$container"')
    assert restore_drill.index("trap cleanup") < stale_guard
    assert stale_guard < restore_drill.index("docker run")

    bootstrap = lowered.split(
        "transfer only the committed bootstrap inputs", maxsplit=1
    )[1].split("if ubuntu reports that a reboot is required", maxsplit=1)[0]
    for required in (
        "git status --porcelain --untracked-files=all",
        "git rev-parse --verify head^{commit}",
        "bootstrap_revision",
        "bootstrap_dir",
        "persistent owner-only per-revision bootstrap directory",
        "/home/ubuntu/.ladle-vps-bootstrap-$bootstrap_revision",
        "stat -c '%u:%a'",
    ):
        assert required in bootstrap
    assert bootstrap.index("git status --porcelain") < bootstrap.index("scp")
    assert bootstrap.index("git rev-parse") < bootstrap.index("scp")
    assert "/tmp/ladle-vps-bootstrap" not in lowered
    assert lowered.count("/home/ubuntu/.ladle-vps-bootstrap-$bootstrap_revision") >= 3

    assert "all commands are bounded" not in lowered
    assert "status and log output are bounded" in prose
    assert "scheduled units enforce systemd timeouts" in prose
    assert "direct health and backup calls bypass those systemd timeouts" in prose
    assert "every deployment runs the operations refresh step" in prose
    assert "current symlink authorizes operations dispatch" in prose
    assert "pinned release handoff fails closed" in prose
    assert "before transition logging or backup lock acquisition" in prose
    assert "blocking shared authority lock" in prose
    assert "separate deployment lock" in prose
    assert "fresh provisioning creates authority.lock" in prose
    assert "before any compose or deployment-state mutation" in prose
    assert "device, inode, owner, and mode" in prose
    assert "two-minute health service timeout" in prose
    gateway_plan = " ".join(
        (
            BACKEND.parent / "docs/plans/2026-07-29-shared-vps-gateway.md"
        )
        .read_text()
        .casefold()
        .replace("`", "")
        .split()
    )
    assert (
        "gateway prepare creates and validates "
        "/var/lib/ladle/locks/authority.lock before pushing the detached release"
    ) in gateway_plan

    forbidden_credentials = (
        "secret-retrieve",
        "BEGIN OPENSSH PRIVATE KEY",
        "BEGIN PRIVATE KEY",
        "AKIA",
        "sk-",
    )
    assert not any(marker in runbook for marker in forbidden_credentials)
    assert re.search(r"\b[0-9a-f]{48,}\b", lowered) is None

    expected_link = "docs/deployment/vps.md"
    assert expected_link in BACKEND_README.read_text()
    assert "Backend/docs/deployment/vps.md" in ROOT_README.read_text()


def test_vps_runbook_configures_assigned_ovh_ipv6_before_provisioning() -> None:
    runbook = RUNBOOK.read_text()
    ipv6_setup = runbook.index("51-ladle-ipv6.yaml")
    provision = runbook.index('sudo "$BOOTSTRAP_DIR/provision.sh"')

    assert "2604:2dc0:121::64f/128" in runbook
    assert "2604:2dc0:121::1" in runbook
    assert "sudo netplan generate" in runbook
    assert "sudo netplan apply" in runbook
    assert "ping -6 -c 2 2606:4700:4700::1111" in runbook
    assert "while ip -6 address show dev ens3 | grep -q tentative" in runbook
    assert "dadfailed" in runbook
    assert runbook.index("grep -q tentative") < runbook.index(
        "ping -6 -c 2 2606:4700:4700::1111"
    )
    assert ipv6_setup < provision


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


def _gateway_profile() -> dict[str, Any]:
    loaded = yaml.load(GATEWAY_PROFILE.read_text(), Loader=ComposeLoader)
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


def _run_operations_library(
    script: str,
    *arguments: str | Path,
    env: dict[str, str] | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "/bin/sh",
            "-c",
            f'. "$1"; shift; {script}',
            "test",
            str(OPERATIONS),
            *(str(argument) for argument in arguments),
        ],
        check=False,
        capture_output=True,
        env={**os.environ, **(env or {})},
        text=True,
        timeout=timeout,
    )


def _run_installer_library(
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
            str(INSTALL_OPERATIONS),
            *(str(argument) for argument in arguments),
        ],
        check=False,
        capture_output=True,
        env={**os.environ, **(env or {})},
        text=True,
    )


def _write_launcher_stat(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import os
import stat
import sys

target = sys.argv[-1]
if target == "/proc/self/fd/7":
    if os.environ.get("FAIL_AUTHORITY_FD_STAT") == "1":
        raise SystemExit(1)
    metadata = os.fstat(7)
else:
    metadata = os.lstat(target)
uid = metadata.st_uid
wrong_owner_paths = os.environ.get("WRONG_OWNER_PATHS", "").split(os.pathsep)
if target in wrong_owner_paths:
    uid += 1
mode = stat.S_IMODE(metadata.st_mode)
format_string = next(
    argument for argument in sys.argv[1:] if argument.startswith("%")
)
if format_string == "%u:%a":
    print(f"{uid}:{mode:o}")
elif format_string == "%d:%i:%u:%a":
    print(f"{metadata.st_dev}:{metadata.st_ino}:{uid}:{mode:o}")
else:
    raise SystemExit("unsupported stat format")
replacement = os.environ.get("AUTHORITY_REPLACEMENT_BEFORE_OPEN")
authority_lock = os.environ.get("AUTHORITY_LOCK_PATH")
if (
    target == authority_lock
    and replacement
    and os.path.exists(replacement)
):
    os.replace(replacement, target)
"""
    )
    path.chmod(0o755)


def _write_test_operations_launcher(
    tmp_path: Path,
    current: Path,
    releases: Path,
    *,
    authority_lock: Path | None = None,
    create_authority_lock: bool = True,
    deployment_lock: Path | None = None,
    create_deployment_lock: bool = True,
    mark_before_current_selection: bool = False,
    pause_before_exec: bool = False,
) -> Path:
    fake_bin = tmp_path / "launcher-bin"
    fake_bin.mkdir(exist_ok=True)
    _write_launcher_stat(fake_bin / "stat")
    _write_fake_flock(fake_bin / "flock")
    if authority_lock is None:
        authority_lock = tmp_path / "authority.lock"
    if create_authority_lock:
        authority_lock.touch()
        authority_lock.chmod(0o600)
    if deployment_lock is None:
        deployment_lock = tmp_path / "deploy.lock"
    if create_deployment_lock:
        deployment_lock.touch()
        deployment_lock.chmod(0o600)
    launcher = tmp_path / "ladle-operations"
    launcher_source = OPERATIONS_LAUNCHER.read_text()
    replacements = {
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin": (
            f"PATH={shlex.quote(str(fake_bin))}:"
            "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ),
        "current_release=/opt/ladle/current": (
            f"current_release={shlex.quote(str(current))}"
        ),
        "releases_directory=/opt/ladle/releases": (
            f"releases_directory={shlex.quote(str(releases))}"
        ),
        "authority_lock=/var/lib/ladle/locks/authority.lock": (
            f"authority_lock={shlex.quote(str(authority_lock))}"
        ),
        "deployment_lock=/var/lib/ladle/locks/deploy.lock": (
            f"deployment_lock={shlex.quote(str(deployment_lock))}"
        ),
        "trusted_uid=0": f"trusted_uid={os.getuid()}",
    }
    for original, replacement in replacements.items():
        if original in launcher_source:
            launcher_source = launcher_source.replace(original, replacement, 1)
        elif original.startswith(("authority_lock=", "deployment_lock=")):
            launcher_source = launcher_source.replace(
                "trusted_uid=0",
                f"trusted_uid=0\n{replacement}",
                1,
            )
        else:
            raise AssertionError(f"missing launcher setting: {original}")
    if mark_before_current_selection:
        launch_line = "launch_active_operations() {"
        assert launch_line in launcher_source
        launcher_source = launcher_source.replace(
            launch_line,
            '''launch_active_operations() {
    : >"$LAUNCHER_STARTED"
    launcher_start_attempt=0
    while [ ! -e "$LAUNCHER_CONTINUE" ]; do
        launcher_start_attempt=$((launcher_start_attempt + 1))
        [ "$launcher_start_attempt" -le 500 ] || launcher_fail
        sleep 0.01
    done
    : >"$LAUNCHER_CONTINUED"''',
            1,
        )
        lock_line = "    acquire_operations_authority_lock"
        assert lock_line in launcher_source
        launcher_source = launcher_source.replace(
            lock_line,
            f"""    : >"$LAUNCHER_PRELOCK"
    launcher_prelock_attempt=0
    while [ ! -e "$LAUNCHER_PRELOCK_CONTINUE" ]; do
        launcher_prelock_attempt=$((launcher_prelock_attempt + 1))
        [ "$launcher_prelock_attempt" -le 500 ] || launcher_fail
        sleep 0.01
    done
{lock_line}""",
            1,
        )
        selection_line = '    [ -L "$current_release" ] || launcher_fail'
        assert selection_line in launcher_source
        launcher_source = launcher_source.replace(
            selection_line,
            f"""    : >"$LAUNCHER_SELECTING"
    launcher_selection_attempt=0
    while [ ! -e "$LAUNCHER_SELECTION_RESUME" ]; do
        launcher_selection_attempt=$((launcher_selection_attempt + 1))
        [ "$launcher_selection_attempt" -le 500 ] || launcher_fail
        sleep 0.01
    done
{selection_line}""",
            1,
        )
    if pause_before_exec:
        exec_line = '    exec "$operations_script" "$@"'
        assert exec_line in launcher_source
        launcher_source = launcher_source.replace(
            exec_line,
            '''    : >"$LAUNCHER_SELECTED"
    pause_attempt=0
    while [ ! -e "$LAUNCHER_RESUME" ]; do
        pause_attempt=$((pause_attempt + 1))
        [ "$pause_attempt" -le 500 ] || launcher_fail
        sleep 0.01
    done
    exec "$operations_script" "$@"''',
            1,
        )
    launcher.write_text(launcher_source)
    launcher.chmod(0o755)
    return launcher


def _write_operations_release(
    releases: Path,
    revision: str,
    label: str,
) -> tuple[Path, Path, Path]:
    release = releases / revision
    operations = release / "Backend" / "deploy" / "vps" / "operations.sh"
    operations.parent.mkdir(parents=True)
    operations.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' "
        f"\"{label}:${{LADLE_OPERATIONS_EXPECTED_RELEASE:-missing}}:$*\" "
        ">>\"$LAUNCH_TRACE\"\n"
    )
    operations.chmod(0o755)
    marker = release / ".ladle-revision"
    marker.write_text(f"{revision}\n")
    marker.chmod(0o444)
    release.chmod(0o755)
    return release, marker, operations


def _write_guarded_operations_release(
    releases: Path,
    revision: str,
    label: str,
    current: Path,
    deployment_state: Path,
) -> tuple[Path, Path]:
    release = releases / revision
    operations = release / "Backend" / "deploy" / "vps" / "operations.sh"
    operations.parent.mkdir(parents=True)
    operations_source = OPERATIONS.read_text().rsplit(
        "\ncase ${0##*/} in",
        maxsplit=1,
    )[0]
    operations_source = operations_source.replace(
        '"/opt/ladle/releases/$revision"',
        '"$releases_directory/$revision"',
    )
    operations.write_text(
        f"""{operations_source}
current_release={shlex.quote(str(current))}
deployment_state={shlex.quote(str(deployment_state))}
releases_directory={shlex.quote(str(releases))}
safe_regular_file() {{ [ -f "$1" ] && [ ! -L "$1" ]; }}
safe_directory() {{ [ -d "$1" ] && [ ! -L "$1" ]; }}
validate_runtime_paths() {{ runtime_paths_ready=true; }}
id() {{ printf '%s\\n' 0; }}
trace_mutation() {{ printf '%s\\n' "$*" >>"$MUTATION_TRACE"; }}
log_transition() {{ trace_mutation "log:$*"; }}
acquire_deployment_lock() {{
    trace_mutation lock-open
    trace_mutation lock-acquire
}}
remove_incomplete_backup_pairs() {{ trace_mutation remove-incomplete; }}
cleanup_backup() {{ trace_mutation cleanup; }}
rm() {{ trace_mutation "rm:$*"; return 1; }}
mktemp() {{ trace_mutation "mktemp:$*"; return 1; }}
mv() {{ trace_mutation "mv:$*"; return 1; }}
check_containers() {{
    trace_mutation health-check
    [ "${{HEALTH_FAIL_AFTER_AUTHORITY:-0}}" != 1 ] ||
        append_failure "forced health failure"
}}
check_nginx() {{ :; }}
check_api() {{ :; }}
check_worker() {{ :; }}
check_postgres() {{
    trace_mutation backup-health-check
    [ "${{BACKUP_FAIL_AFTER_AUTHORITY:-0}}" != 1 ] ||
        append_failure "forced backup failure"
}}
check_redis() {{ :; }}
check_minio() {{ :; }}
check_certificate() {{ :; }}
check_backup_freshness() {{ :; }}
systemctl() {{ return "${{SYSTEMCTL_STATUS:-0}}"; }}
journalctl() {{ :; }}
compose() {{
    printf '%s\\n' "{label}:$backend_directory:$*" >>"$MUTATION_TRACE"
}}
gate_state_read() {{
    [ -n "${{STATE_READ_SELECTED:-}}" ] || return 0
    [ ! -e "$STATE_READ_SELECTED" ] || return 0
    : >"$STATE_READ_SELECTED"
    gate_attempt=0
    while [ ! -e "$STATE_READ_RESUME" ]; do
        gate_attempt=$((gate_attempt + 1))
        [ "$gate_attempt" -le 500 ] || return 1
        sleep 0.01
    done
}}
wc() {{ command wc "$@"; gate_state_read; }}
cat() {{
    command cat "$@"
    [ "${{1:-}}" != "$deployment_state" ] || gate_state_read
}}
operations_main "$@"
"""
    )
    operations.chmod(0o755)
    marker = release / ".ladle-revision"
    marker.write_text(f"{revision}\n")
    marker.chmod(0o444)
    (release / "Backend" / "docker-compose.yml").write_text("services: {}\n")
    (release / "Backend" / "deploy" / "vps" / "docker-compose.yml").write_text(
        "services: {}\n"
    )
    release.chmod(0o755)
    return release, operations


def _write_active_deployment_state(path: Path, revision: str) -> None:
    replacement = path.with_name(f"{path.name}.next")
    replacement.write_text(
        f"STATUS=active\nREVISION={revision}\nPHASE=complete\n"
    )
    replacement.chmod(0o644)
    os.replace(replacement, path)


def _activate_test_release(
    current: Path,
    deployment_state: Path,
    release: Path,
) -> None:
    revision = release.name
    _write_active_deployment_state(deployment_state, revision)
    replacement = current.with_name(f"{current.name}.next")
    replacement.symlink_to(release)
    os.replace(replacement, current)


def _run_launcher(
    launcher: Path,
    trace: Path,
    *arguments: str,
    wrong_owner_paths: tuple[Path, ...] = (),
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(launcher), *arguments],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "LAUNCH_TRACE": str(trace),
            "WRONG_OWNER_PATHS": os.pathsep.join(map(str, wrong_owner_paths)),
            **(env or {}),
        },
        text=True,
    )


def _wait_for_path(
    path: Path,
    *,
    process: subprocess.Popen[str] | None = None,
    timeout: float = 5,
) -> None:
    deadline = time.monotonic() + timeout
    while (
        not path.exists()
        and (process is None or process.poll() is None)
        and time.monotonic() < deadline
    ):
        time.sleep(0.01)
    assert path.exists(), f"timed out waiting for {path}"


def _run_release_operations(
    operations: Path,
    mutation_trace: Path,
    *arguments: str,
    expected_release: str | None,
) -> subprocess.CompletedProcess[str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if key != "LADLE_OPERATIONS_EXPECTED_RELEASE"
    }
    environment["MUTATION_TRACE"] = str(mutation_trace)
    if expected_release is not None:
        environment["LADLE_OPERATIONS_EXPECTED_RELEASE"] = expected_release
    return subprocess.run(
        [str(operations), *arguments],
        check=False,
        capture_output=True,
        env=environment,
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
import os
import sys

arguments = sys.argv[1:]
nonblocking = "-n" in arguments
shared = "-s" in arguments
descriptor = int(arguments[-1])
operation = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
operation |= fcntl.LOCK_NB if nonblocking else 0
try:
    fcntl.flock(descriptor, operation)
except BlockingIOError:
    raise SystemExit(1)
replacement = os.environ.get("AUTHORITY_REPLACEMENT_AFTER_OPEN")
authority_lock = os.environ.get("AUTHORITY_LOCK_PATH")
if descriptor == 7 and replacement and os.path.exists(replacement):
    os.replace(replacement, authority_lock)
"""
    )
    path.chmod(0o755)


def _write_operations_installer_fakes(path: Path) -> None:
    path.mkdir()
    (path / "install").write_text(
        """#!/usr/bin/env python3
import os
import shutil
import sys

arguments = sys.argv[1:]
mode = int(arguments[arguments.index("-m") + 1], 8)
source, target = arguments[-2:]
if os.environ.get("FAIL_PHASE") == "stage" and not os.environ.get(
    "STAGE_FAILURE_USED"
):
    marker = os.environ["FAKE_STATE"] + ".stage"
    if not os.path.exists(marker):
        open(marker, "w").close()
        raise SystemExit(1)
shutil.copyfile(source, target)
os.chmod(target, mode)
"""
    )
    (path / "stat").write_text(
        """#!/usr/bin/env python3
import os
import stat
import sys

target = sys.argv[-1]
metadata = os.stat(target, follow_symlinks=False)
mode = stat.S_IMODE(metadata.st_mode)
format_string = sys.argv[2]
if format_string == "%u:%a":
    print(f"{metadata.st_uid}:{mode:o}")
elif format_string == "%u:%g:%a":
    print(f"{metadata.st_uid}:{metadata.st_gid}:{mode:o}")
else:
    raise SystemExit(f"unsupported stat format: {format_string}")
"""
    )
    (path / "mv").write_text(
        """#!/usr/bin/env python3
import os
import sys
import time

source, target = sys.argv[-2:]
marker = os.environ["FAKE_STATE"] + ".swap"
if (
    os.environ.get("FAIL_PHASE")
    in {"swap", "restore", "stage_cleanup", "remove_new_target"}
    and ".ladle-stage." in os.path.basename(source)
    and os.path.basename(target) == "ladle-health.service"
    and not os.path.exists(marker)
):
    open(marker, "w").close()
    raise SystemExit(1)
if (
    os.environ.get("PAUSE_SWAP") == "1"
    and ".ladle-stage." in os.path.basename(source)
    and os.path.basename(target) == "ladle-health.service"
):
    open(os.environ["FAKE_STATE"] + ".signal", "w").close()
    time.sleep(30)
if (
    os.environ.get("FAIL_PHASE") == "restore"
    and ".ladle-backup." in os.path.basename(source)
    and os.path.basename(target) == "ladle-operations"
):
    raise SystemExit(1)
if (
    os.environ.get("PAUSE_ROLLBACK") == "1"
    and ".ladle-backup." in os.path.basename(source)
    and os.path.basename(target) == "ladle-operations"
    and not os.path.exists(os.environ["FAKE_STATE"] + ".rollback")
):
    open(os.environ["FAKE_STATE"] + ".rollback", "w").close()
    time.sleep(2)
os.replace(source, target)
"""
    )
    (path / "rm").write_text(
        """#!/usr/bin/env python3
import os
import subprocess
import sys

if os.environ.get("FAIL_PHASE") in {"cleanup", "commit_signal_cleanup"} and any(
    ".ladle-backup." in argument for argument in sys.argv[1:]
):
    if os.environ.get("FAIL_PHASE") == "commit_signal_cleanup":
        marker = os.environ["FAKE_STATE"] + ".committed-cleanup"
        if not os.path.exists(marker):
            open(marker, "w").close()
            import time
            time.sleep(30)
    raise SystemExit(1)
if os.environ.get("FAIL_PHASE") == "stage_cleanup" and any(
    ".ladle-stage." in argument for argument in sys.argv[1:]
):
    raise SystemExit(1)
if (
    os.environ.get("FAIL_PHASE") == "remove_new_target"
    and os.path.basename(sys.argv[-1]) == "ladle-operations"
):
    raise SystemExit(1)
raise SystemExit(subprocess.run(["/bin/rm", *sys.argv[1:]], check=False).returncode)
"""
    )
    (path / "systemd-analyze").write_text(
        """#!/bin/sh
[ "${FAIL_PHASE:-}" != verify ]
"""
    )
    (path / "systemctl").write_text(
        """#!/usr/bin/env python3
import os
import sys

command = sys.argv[1]
state = os.environ["FAKE_STATE"]
with open(state, "a") as trace:
    trace.write(" ".join(sys.argv[1:]) + "\\n")
if command in {"is-enabled", "is-active"}:
    if os.environ.get("QUERY_FAILURE") == "1":
        print("Failed to query unit state", file=sys.stderr)
        raise SystemExit(1)
    if os.environ.get("TIMERS_NOT_FOUND") == "1":
        print("not-found" if command == "is-enabled" else "unknown")
        raise SystemExit(4)
    previous_active = os.environ.get("PREVIOUS_TIMERS_ACTIVE") == "1"
    if command == "is-enabled":
        print("enabled" if previous_active else "disabled")
        raise SystemExit(0 if previous_active else 1)
    print("active" if previous_active else "inactive")
    raise SystemExit(0 if previous_active else 3)
if (
    command == "disable"
    and os.environ.get("ROLLBACK_FAILURE") == "disable"
):
    raise SystemExit(1)
if command == "daemon-reload" and os.environ.get("FAIL_PHASE") == "daemon":
    marker = state + ".daemon"
    if not os.path.exists(marker):
        open(marker, "w").close()
        raise SystemExit(1)
if (
    command == "daemon-reload"
    and os.environ.get("ROLLBACK_FAILURE") == "reload"
    and open(state).read().splitlines().count("daemon-reload") >= 2
):
    raise SystemExit(1)
if (
    command == "enable"
    and os.environ.get("FAIL_PHASE") == "enable"
    and len(sys.argv[2:]) == 2
):
    raise SystemExit(1)
if (
    command == "enable"
    and os.environ.get("ROLLBACK_FAILURE") == "enable"
    and len(sys.argv[2:]) == 1
):
    raise SystemExit(1)
if (
    command == "start"
    and os.environ.get("FAIL_PHASE") == "start"
    and "ladle-health.timer" in sys.argv[2:]
    and not os.path.exists(state + ".activation-start")
):
    open(state + ".activation-start", "w").close()
    raise SystemExit(1)
if (
    command == "start"
    and os.environ.get("FAIL_PHASE") == "initial_backup"
    and sys.argv[2:] == ["ladle-backup.service"]
):
    raise SystemExit(1)
if (
    command == "start"
    and os.environ.get("ROLLBACK_FAILURE") == "start"
    and len(sys.argv[2:]) == 1
):
    raise SystemExit(1)
"""
    )
    for fake in path.iterdir():
        fake.chmod(0o755)


def _operations_installer_fixture(
    tmp_path: Path,
    *,
    preexisting: bool,
) -> tuple[Path, Path, Path, tuple[Path, ...], Path, Path]:
    source = tmp_path / "source"
    source.mkdir()
    binary_source = source / "operations-launcher.sh"
    binary_source.write_text("#!/bin/sh\nprintf '%s\\n' new-launcher\n")
    binary_source.chmod(0o755)
    unit_names = (
        "ladle-health.service",
        "ladle-health.timer",
        "ladle-backup.service",
        "ladle-backup.timer",
    )
    for name in unit_names:
        (source / name).write_text(f"[Unit]\nDescription=new {name}\n")
    binary_dir = tmp_path / "sbin"
    unit_dir = tmp_path / "systemd"
    binary_dir.mkdir()
    unit_dir.mkdir()
    binary_target = binary_dir / "ladle-operations"
    targets = (binary_target, *(unit_dir / name for name in unit_names))
    if preexisting:
        for target in targets:
            target.write_text(f"old:{target.name}\n")
            target.chmod(0o755 if target == binary_target else 0o644)
    fake_bin = tmp_path / "bin"
    _write_operations_installer_fakes(fake_bin)
    return (
        source,
        binary_target,
        unit_dir,
        targets,
        fake_bin,
        tmp_path / "systemctl.trace",
    )


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


def _valid_platform_network(
    containers: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "driver": "bridge",
        "scope": "local",
        "internal": False,
        "subnets": ["172.30.0.0/24"],
        "label": "shared-edge-v1",
        "containers": containers or [],
    }


def _write_fake_platform_docker(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys

state_path = os.environ["FAKE_DOCKER_STATE"]
with open(state_path) as source:
    state = json.load(source)
arguments = sys.argv[1:]

def save():
    with open(state_path, "w") as target:
        json.dump(state, target)

if arguments[:2] == ["network", "inspect"]:
    network = state.get("network")
    if network is None:
        raise SystemExit(1)
    template = arguments[arguments.index("--format") + 1]
    if ".Driver" in template:
        print(network["driver"])
        print(network["scope"])
        print(str(network["internal"]).lower())
        print(len(network["subnets"]))
        for subnet in network["subnets"]:
            print(subnet)
        print(network["label"])
    elif ".Containers" in template:
        for container in network["containers"]:
            print(container["id"])
    else:
        raise SystemExit("unsupported network format")
elif arguments[:2] == ["network", "create"]:
    expected = [
        "network",
        "create",
        "--driver",
        "bridge",
        "--subnet",
        "172.30.0.0/24",
        "--label",
        "com.ladle.platform.network=shared-edge-v1",
        "platform-edge",
    ]
    if arguments != expected:
        raise SystemExit("unexpected create contract")
    state["create_calls"] = state.get("create_calls", 0) + 1
    mode = state["create_mode"]
    if mode in {"success", "race_valid"}:
        state["network"] = {
            "driver": "bridge",
            "scope": "local",
            "internal": False,
            "subnets": ["172.30.0.0/24"],
            "label": "shared-edge-v1",
            "containers": [],
        }
    elif mode == "fail_invalid":
        state["network"] = {
            "driver": "bridge",
            "scope": "local",
            "internal": False,
            "subnets": ["172.29.0.0/24"],
            "label": "foreign",
            "containers": [],
        }
    save()
    if mode == "success":
        print("platform-edge")
    else:
        raise SystemExit(1)
elif arguments[0] == "inspect":
    network = state.get("network")
    container_id = arguments[-1]
    container = next(
        item for item in network["containers"] if item["id"] == container_id
    )
    template = arguments[arguments.index("--format") + 1]
    if ".Aliases" in template:
        for alias in container["aliases"]:
            print(alias)
    elif "com.docker.compose.project" in template:
        print(container["project"])
        print(container["service"])
    else:
        raise SystemExit("unsupported container format")
else:
    raise SystemExit("unsupported docker command")
"""
    )
    path.chmod(0o755)


def _run_platform_network_function(
    tmp_path: Path,
    function: str,
    state: dict[str, object],
) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_platform_docker(fake_bin / "docker")
    state_path = tmp_path / "docker-state.json"
    state_path.write_text(json.dumps(state))
    result = subprocess.run(
        [
            "/bin/sh",
            "-c",
            '. "$1"; shift; '
            f'{function} || {{ printf "%s\\n" "$PLATFORM_NETWORK_ERROR" >&2; '
            "exit 1; }",
            "test",
            str(HOST_VALIDATION),
        ],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "FAKE_DOCKER_STATE": str(state_path),
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
        },
        text=True,
    )
    loaded = json.loads(state_path.read_text())
    assert isinstance(loaded, dict)
    return result, loaded


def test_vps_profile_files_exist() -> None:
    assert PROFILE.is_file()


def test_gateway_assets_exist() -> None:
    assert GATEWAY_PROFILE.is_file()
    assert GATEWAY_CADDYFILE.is_file()
    assert GATEWAY_LADLE_ROUTE.is_file()


def test_gateway_profile_exposes_only_a_hardened_shared_tls_edge() -> None:
    profile_text = GATEWAY_PROFILE.read_text()
    profile = _gateway_profile()

    assert set(profile["services"]) == {"gateway"}
    gateway = profile["services"]["gateway"]
    assert gateway["ports"] == ["80:80", "443:443", "443:443/udp"]
    assert re.fullmatch(
        r"caddy:[^@]+@sha256:[0-9a-f]{64}",
        gateway["image"],
    )
    assert gateway["networks"] == ["platform-edge"]
    assert profile["networks"] == {"platform-edge": {"external": True}}
    assert gateway["logging"] == {
        "driver": "json-file",
        "options": {"max-size": "10m", "max-file": 3},
    }
    assert gateway["cpus"] > 0
    assert _memory_mib(gateway["mem_limit"]) > 0
    assert gateway["pids_limit"] > 0
    assert gateway["read_only"] is True
    assert gateway["cap_drop"] == ["ALL"]
    assert gateway["cap_add"] == ["NET_BIND_SERVICE"]
    assert gateway["security_opt"] == ["no-new-privileges:true"]
    assert gateway["volumes"] == [
        "./Caddyfile:/etc/caddy/Caddyfile:ro",
        "./routes:/etc/caddy/routes:ro",
        "gateway-caddy-data:/data",
        "gateway-caddy-config:/config",
    ]
    assert set(profile["volumes"]) == {
        "gateway-caddy-data",
        "gateway-caddy-config",
    }
    assert gateway["healthcheck"]["test"] == [
        "CMD",
        "caddy",
        "validate",
        "--config",
        "/etc/caddy/Caddyfile",
    ]
    assert "privileged: true" not in profile_text


def test_gateway_profile_requires_ladle_values_without_embedding_secrets() -> None:
    profile_text = GATEWAY_PROFILE.read_text()
    environment = _gateway_profile()["services"]["gateway"]["environment"]

    assert environment == {
        "LADLE_PUBLIC_HOSTNAME": (
            "${LADLE_PUBLIC_HOSTNAME:?set LADLE_PUBLIC_HOSTNAME}"
        ),
        "LADLE_TUNNEL_ACCESS_KEY": (
            "${LADLE_TUNNEL_ACCESS_KEY:?set LADLE_TUNNEL_ACCESS_KEY}"
        ),
    }
    assert "api.ladle.app" not in profile_text
    assert "tunnel123" not in profile_text


def test_gateway_caddy_imports_routes_and_preserves_ladle_access_controls() -> None:
    caddy = GATEWAY_CADDYFILE.read_text()
    route = GATEWAY_LADLE_ROUTE.read_text()

    assert "import /etc/caddy/routes/*.caddy" in caddy
    assert "{$LADLE_PUBLIC_HOSTNAME}" in route
    assert "@private path /ladle-private/*" in route
    assert "@authorized header X-Ladle-Tunnel-Key {$LADLE_TUNNEL_ACCESS_KEY}" in route
    assert "reverse_proxy @private ladle-edge:8082" in route
    assert "reverse_proxy @authorized ladle-edge:8082" in route
    assert "edge:8082" not in route.replace("ladle-edge:8082", "")
    assert (
        'header Strict-Transport-Security "max-age=63072000; '
        'includeSubDomains; preload"'
    ) in route
    assert route.index("header Strict-Transport-Security") < route.index(
        "@private path"
    )
    assert route.index("@private path") < route.index("@authorized header")
    assert route.index("@authorized header") < route.index("respond 404")
    assert route.count("header_up Host {http.request.host}") == 2
    assert "respond 404" in route


def test_vps_profile_publishes_no_host_ports() -> None:
    profile_text = PROFILE.read_text()
    services = _profile()["services"]

    assert set(services) == EXPECTED_SERVICES
    for name, service in services.items():
        assert service.get("ports", []) == [], name
    for name in ("api", "minio", "edge"):
        assert services[name]["ports"] == []
    assert profile_text.count("ports: !reset []") >= 3


def test_vps_profile_uses_pinned_reusable_edge_images() -> None:
    services = _profile()["services"]

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
    for name in ("postgres", "redis", "minio", "edge", "worker-egress"):
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


def test_vps_profile_uses_named_state_and_fixed_private_edge_addresses() -> None:
    profile = _profile()
    services = profile["services"]

    assert set(profile["volumes"]) == {
        "ladle-postgres",
        "ladle-redis",
        "ladle-minio",
    }
    assert services["postgres"]["volumes"] == [
        "ladle-postgres:/var/lib/postgresql/data"
    ]
    assert services["redis"]["volumes"] == ["ladle-redis:/data"]
    assert services["minio"]["volumes"] == ["ladle-minio:/data"]

    edge = profile["networks"]["edge"]
    assert edge["internal"] is True
    assert edge["ipam"]["config"] == [{"subnet": "172.31.0.0/24"}]
    expected_addresses = {
        "edge": "172.31.0.3",
        "api": "172.31.0.4",
        "minio": "172.31.0.5",
    }
    for name, address in expected_addresses.items():
        assert services[name]["networks"]["edge"]["ipv4_address"] == address


def test_only_ladle_edge_joins_the_shared_platform_network() -> None:
    profile = _profile()
    services = profile["services"]

    assert profile["networks"]["platform"] == {
        "external": True,
        "name": "platform-edge",
    }
    assert services["edge"]["networks"] == {
        "edge": {"ipv4_address": "172.31.0.3"},
        "platform": {"aliases": ["ladle-edge"]},
    }
    for name, service in services.items():
        if name != "edge":
            assert "platform" not in service.get("networks", {}), name


def test_vps_profile_requires_secrets_without_embedding_them() -> None:
    profile = PROFILE.read_text()

    assert "${LADLE_PUBLIC_HOSTNAME}" in profile
    for variable in (
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
    assert "!deploy/vps/Caddyfile" not in dockerignore
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


def test_vps_scripts_use_the_shared_platform_network_contract_before_mutation() -> None:
    provision = PROVISION.read_text()
    deploy = DEPLOY.read_text()

    docker_ready = provision.index("systemctl enable --now docker.service")
    ensure = provision.index("ensure_platform_network")
    network_gate = deploy.index("platform_network_is_valid")
    environment_validation = deploy.index("validate_env_metadata")
    compose_validation = deploy.index("compose config --quiet")
    first_service_mutation = deploy.index("compose up -d")

    assert docker_ready < ensure
    assert network_gate < environment_validation
    assert network_gate < compose_validation < first_service_mutation
    assert 'die "$PLATFORM_NETWORK_ERROR"' in provision
    assert 'die "$PLATFORM_NETWORK_ERROR"' in deploy


@pytest.mark.parametrize(
    "network",
    (
        {**_valid_platform_network(), "driver": "overlay"},
        {**_valid_platform_network(), "scope": "swarm"},
        {**_valid_platform_network(), "internal": True},
        {**_valid_platform_network(), "subnets": ["172.29.0.0/24"]},
        {
            **_valid_platform_network(),
            "subnets": ["172.30.0.0/24", "172.29.0.0/24"],
        },
        {**_valid_platform_network(), "label": "foreign"},
    ),
)
def test_platform_network_validation_rejects_malformed_contracts(
    tmp_path: Path,
    network: dict[str, object],
) -> None:
    result, _ = _run_platform_network_function(
        tmp_path,
        "platform_network_is_valid",
        {"network": network},
    )

    assert result.returncode != 0
    assert "required local bridge contract" in result.stderr


def test_platform_network_validation_accepts_empty_and_owned_aliases(
    tmp_path: Path,
) -> None:
    empty, _ = _run_platform_network_function(
        tmp_path / "empty",
        "platform_network_is_valid",
        {"network": _valid_platform_network()},
    )
    owned, _ = _run_platform_network_function(
        tmp_path / "owned",
        "platform_network_is_valid",
        {
            "network": _valid_platform_network(
                [
                    {
                        "id": "a" * 64,
                        "aliases": ["ladle-edge"],
                        "project": "ladle",
                        "service": "edge",
                    }
                ]
            )
        },
    )

    assert empty.returncode == 0, empty.stderr
    assert owned.returncode == 0, owned.stderr


def test_platform_network_validation_rejects_missing_and_foreign_aliases(
    tmp_path: Path,
) -> None:
    missing, _ = _run_platform_network_function(
        tmp_path / "missing",
        "platform_network_is_valid",
        {"network": None},
    )
    foreign, _ = _run_platform_network_function(
        tmp_path / "foreign",
        "platform_network_is_valid",
        {
            "network": _valid_platform_network(
                [
                    {
                        "id": "b" * 64,
                        "aliases": ["ladle-edge"],
                        "project": "foreign",
                        "service": "edge",
                    }
                ]
            )
        },
    )

    assert missing.returncode != 0
    assert "missing or unreadable" in missing.stderr
    assert foreign.returncode != 0
    assert "foreign container" in foreign.stderr


@pytest.mark.parametrize(
    ("create_mode", "expected_success"),
    (
        ("success", True),
        ("race_valid", True),
        ("fail_invalid", False),
        ("fail_missing", False),
    ),
)
def test_platform_network_creation_handles_success_races_and_real_failures(
    tmp_path: Path,
    create_mode: str,
    expected_success: bool,
) -> None:
    result, state = _run_platform_network_function(
        tmp_path,
        "ensure_platform_network",
        {
            "network": None,
            "create_mode": create_mode,
            "create_calls": 0,
        },
    )

    assert (result.returncode == 0) is expected_success, result.stderr
    assert state["create_calls"] == 1


def test_platform_network_creation_rejects_wrong_existing_network_without_mutation(
    tmp_path: Path,
) -> None:
    result, state = _run_platform_network_function(
        tmp_path,
        "ensure_platform_network",
        {
            "network": {
                **_valid_platform_network(),
                "subnets": ["172.29.0.0/24"],
            },
            "create_mode": "success",
            "create_calls": 0,
        },
    )

    assert result.returncode != 0
    assert state["create_calls"] == 0


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
    assert "sudo -n /usr/bin/env" in push
    assert 'LADLE_PUBLIC_HOSTNAME="$public_hostname"' in push
    assert '"$release/Backend/deploy/vps/initialize-env.sh"' in push
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


def test_push_forwards_a_validated_first_deployment_hostname() -> None:
    push = PUSH.read_text()

    assert "Usage: push.sh SSH_USER@HOST [PUBLIC_HOSTNAME]" in push
    assert "public_hostname=${2:-api.ladle.app}" in push
    assert "The public hostname is unsafe." in push
    assert (
        '"$revision" "$remote_directory" "$remote_archive" "$public_hostname"'
        in push
    )
    assert "public_hostname=$4" in push
    assert 'LADLE_PUBLIC_HOSTNAME="$public_hostname"' in push
    assert (
        'sudo -n /usr/bin/env \\\n'
        '    LADLE_PUBLIC_HOSTNAME="$public_hostname" \\\n'
        '    "$release/Backend/deploy/vps/initialize-env.sh"'
        in push
    )


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
        "Backend/deploy/vps/host-validation.sh",
        "Backend/deploy/vps/install-operations.sh",
        "Backend/deploy/vps/operations-launcher.sh",
        "Backend/deploy/vps/operations.sh",
        "Backend/deploy/vps/ladle-health.service",
        "Backend/deploy/vps/ladle-health.timer",
        "Backend/deploy/vps/ladle-backup.service",
        "Backend/deploy/vps/ladle-backup.timer",
        "Backend/docker-compose.yml",
        "Backend/deploy/vps/docker-compose.yml",
    ):
        assert relative_path in push
        assert relative_path in deploy
    assert deploy.index('. "$host_validation_source"') > deploy.index(
        'release_root_is_safe "$release"'
    )
    for executable_path in (
        "Backend/deploy/vps/install-operations.sh",
        "Backend/deploy/vps/operations-launcher.sh",
        "Backend/deploy/vps/operations.sh",
    ):
        assert f'[ -x "$root_release/{executable_path}" ]' in push
        assert f'[ -x "$root_release/{executable_path}" ]' in deploy


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

    network_gate = deploy.index("platform_network_is_valid")
    config = deploy.index("config --quiet")
    data = deploy.index("up -d --wait --wait-timeout", config)
    build = deploy.index("build migrate minio-init", data)
    bucket = deploy.index("run --rm minio-init", build)
    migrate = deploy.index("run --rm migrate", bucket)
    worker_pair = deploy.index("rollout_worker_pair", migrate)
    api = deploy.index("--no-deps api", worker_pair)
    beat = deploy.index("--force-recreate beat", api)
    edge = deploy.index("--no-deps edge", beat)
    assert network_gate < config < data < build < bucket < migrate < worker_pair
    assert worker_pair < api < beat < edge
    assert "caddy" not in deploy


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
    assert "activate_deployment_revision" in deploy

    edge_rollout = deploy.index(
        "compose up -d --no-build --wait --wait-timeout 120 --no-deps edge"
    )
    activation = deploy.index("activate_deployment_revision")
    for gate in (
        "wait_for_api_readiness",
        "wait_for_edge_readiness",
        "wait_for_worker_ping",
        "wait_for_beat_stability",
    ):
        readiness = deploy.rindex(gate)
        assert edge_rollout < readiness < activation
    operations_install = deploy.index("deployment_phase=operations-install")
    installer = deploy.index(
        '"$backend_directory/deploy/vps/install-operations.sh" "$revision" refresh'
    )
    assert readiness < operations_install < installer < activation
    assert "deployment_phase" in deploy
    assert 'progress failure "$deployment_phase failed"' in deploy


def _run_deploy_authority_flow(
    tmp_path: Path,
    *,
    authority_state: str,
    swap_after_readiness: bool = False,
    replace_after_readiness: bool = False,
) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")
    _write_launcher_stat(fake_bin / "stat")
    deployment_lock = tmp_path / "deploy.lock"
    environment_lock = tmp_path / "environment.lock"
    authority_lock = tmp_path / "authority.lock"
    for lock in (deployment_lock, environment_lock):
        lock.touch()
        lock.chmod(0o600)
    if authority_state != "missing":
        authority_lock.touch()
        authority_lock.chmod(0o600)
    wrong_owner_paths = ""
    if authority_state == "symlink":
        authority_lock.unlink()
        target = tmp_path / "authority-target.lock"
        target.touch()
        target.chmod(0o600)
        authority_lock.symlink_to(target)
    elif authority_state == "wrong_owner":
        wrong_owner_paths = str(authority_lock)
    elif authority_state == "wrong_mode":
        authority_lock.chmod(0o640)
    authority_replacement = tmp_path / "authority-replacement.lock"
    if replace_after_readiness:
        authority_replacement.write_text("replacement-sentinel\n")
        authority_replacement.chmod(0o600)

    backend = tmp_path / "Backend"
    installer = backend / "deploy" / "vps" / "install-operations.sh"
    installer.parent.mkdir(parents=True)
    installer.write_text(
        """#!/bin/sh
printf '%s\n' operations-refresh >>"$DEPLOY_TRACE"
"""
    )
    installer.chmod(0o755)
    trace = tmp_path / "deploy.trace"
    deploy_flow = DEPLOY.read_text()
    deploy_flow = deploy_flow[
        deploy_flow.index("deployment_lock=/var/lib/ladle/locks/deploy.lock") :
    ]
    for original, replacement in (
        (
            "deployment_lock=/var/lib/ladle/locks/deploy.lock",
            'deployment_lock="$TEST_DEPLOYMENT_LOCK"',
        ),
        (
            "authority_lock=/var/lib/ladle/locks/authority.lock",
            'authority_lock="$TEST_AUTHORITY_LOCK"',
        ),
        (
            "environment_lock=/var/lib/ladle/locks/environment.lock",
            'environment_lock="$TEST_ENVIRONMENT_LOCK"',
        ),
        (
            'acquire_deployment_lock "$deployment_lock" 0',
            'acquire_deployment_lock "$deployment_lock" "$TEST_UID"',
        ),
        (
            'acquire_environment_lock "$environment_lock" 0',
            'acquire_environment_lock "$environment_lock" "$TEST_UID"',
        ),
        (
            'lock_file_identity "$authority_lock" 0',
            'lock_file_identity "$authority_lock" "$TEST_UID"',
        ),
        (
            'acquire_authority_lock "$authority_lock" 0',
            'acquire_authority_lock "$authority_lock" "$TEST_UID"',
        ),
    ):
        deploy_flow = deploy_flow.replace(original, replacement, 1)
    runner = f"""
. "$1"
PATH=$2:$PATH
backend_directory=$3
base_compose=$backend_directory/docker-compose.yml
vps_compose=$backend_directory/deploy/vps/docker-compose.yml
revision={'d' * 40}
release=$4
state_directory=$5
secret_group=ladle-secrets
env_file=$6
deployment_phase=lock
platform_network_is_valid() {{ :; }}
validate_env_metadata() {{ :; }}
validate_staging_environment() {{ :; }}
progress() {{ :; }}
write_deployment_state() {{
    printf '%s\\n' "state:$2" >>"$DEPLOY_TRACE"
}}
docker() {{ printf '%s\\n' "compose:$*" >>"$DEPLOY_TRACE"; }}
rollout_worker_pair() {{
    printf '%s\\n' service:workers >>"$DEPLOY_TRACE"
}}
wait_for_api_readiness() {{ :; }}
wait_for_edge_readiness() {{ :; }}
wait_for_worker_ping() {{ :; }}
wait_for_beat_stability() {{
    [ "$SWAP_AFTER_READINESS" != 1 ] ||
        chmod 0640 "$TEST_AUTHORITY_LOCK"
    [ "$REPLACE_AFTER_READINESS" != 1 ] ||
        mv "$TEST_AUTHORITY_REPLACEMENT" "$TEST_AUTHORITY_LOCK"
}}
sleep() {{ :; }}
activate_deployment_revision() {{
    printf '%s\\n' activation >>"$DEPLOY_TRACE"
}}
{deploy_flow}
"""
    result = subprocess.run(
        [
            "/bin/sh",
            "-c",
            runner,
            "test",
            str(DEPLOYMENT_LIB),
            str(fake_bin),
            str(backend),
            str(tmp_path / "release"),
            str(tmp_path / "state"),
            str(tmp_path / "ladle.env"),
        ],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "DEPLOY_TRACE": str(trace),
            "SWAP_AFTER_READINESS": "1" if swap_after_readiness else "0",
            "REPLACE_AFTER_READINESS": (
                "1" if replace_after_readiness else "0"
            ),
            "TEST_AUTHORITY_LOCK": str(authority_lock),
            "TEST_AUTHORITY_REPLACEMENT": str(authority_replacement),
            "TEST_DEPLOYMENT_LOCK": str(deployment_lock),
            "TEST_ENVIRONMENT_LOCK": str(environment_lock),
            "TEST_UID": str(os.getuid()),
            "WRONG_OWNER_PATHS": wrong_owner_paths,
        },
        text=True,
        timeout=10,
    )
    return result, trace, authority_lock


@pytest.mark.parametrize(
    "authority_state",
    ("missing", "symlink", "wrong_owner", "wrong_mode"),
)
def test_deploy_rejects_unsafe_authority_before_any_mutation(
    tmp_path: Path,
    authority_state: str,
) -> None:
    result, trace, _ = _run_deploy_authority_flow(
        tmp_path,
        authority_state=authority_state,
    )

    assert result.returncode != 0
    assert "Authority lock metadata is unsafe before deployment." in result.stderr
    assert not trace.exists()


def test_deploy_authority_preflight_allows_valid_lock(tmp_path: Path) -> None:
    result, trace, _ = _run_deploy_authority_flow(
        tmp_path,
        authority_state="valid",
    )

    assert result.returncode == 0, result.stderr
    assert "operations-refresh" in trace.read_text().splitlines()
    assert "activation" in trace.read_text().splitlines()


def test_deploy_late_authority_acquire_rejects_post_preflight_swap(
    tmp_path: Path,
) -> None:
    result, trace, _ = _run_deploy_authority_flow(
        tmp_path,
        authority_state="valid",
        swap_after_readiness=True,
    )

    assert result.returncode != 0
    assert "Cannot acquire the operations authority lock." in result.stderr
    assert trace.exists()
    assert "operations-refresh" not in trace.read_text().splitlines()
    assert "activation" not in trace.read_text().splitlines()


def test_deploy_rejects_safe_authority_inode_replacement_after_preflight(
    tmp_path: Path,
) -> None:
    result, trace, authority_lock = _run_deploy_authority_flow(
        tmp_path,
        authority_state="valid",
        replace_after_readiness=True,
    )

    assert result.returncode != 0
    assert "Cannot acquire the operations authority lock." in result.stderr
    assert trace.exists()
    assert "operations-refresh" not in trace.read_text().splitlines()
    assert "activation" not in trace.read_text().splitlines()
    assert authority_lock.read_text() == "replacement-sentinel\n"


@pytest.mark.parametrize(
    ("installed_state", "expected_activation"),
    (
        ("absent", True),
        ("complete_stale", True),
        ("partial", False),
        ("refresh_failure", False),
    ),
)
def test_every_deploy_refreshes_operations_before_activation(
    tmp_path: Path,
    installed_state: str,
    expected_activation: bool,
) -> None:
    deploy = DEPLOY.read_text()
    deployment_tail = deploy[deploy.index("deployment_phase=operations-install") :]
    backend = tmp_path / "Backend"
    installer = backend / "deploy" / "vps" / "install-operations.sh"
    installer.parent.mkdir(parents=True)
    installer.write_text(
        """#!/bin/sh
set -eu
printf '%s %s\n' "$1" "$2" >"$INSTALL_TRACE"
case "$INSTALLED_STATE" in
    absent) ;;
    complete_stale)
        printf '%s\n' "current operations without caddy" >"$INSTALLED_OPERATIONS"
        ;;
    partial | refresh_failure) exit 23 ;;
esac
"""
    )
    installer.chmod(0o755)
    installed_operations = tmp_path / "installed-operations"
    if installed_state != "absent":
        installed_operations.write_text("stale operations requiring caddy\n")
    install_trace = tmp_path / "install-trace"
    activation_marker = tmp_path / "activated"
    revision = "d" * 40
    runner = f"""
set -eu
backend_directory=$1
revision=$2
release=$3
state_directory=$4
authority_lock=/var/lib/ladle/locks/authority.lock
write_deployment_state() {{ :; }}
progress() {{ :; }}
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
acquire_authority_lock() {{ :; }}
activate_deployment_revision() {{ : >"$ACTIVATION_MARKER"; }}
{deployment_tail}
"""

    result = subprocess.run(
        [
            "/bin/sh",
            "-c",
            runner,
            "test",
            str(backend),
            revision,
            str(tmp_path),
            "state",
        ],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "ACTIVATION_MARKER": str(activation_marker),
            "INSTALLED_OPERATIONS": str(installed_operations),
            "INSTALLED_STATE": installed_state,
            "INSTALL_TRACE": str(install_trace),
        },
        text=True,
    )

    assert install_trace.read_text() == f"{revision} refresh\n"
    if expected_activation:
        assert result.returncode == 0, result.stderr
        if installed_state == "absent":
            assert not installed_operations.exists()
        else:
            assert installed_operations.read_text() == (
                "current operations without caddy\n"
            )
        assert activation_marker.exists()
    else:
        assert result.returncode != 0
        assert installed_operations.read_text() == (
            "stale operations requiring caddy\n"
        )
        assert not activation_marker.exists()


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
        "operations-install",
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
        'sudo -n /usr/bin/env \\\n'
        '    LADLE_PUBLIC_HOSTNAME="$public_hostname"'
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

    lock_directory = "/var/lib/ladle/locks"
    deployment_lock = f"{lock_directory}/deploy.lock"
    authority_lock = f"{lock_directory}/authority.lock"
    environment_lock = f"{lock_directory}/environment.lock"
    transition_lock = f"{lock_directory}/transition.lock"

    assert lock_directory in provision
    assert deployment_lock in provision
    assert authority_lock in provision
    assert environment_lock in provision
    assert transition_lock in provision
    assert "mode 0600" in provision
    assert environment_lock in initialize
    assert environment_lock in set_secret
    assert deployment_lock in deploy
    assert authority_lock in deploy
    assert environment_lock in deploy
    assert deployment_lock in OPERATIONS.read_text()
    assert authority_lock in OPERATIONS.read_text()
    assert deployment_lock in INSTALL_OPERATIONS.read_text()
    assert authority_lock in INSTALL_OPERATIONS.read_text()
    assert environment_lock in INSTALL_OPERATIONS.read_text()
    assert transition_lock in INSTALL_OPERATIONS.read_text()
    assert "safe_directory /var/lib/ladle/locks 700" in OPERATIONS.read_text()
    assert transition_lock in OPERATIONS.read_text()
    assert transition_lock in HEALTH_SERVICE.read_text()
    assert transition_lock in BACKUP_SERVICE.read_text()
    assert authority_lock in OPERATIONS_LAUNCHER.read_text()
    assert deployment_lock not in OPERATIONS_LAUNCHER.read_text()
    assert "/var/lock/ladle-" not in provision
    assert "/var/lock/ladle-" not in initialize
    assert "/var/lock/ladle-" not in set_secret
    assert "/var/lock/ladle-" not in deploy
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
    readiness = deploy.rindex("wait_for_beat_stability")
    authority = deploy.index("acquire_authority_lock", readiness)
    refresh = deploy.index("deployment_phase=operations-install")
    activation = deploy.index("deployment_phase=activation")
    assert readiness < authority < refresh < activation


@pytest.mark.parametrize(
    ("lock_state", "expected_success"),
    (
        ("safe", True),
        ("missing", False),
        ("symlink", False),
        ("wrong_owner", False),
        ("wrong_mode", False),
        ("canonical_mismatch", False),
    ),
)
def test_deployment_authority_lock_rejects_unsafe_metadata(
    tmp_path: Path,
    lock_state: str,
    expected_success: bool,
) -> None:
    lock_path = tmp_path / "authority.lock"
    actual_lock = lock_path
    expected_uid = os.getuid()
    if lock_state == "canonical_mismatch":
        canonical_directory = tmp_path / "canonical"
        canonical_directory.mkdir()
        alias_directory = tmp_path / "alias"
        alias_directory.symlink_to(canonical_directory, target_is_directory=True)
        lock_path = alias_directory / "authority.lock"
        actual_lock = canonical_directory / "authority.lock"
    if lock_state != "missing":
        actual_lock.touch()
        actual_lock.chmod(0o600)
    if lock_state == "symlink":
        actual_lock.unlink()
        target = tmp_path / "target.lock"
        target.touch()
        target.chmod(0o600)
        actual_lock.symlink_to(target)
    elif lock_state == "wrong_owner":
        expected_uid += 1
    elif lock_state == "wrong_mode":
        actual_lock.chmod(0o640)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")
    _write_launcher_stat(fake_bin / "stat")

    result = _run_library_script(
        """
PATH=$1:$PATH
expected_identity=$(lock_file_identity "$2" "$3") || exit 1
acquire_authority_lock "$2" "$3" "$expected_identity"
""",
        fake_bin,
        lock_path,
        str(expected_uid),
    )

    assert (result.returncode == 0) is expected_success, result.stderr


def test_deployment_authority_lock_pins_stable_identity_without_truncation(
    tmp_path: Path,
) -> None:
    lock_path = tmp_path / "authority.lock"
    lock_path.write_text("lock-sentinel\n")
    lock_path.chmod(0o600)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")
    _write_launcher_stat(fake_bin / "stat")

    result = _run_library_script(
        """
PATH=$1:$PATH
expected_identity=$(lock_file_identity "$2" "$3") || exit 1
acquire_authority_lock "$2" "$3" "$expected_identity"
""",
        fake_bin,
        lock_path,
        str(os.getuid()),
    )

    assert result.returncode == 0, result.stderr
    assert lock_path.read_text() == "lock-sentinel\n"


def test_persistent_lock_contract_rejects_a_volatile_symlink_alias(
    tmp_path: Path,
) -> None:
    persistent = tmp_path / "var" / "lib" / "ladle" / "locks"
    persistent.mkdir(parents=True, mode=0o700)
    persistent_lock = persistent / "deploy.lock"
    persistent_lock.touch(mode=0o600)
    volatile = tmp_path / "run" / "lock"
    volatile.mkdir(parents=True)
    volatile_lock = volatile / "deploy.lock"
    volatile_lock.touch(mode=0o600)
    legacy_parent = tmp_path / "var" / "lock"
    legacy_parent.symlink_to(volatile, target_is_directory=True)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")

    canonical = _run_library_script(
        """
PATH=$1:$PATH
acquire_deployment_lock "$2" "$3"
""",
        fake_bin,
        persistent_lock,
        str(os.getuid()),
    )
    alias = _run_library_script(
        """
PATH=$1:$PATH
acquire_deployment_lock "$2" "$3"
""",
        fake_bin,
        legacy_parent / "deploy.lock",
        str(os.getuid()),
    )
    volatile_lock.unlink()

    assert canonical.returncode == 0, canonical.stderr
    assert alias.returncode != 0
    assert persistent_lock.is_file()
    assert persistent_lock.stat().st_mode & 0o777 == 0o600


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


def test_active_state_write_failure_leaves_current_on_previous_release(
    tmp_path: Path,
) -> None:
    state_directory = tmp_path / "state"
    state_directory.mkdir(mode=0o750)
    previous = tmp_path / ("a" * 40)
    candidate = tmp_path / ("b" * 40)
    previous.mkdir(mode=0o755)
    candidate.mkdir(mode=0o755)
    current = tmp_path / "current"
    current.symlink_to(previous)

    failed = _run_deployment_library(
        "activate_deployment_revision",
        state_directory,
        candidate.name,
        candidate,
        current,
        str(os.getuid() + 1),
    )

    assert failed.returncode == 1
    assert current.resolve() == previous
    assert not (state_directory / "deployment-state").exists()


def test_activation_failure_leaves_current_old_and_records_failed_state(
    tmp_path: Path,
) -> None:
    state_directory = tmp_path / "state"
    state_directory.mkdir(mode=0o750)
    previous = tmp_path / ("a" * 40)
    candidate = tmp_path / ("b" * 40)
    previous.mkdir(mode=0o755)
    candidate.mkdir(mode=0o755)
    current = tmp_path / "current"
    current.symlink_to(previous)
    state_file = state_directory / "deployment-state"

    failed = _run_library_script(
        """
mkdir "$4.next.$$"
set +e
activate_deployment_revision "$1" "$2" "$3" "$4" "$5"
transaction_status=$?
set -e
finalize_deployment_exit \
    "$transaction_status" true "$1" "$2" activation "$4" "$5"
[ "$DEPLOYMENT_FINAL_STATUS" -eq 1 ]
""",
        state_directory,
        candidate.name,
        candidate,
        current,
        str(os.getuid()),
    )

    assert failed.returncode == 0, failed.stderr
    assert current.resolve() == previous
    assert state_file.read_text() == (
        f"STATUS=failed\nREVISION={candidate.name}\nPHASE=activation\n"
    )


def test_failure_after_current_moves_is_reconciled_as_committed(
    tmp_path: Path,
) -> None:
    state_directory = tmp_path / "state"
    state_directory.mkdir(mode=0o750)
    release = tmp_path / ("c" * 40)
    release.mkdir(mode=0o755)
    current = tmp_path / "current"
    state_file = state_directory / "deployment-state"

    interrupted = _run_library_script(
        """
activate_deployment_revision "$1" "$2" "$3" "$4" "$5"
finalize_deployment_exit 143 true "$1" "$2" activation "$4" "$5"
[ "$DEPLOYMENT_FINAL_STATUS" -eq 0 ]
[ "$DEPLOYMENT_COMMIT_RECOVERED" = true ]
""",
        state_directory,
        release.name,
        release,
        current,
        str(os.getuid()),
    )
    assert interrupted.returncode == 0, interrupted.stderr
    assert state_file.read_text() == (
        f"STATUS=active\nREVISION={release.name}\nPHASE=complete\n"
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
    library = DEPLOYMENT_LIB.read_text()
    activation_helper = library[
        library.index("activate_deployment_revision()") : library.index(
            "finalize_deployment_exit()"
        )
    ]
    assert activation_helper.index("write_deployment_state") < (
        activation_helper.index("activate_release")
    )
    activation = deploy.index("activate_deployment_revision")
    success = deploy.index('progress "success"')
    assert activation < success
    assert 'progress "success" "revision $revision is active" || true' in deploy
    assert deploy.index(
        'write_deployment_state "$state_directory" deploying'
    ) < deploy.index("compose up -d")
    assert "finalize_deployment_exit" in deploy
    assert 'write_deployment_state "$finalization_state_directory" failed' in library


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
        "activate_deployment_revision"
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


def test_vps_operations_assets_are_posix_and_executable() -> None:
    for script in (OPERATIONS, INSTALL_OPERATIONS):
        assert script.is_file()
        assert script.stat().st_mode & stat.S_IXUSR
        text = script.read_text()
        assert text.startswith("#!/bin/sh\nset -eu\numask 077\n")
        assert "set -x" not in text
        assert "/Users/" not in text
        assert "Library/Application Support" not in text
        for macos_command in ("launchctl", "osascript", "shasum", "stat -f"):
            assert macos_command not in text


def test_vps_operations_create_validated_atomic_postgres_backups() -> None:
    operations = OPERATIONS.read_text()

    assert "/var/backups/ladle" in operations
    assert "20" in operations
    assert "35" in operations
    assert "df -Pk" in operations
    assert "pg_dump -Fc" in operations
    assert "pg_restore --list" in operations
    assert "sha256sum" in operations
    assert '[ "${#backup_digest}" -eq 64 ]' in operations
    assert "chmod 0600" in operations
    assert "stat -c" in operations
    assert "mktemp" in operations
    assert "mv -f --" in operations
    assert "remove_incomplete_backup_pairs" in operations
    assert "retain_backup_pairs" in operations
    assert '-mtime "+$backup_retention_days"' in operations
    assert 'rm -f -- "$retained_dump" "$retained_checksum"' in operations
    assert "POSTGRES_PASSWORD" not in operations
    assert "LADLE_DATABASE_PASSWORD" not in operations

    disk_check = operations.index("df -Pk")
    dump = operations.index("pg_dump -Fc")
    nonempty = operations.index('[ ! -s "$temporary_backup" ]')
    validation = operations.index("pg_restore --list")
    final_move = operations.index('mv -f -- "$temporary_backup" "$backup_path"')
    digest = operations.index("sha256sum", validation)
    assert disk_check < dump < nonempty < validation < digest < final_move
    backup = operations[operations.index("database_backup()") :]
    assert backup.index("acquire_deployment_lock") < backup.index(
        "remove_incomplete_backup_pairs"
    )
    assert backup.index("remove_incomplete_backup_pairs") < backup.index("pg_dump -Fc")


def test_operations_launcher_overwrites_pin_and_forwards_original_arguments(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    revision = "a" * 40
    active, _, _ = _write_operations_release(releases, revision, "active")
    current = tmp_path / "current"
    current.symlink_to(active)
    launcher = _write_test_operations_launcher(tmp_path, current, releases)
    trace = tmp_path / "launch.trace"

    result = _run_launcher(
        launcher,
        trace,
        "status",
        "37",
        env={"LADLE_OPERATIONS_EXPECTED_RELEASE": "/spoofed/release"},
    )

    assert result.returncode == 0, result.stderr
    assert trace.read_text() == f"active:{active}:status 37\n"


def test_operations_launcher_follows_current_after_activation(tmp_path: Path) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    old_release, _, _ = _write_operations_release(
        releases,
        "a" * 40,
        "old",
    )
    new_release, _, _ = _write_operations_release(
        releases,
        "b" * 40,
        "new",
    )
    current = tmp_path / "current"
    current.symlink_to(old_release)
    launcher = _write_test_operations_launcher(tmp_path, current, releases)
    trace = tmp_path / "launch.trace"

    old_result = _run_launcher(launcher, trace, "health")
    current.unlink()
    current.symlink_to(new_release)
    new_result = _run_launcher(launcher, trace, "backup")

    assert old_result.returncode == 0, old_result.stderr
    assert new_result.returncode == 0, new_result.stderr
    assert trace.read_text().splitlines() == [
        f"old:{old_release}:health",
        f"new:{new_release}:backup",
    ]


@pytest.mark.parametrize("contender", ("backup", "deployment"))
def test_health_authority_reader_does_not_block_deploy_lock(
    tmp_path: Path,
    contender: str,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    release, _, operations = _write_operations_release(
        releases,
        "a" * 40,
        "active",
    )
    current = tmp_path / "current"
    current.symlink_to(release)
    authority_lock = tmp_path / "authority.lock"
    deployment_lock = tmp_path / "deploy.lock"
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        authority_lock=authority_lock,
        deployment_lock=deployment_lock,
    )
    reader_started = tmp_path / "reader-started"
    reader_release = tmp_path / "reader-release"
    operations.write_text(
        """#!/bin/sh
: >"$READER_STARTED"
attempt=0
while [ ! -e "$READER_RELEASE" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 500 ] || exit 1
    sleep 0.01
done
"""
    )
    operations.chmod(0o755)
    reader_process = subprocess.Popen(
        [str(launcher), "health"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            **os.environ,
            "READER_STARTED": str(reader_started),
            "READER_RELEASE": str(reader_release),
            "WRONG_OWNER_PATHS": "",
        },
        text=True,
    )
    try:
        _wait_for_path(reader_started, process=reader_process)
        if contender == "backup":
            fake_flock = tmp_path / "launcher-bin" / "flock"
            result = _run_operations_library(
                """
deployment_lock=$1
fake_flock=$2
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
flock() { "$fake_flock" "$@"; }
acquire_deployment_lock
""",
                deployment_lock,
                fake_flock,
                timeout=5,
            )
        else:
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    """
import fcntl
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("r+") as descriptor:
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
""",
                    str(deployment_lock),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
    finally:
        reader_release.touch(exist_ok=True)
        if reader_process.poll() is None:
            _, reader_stderr = reader_process.communicate(timeout=5)
            assert reader_process.returncode == 0, reader_stderr

    assert result.returncode == 0, result.stderr


def test_operations_launcher_shared_lock_open_does_not_truncate(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    release, _, _ = _write_operations_release(
        releases,
        "a" * 40,
        "active",
    )
    current = tmp_path / "current"
    current.symlink_to(release)
    authority_lock = tmp_path / "authority.lock"
    authority_lock.write_text("lock-sentinel\n")
    authority_lock.chmod(0o600)
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        authority_lock=authority_lock,
        create_authority_lock=False,
    )

    result = _run_launcher(
        launcher,
        tmp_path / "launch.trace",
        "status",
    )

    assert result.returncode == 0, result.stderr
    assert authority_lock.read_text() == "lock-sentinel\n"


@pytest.mark.parametrize(
    "replacement_timing",
    ("before_open", "after_open"),
)
def test_operations_launcher_rejects_authority_inode_replacement(
    tmp_path: Path,
    replacement_timing: str,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    release, _, _ = _write_operations_release(
        releases,
        "a" * 40,
        "active",
    )
    current = tmp_path / "current"
    current.symlink_to(release)
    authority_lock = tmp_path / "authority.lock"
    authority_lock.write_text("original\n")
    authority_lock.chmod(0o600)
    replacement = tmp_path / "authority-replacement.lock"
    replacement.write_text("replacement\n")
    replacement.chmod(0o600)
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        authority_lock=authority_lock,
        create_authority_lock=False,
    )
    trace = tmp_path / "launch.trace"
    trigger = {
        f"AUTHORITY_REPLACEMENT_{replacement_timing.upper()}": str(replacement)
    }

    result = _run_launcher(
        launcher,
        trace,
        "health",
        env={
            "AUTHORITY_LOCK_PATH": str(authority_lock),
            **trigger,
        },
    )

    assert result.returncode != 0
    assert result.stderr == "Cannot run active Ladle operations.\n"
    assert not trace.exists()
    assert authority_lock.read_text() == "replacement\n"


def test_operations_launcher_fails_closed_without_open_fd_identity(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    release, _, _ = _write_operations_release(
        releases,
        "a" * 40,
        "active",
    )
    current = tmp_path / "current"
    current.symlink_to(release)
    launcher = _write_test_operations_launcher(tmp_path, current, releases)
    trace = tmp_path / "launch.trace"

    result = _run_launcher(
        launcher,
        trace,
        "health",
        env={"FAIL_AUTHORITY_FD_STAT": "1"},
    )

    assert result.returncode != 0
    assert result.stderr == "Cannot run active Ladle operations.\n"
    assert not trace.exists()


@pytest.mark.parametrize(
    "unsafe_lock",
    (
        "missing",
        "symlink",
        "wrong_owner",
        "wrong_mode",
        "canonical_mismatch",
    ),
)
def test_operations_launcher_rejects_unsafe_authority_lock_before_dispatch(
    tmp_path: Path,
    unsafe_lock: str,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    release, _, _ = _write_operations_release(
        releases,
        "a" * 40,
        "active",
    )
    current = tmp_path / "current"
    current.symlink_to(release)
    authority_lock = tmp_path / "authority.lock"
    actual_lock = authority_lock
    wrong_owner_paths: tuple[Path, ...] = ()
    if unsafe_lock == "canonical_mismatch":
        canonical_directory = tmp_path / "canonical-locks"
        canonical_directory.mkdir()
        alias_directory = tmp_path / "lock-alias"
        alias_directory.symlink_to(canonical_directory, target_is_directory=True)
        authority_lock = alias_directory / "authority.lock"
        actual_lock = canonical_directory / "authority.lock"
    if unsafe_lock != "missing":
        actual_lock.touch()
        actual_lock.chmod(0o600)
    if unsafe_lock == "symlink":
        actual_lock.unlink()
        target = tmp_path / "lock-target"
        target.touch()
        target.chmod(0o600)
        actual_lock.symlink_to(target)
    elif unsafe_lock == "wrong_owner":
        wrong_owner_paths = (authority_lock,)
    elif unsafe_lock == "wrong_mode":
        actual_lock.chmod(0o640)
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        authority_lock=authority_lock,
        create_authority_lock=False,
    )
    trace = tmp_path / "launch.trace"

    result = _run_launcher(
        launcher,
        trace,
        "health",
        wrong_owner_paths=wrong_owner_paths,
    )

    assert result.returncode != 0
    assert result.stderr == "Cannot run active Ladle operations.\n"
    assert not trace.exists()


def test_operations_launcher_holds_authority_for_legacy_release_until_exit(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    old_release, _, old_operations = _write_operations_release(
        releases,
        "a" * 40,
        "old",
    )
    new_release, _, _ = _write_operations_release(
        releases,
        "b" * 40,
        "new",
    )
    current = tmp_path / "current"
    current.symlink_to(old_release)
    authority_lock = tmp_path / "authority.lock"
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        authority_lock=authority_lock,
    )
    legacy_started = tmp_path / "legacy-started"
    legacy_observe = tmp_path / "legacy-observe"
    activation_attempted = tmp_path / "activation-attempted"
    activation_acquired = tmp_path / "activation-acquired"
    trace = tmp_path / "launch.trace"
    old_operations.write_text(
        """#!/bin/sh
: >"$LEGACY_STARTED"
attempt=0
while [ ! -e "$LEGACY_OBSERVE" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 500 ] || exit 1
    sleep 0.01
done
observed=$(readlink -f -- "$CURRENT_PATH") || exit 1
printf '%s\n' "legacy:$observed" >>"$LAUNCH_TRACE"
"""
    )
    old_operations.chmod(0o755)
    environment = {
        **os.environ,
        "LAUNCH_TRACE": str(trace),
        "WRONG_OWNER_PATHS": "",
        "LEGACY_STARTED": str(legacy_started),
        "LEGACY_OBSERVE": str(legacy_observe),
        "CURRENT_PATH": str(current),
    }
    launcher_process = subprocess.Popen(
        [str(launcher), "health"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        text=True,
    )
    activation_process: subprocess.Popen[str] | None = None
    try:
        _wait_for_path(legacy_started, process=launcher_process)
        activation_process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                """
import fcntl
import os
import pathlib
import sys

lock, current, release, attempted, acquired = map(pathlib.Path, sys.argv[1:])
with lock.open("r+") as descriptor:
    attempted.touch()
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    replacement = current.with_name(f"{current.name}.next")
    replacement.symlink_to(release)
    os.replace(replacement, current)
    acquired.touch()
""",
                str(authority_lock),
                str(current),
                str(new_release),
                str(activation_attempted),
                str(activation_acquired),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        _wait_for_path(activation_attempted, process=activation_process)
        with pytest.raises(subprocess.TimeoutExpired):
            activation_process.communicate(timeout=0.2)
        assert not activation_acquired.exists()
        assert current.resolve() == old_release
        legacy_observe.touch()
        _, launcher_stderr = launcher_process.communicate(timeout=10)
        assert launcher_process.returncode == 0, launcher_stderr
        _, activation_stderr = activation_process.communicate(timeout=10)
        assert activation_process.returncode == 0, activation_stderr
    finally:
        legacy_observe.touch(exist_ok=True)
        if launcher_process.poll() is None:
            launcher_process.kill()
            launcher_process.communicate(timeout=5)
        if activation_process is not None and activation_process.poll() is None:
            activation_process.kill()
            activation_process.communicate(timeout=5)

    subsequent = _run_launcher(launcher, trace, "backup")

    assert subsequent.returncode == 0, subsequent.stderr
    assert trace.read_text().splitlines() == [
        f"legacy:{old_release}",
        f"new:{new_release}:backup",
    ]


def test_deploy_rejects_replaced_path_while_launcher_holds_old_authority(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    release, _, operations = _write_operations_release(
        releases,
        "a" * 40,
        "active",
    )
    current = tmp_path / "current"
    current.symlink_to(release)
    authority_lock = tmp_path / "authority.lock"
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        authority_lock=authority_lock,
    )
    expected_metadata = authority_lock.stat()
    expected_identity = (
        f"{expected_metadata.st_dev}:{expected_metadata.st_ino}:"
        f"{expected_metadata.st_uid}:600"
    )
    launcher_holding = tmp_path / "launcher-holding"
    launcher_release = tmp_path / "launcher-release"
    activation = tmp_path / "activation"
    operations.write_text(
        """#!/bin/sh
: >"$LAUNCHER_HOLDING"
attempt=0
while [ ! -e "$LAUNCHER_RELEASE" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 500 ] || exit 1
    sleep 0.01
done
"""
    )
    operations.chmod(0o755)
    launcher_process = subprocess.Popen(
        [str(launcher), "health"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            **os.environ,
            "LAUNCH_TRACE": str(tmp_path / "launch.trace"),
            "LAUNCHER_HOLDING": str(launcher_holding),
            "LAUNCHER_RELEASE": str(launcher_release),
            "WRONG_OWNER_PATHS": "",
        },
        text=True,
    )
    try:
        _wait_for_path(launcher_holding, process=launcher_process)
        replacement = tmp_path / "authority-replacement.lock"
        replacement.write_text("replacement\n")
        replacement.chmod(0o600)
        os.replace(replacement, authority_lock)
        fake_bin = tmp_path / "launcher-bin"

        result = _run_library_script(
            """
PATH=$1:$PATH
acquire_authority_lock "$2" "$3" "$4" &&
    : >"$5"
""",
            fake_bin,
            authority_lock,
            str(os.getuid()),
            expected_identity,
            activation,
            env={
                "AUTHORITY_LOCK_PATH": str(authority_lock),
                "WRONG_OWNER_PATHS": "",
            },
        )
    finally:
        launcher_release.touch(exist_ok=True)
        _, launcher_stderr = launcher_process.communicate(timeout=5)
        assert launcher_process.returncode == 0, launcher_stderr

    assert result.returncode != 0
    assert not activation.exists()
    assert authority_lock.read_text() == "replacement\n"


def test_operations_launcher_waits_for_exclusive_authority_before_selection(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    old_release, _, _ = _write_operations_release(
        releases,
        "a" * 40,
        "old",
    )
    new_release, _, _ = _write_operations_release(
        releases,
        "b" * 40,
        "new",
    )
    current = tmp_path / "current"
    current.symlink_to(old_release)
    authority_lock = tmp_path / "authority.lock"
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        authority_lock=authority_lock,
        mark_before_current_selection=True,
    )
    deployment_held = tmp_path / "deployment-held"
    deployment_release = tmp_path / "deployment-release"
    launcher_started = tmp_path / "launcher-started"
    launcher_continue = tmp_path / "launcher-continue"
    launcher_continued = tmp_path / "launcher-continued"
    launcher_prelock = tmp_path / "launcher-prelock"
    launcher_prelock_continue = tmp_path / "launcher-prelock-continue"
    launcher_selecting = tmp_path / "launcher-selecting"
    launcher_selection_resume = tmp_path / "launcher-selection-resume"
    trace = tmp_path / "launch.trace"
    deployment_process = subprocess.Popen(
        [
            sys.executable,
            "-c",
            """
import fcntl
import os
import pathlib
import sys
import time

lock, current, release, held, resume = map(pathlib.Path, sys.argv[1:])
with lock.open("r+") as descriptor:
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    held.touch()
    deadline = time.monotonic() + 10
    while not resume.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not resume.exists():
        raise SystemExit("timed out waiting to finish deployment")
    replacement = current.with_name(f"{current.name}.next")
    replacement.symlink_to(release)
    os.replace(replacement, current)
""",
            str(authority_lock),
            str(current),
            str(new_release),
            str(deployment_held),
            str(deployment_release),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    launcher_process: subprocess.Popen[str] | None = None
    try:
        _wait_for_path(deployment_held, process=deployment_process)
        launcher_process = subprocess.Popen(
            [str(launcher), "health"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **os.environ,
                "LAUNCH_TRACE": str(trace),
                "LAUNCHER_STARTED": str(launcher_started),
                "LAUNCHER_CONTINUE": str(launcher_continue),
                "LAUNCHER_CONTINUED": str(launcher_continued),
                "LAUNCHER_PRELOCK": str(launcher_prelock),
                "LAUNCHER_PRELOCK_CONTINUE": str(launcher_prelock_continue),
                "LAUNCHER_SELECTING": str(launcher_selecting),
                "LAUNCHER_SELECTION_RESUME": str(launcher_selection_resume),
                "WRONG_OWNER_PATHS": "",
            },
            text=True,
        )
        _wait_for_path(launcher_started, process=launcher_process)
        launcher_continue.touch()
        _wait_for_path(launcher_continued, process=launcher_process)
        _wait_for_path(launcher_prelock, process=launcher_process)
        launcher_prelock_continue.touch()
        with pytest.raises(subprocess.TimeoutExpired):
            launcher_process.communicate(timeout=1)
        assert not launcher_selecting.exists()
        assert not trace.exists()
        deployment_release.touch()
        _, deployment_stderr = deployment_process.communicate(timeout=10)
        assert deployment_process.returncode == 0, deployment_stderr
        _wait_for_path(launcher_selecting, process=launcher_process)
        launcher_selection_resume.touch()
        _, launcher_stderr = launcher_process.communicate(timeout=10)
        assert launcher_process.returncode == 0, launcher_stderr
    finally:
        deployment_release.touch(exist_ok=True)
        launcher_continue.touch(exist_ok=True)
        launcher_prelock_continue.touch(exist_ok=True)
        launcher_selection_resume.touch(exist_ok=True)
        if deployment_process.poll() is None:
            deployment_process.kill()
            deployment_process.communicate(timeout=5)
        if launcher_process is not None and launcher_process.poll() is None:
            launcher_process.kill()
            launcher_process.communicate(timeout=5)

    assert trace.read_text() == f"new:{new_release}:health\n"


def test_operations_handoff_dispatches_stable_old_and_new_releases(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    current = tmp_path / "current"
    deployment_state = tmp_path / "deployment-state"
    old_release, _ = _write_guarded_operations_release(
        releases,
        "a" * 40,
        "old",
        current,
        deployment_state,
    )
    new_release, _ = _write_guarded_operations_release(
        releases,
        "b" * 40,
        "new",
        current,
        deployment_state,
    )
    current.symlink_to(old_release)
    _write_active_deployment_state(deployment_state, old_release.name)
    launcher = _write_test_operations_launcher(tmp_path, current, releases)
    mutation_trace = tmp_path / "mutation.trace"
    launcher_env = {"MUTATION_TRACE": str(mutation_trace)}

    old_result = _run_launcher(
        launcher,
        tmp_path / "launch.trace",
        "status",
        "37",
        env=launcher_env,
    )
    _activate_test_release(current, deployment_state, new_release)
    new_result = _run_launcher(
        launcher,
        tmp_path / "launch.trace",
        "status",
        "41",
        env=launcher_env,
    )

    assert old_result.returncode == 0, old_result.stderr
    assert new_result.returncode == 0, new_result.stderr
    assert mutation_trace.read_text().splitlines() == [
        f"old:{old_release}/Backend:ps",
        f"new:{new_release}/Backend:ps",
    ]


@pytest.mark.parametrize(
    "pin_case",
    ("missing", "malformed", "spoofed"),
)
def test_operations_executable_rejects_untrusted_release_pin(
    tmp_path: Path,
    pin_case: str,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    current = tmp_path / "current"
    deployment_state = tmp_path / "deployment-state"
    old_release, old_operations = _write_guarded_operations_release(
        releases,
        "a" * 40,
        "old",
        current,
        deployment_state,
    )
    new_release, _ = _write_guarded_operations_release(
        releases,
        "b" * 40,
        "new",
        current,
        deployment_state,
    )
    current.symlink_to(old_release)
    _write_active_deployment_state(deployment_state, old_release.name)
    expected_release = {
        "missing": None,
        "malformed": "/not/an/immutable/release",
        "spoofed": str(new_release),
    }[pin_case]
    mutation_trace = tmp_path / "mutation.trace"

    result = _run_release_operations(
        old_operations,
        mutation_trace,
        "status",
        expected_release=expected_release,
    )

    assert result.returncode != 0
    assert not mutation_trace.exists()


@pytest.mark.parametrize(
    "mixed_state",
    ("new_state_old_current", "old_state_new_current"),
)
@pytest.mark.parametrize("operation", ("health", "backup"))
def test_operations_pin_rejects_both_activation_write_order_mismatches(
    tmp_path: Path,
    mixed_state: str,
    operation: str,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    current = tmp_path / "current"
    deployment_state = tmp_path / "deployment-state"
    old_release, old_operations = _write_guarded_operations_release(
        releases,
        "a" * 40,
        "old",
        current,
        deployment_state,
    )
    new_release, _ = _write_guarded_operations_release(
        releases,
        "b" * 40,
        "new",
        current,
        deployment_state,
    )
    current.symlink_to(old_release)
    if mixed_state == "new_state_old_current":
        _write_active_deployment_state(deployment_state, new_release.name)
    else:
        _write_active_deployment_state(deployment_state, old_release.name)
        replacement = current.with_name("current.next")
        replacement.symlink_to(new_release)
        os.replace(replacement, current)
    mutation_trace = tmp_path / "mutation.trace"

    result = _run_release_operations(
        old_operations,
        mutation_trace,
        operation,
        expected_release=str(old_release),
    )

    assert result.returncode != 0
    assert not mutation_trace.exists()


@pytest.mark.parametrize("operation", ("health", "backup"))
def test_operations_handoff_fails_closed_when_activation_wins_exec_race(
    tmp_path: Path,
    operation: str,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    current = tmp_path / "current"
    deployment_state = tmp_path / "deployment-state"
    old_release, _ = _write_guarded_operations_release(
        releases,
        "a" * 40,
        "old",
        current,
        deployment_state,
    )
    new_release, _ = _write_guarded_operations_release(
        releases,
        "b" * 40,
        "new",
        current,
        deployment_state,
    )
    current.symlink_to(old_release)
    _write_active_deployment_state(deployment_state, old_release.name)
    launcher = _write_test_operations_launcher(
        tmp_path,
        current,
        releases,
        pause_before_exec=True,
    )
    selected = tmp_path / "launcher-selected"
    resume = tmp_path / "launcher-resume"
    mutation_trace = tmp_path / "mutation.trace"
    environment = {
        **os.environ,
        "LAUNCHER_SELECTED": str(selected),
        "LAUNCHER_RESUME": str(resume),
        "LAUNCH_TRACE": str(tmp_path / "launch.trace"),
        "MUTATION_TRACE": str(mutation_trace),
        "WRONG_OWNER_PATHS": "",
    }
    process = subprocess.Popen(
        [str(launcher), operation],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        text=True,
    )
    try:
        deadline = time.monotonic() + 5
        while (
            not selected.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        assert selected.exists(), "launcher did not reach the bounded race gate"
        _activate_test_release(current, deployment_state, new_release)
        resume.touch()
        _, stderr = process.communicate(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)

    assert process.returncode != 0, stderr
    assert not mutation_trace.exists()


def test_operations_authority_uses_one_deployment_state_snapshot(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    current = tmp_path / "current"
    deployment_state = tmp_path / "deployment-state"
    old_release, old_operations = _write_guarded_operations_release(
        releases,
        "a" * 40,
        "old",
        current,
        deployment_state,
    )
    new_release, _ = _write_guarded_operations_release(
        releases,
        "b" * 40,
        "new",
        current,
        deployment_state,
    )
    current.symlink_to(old_release)
    _write_active_deployment_state(deployment_state, old_release.name)
    selected = tmp_path / "state-read-selected"
    resume = tmp_path / "state-read-resume"
    mutation_trace = tmp_path / "mutation.trace"
    environment = {
        **os.environ,
        "LADLE_OPERATIONS_EXPECTED_RELEASE": str(old_release),
        "MUTATION_TRACE": str(mutation_trace),
        "STATE_READ_SELECTED": str(selected),
        "STATE_READ_RESUME": str(resume),
    }
    process = subprocess.Popen(
        [str(old_operations), "status"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        text=True,
    )
    try:
        deadline = time.monotonic() + 5
        while (
            not selected.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        assert selected.exists(), "state read did not reach the bounded gate"
        _write_active_deployment_state(deployment_state, new_release.name)
        resume.touch()
        _, stderr = process.communicate(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)

    assert process.returncode == 0, stderr
    assert mutation_trace.read_text().splitlines() == [
        f"old:{old_release}/Backend:ps"
    ]


@pytest.mark.parametrize(
    ("operation", "failure_env", "expected_trace"),
    (
        (
            "health",
            {"HEALTH_FAIL_AFTER_AUTHORITY": "1"},
            (
                "health-check",
                "backup-health-check",
                "log:health failed forced health failure",
            ),
        ),
        (
            "backup",
            {"BACKUP_FAIL_AFTER_AUTHORITY": "1"},
            (
                "lock-open",
                "lock-acquire",
                "remove-incomplete",
                "backup-health-check",
                "cleanup",
                "log:backup failed database backup did not complete",
            ),
        ),
    ),
)
def test_operations_preserve_post_authority_failure_cleanup_and_logging(
    tmp_path: Path,
    operation: str,
    failure_env: dict[str, str],
    expected_trace: tuple[str, ...],
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    current = tmp_path / "current"
    deployment_state = tmp_path / "deployment-state"
    release, operations = _write_guarded_operations_release(
        releases,
        "a" * 40,
        "active",
        current,
        deployment_state,
    )
    current.symlink_to(release)
    _write_active_deployment_state(deployment_state, release.name)
    mutation_trace = tmp_path / "mutation.trace"
    environment = {
        **os.environ,
        **failure_env,
        "LADLE_OPERATIONS_EXPECTED_RELEASE": str(release),
        "MUTATION_TRACE": str(mutation_trace),
    }

    result = subprocess.run(
        [str(operations), operation],
        check=False,
        capture_output=True,
        env=environment,
        text=True,
    )

    assert result.returncode != 0
    assert tuple(mutation_trace.read_text().splitlines()) == expected_trace


@pytest.mark.parametrize(
    ("systemctl_status", "expected_status"),
    ((0, 0), (3, 0), (1, 1), (4, 4)),
)
def test_operations_status_only_tolerates_inactive_systemd_units(
    tmp_path: Path,
    systemctl_status: int,
    expected_status: int,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    current = tmp_path / "current"
    deployment_state = tmp_path / "deployment-state"
    release, operations = _write_guarded_operations_release(
        releases,
        "a" * 40,
        "active",
        current,
        deployment_state,
    )
    current.symlink_to(release)
    _write_active_deployment_state(deployment_state, release.name)
    mutation_trace = tmp_path / "mutation.trace"

    result = subprocess.run(
        [str(operations), "status"],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "LADLE_OPERATIONS_EXPECTED_RELEASE": str(release),
            "MUTATION_TRACE": str(mutation_trace),
            "SYSTEMCTL_STATUS": str(systemctl_status),
        },
        text=True,
    )

    assert result.returncode == expected_status, result.stderr


@pytest.mark.parametrize(
    ("journal_status", "compose_status"),
    ((1, 0), (0, 1)),
)
def test_operations_logs_propagate_journal_and_compose_errors(
    journal_status: int,
    compose_status: int,
) -> None:
    result = _run_operations_library(
        """
log_lines=20
load_authoritative_release() { :; }
journalctl() { return "$JOURNAL_STATUS"; }
compose() { return "$COMPOSE_STATUS"; }
show_logs
""",
        env={
            "JOURNAL_STATUS": str(journal_status),
            "COMPOSE_STATUS": str(compose_status),
        },
    )

    assert result.returncode != 0


@pytest.mark.parametrize(
    "unsafe_state",
    (
        "current_regular",
        "outside_releases",
        "malformed_revision",
        "mutable_release",
        "wrong_owner_release",
        "mutable_marker",
        "wrong_owner_marker",
        "mutable_script",
        "wrong_owner_script",
        "symlinked_script",
        "marker_mismatch",
    ),
)
def test_operations_launcher_fails_closed_for_untrusted_active_release(
    tmp_path: Path,
    unsafe_state: str,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    revision = "a" * 40
    release, marker, operations = _write_operations_release(
        releases,
        revision,
        "active",
    )
    current = tmp_path / "current"
    current.symlink_to(release)
    wrong_owner_paths: tuple[Path, ...] = ()
    if unsafe_state == "current_regular":
        current.unlink()
        current.write_text("not a link\n")
    elif unsafe_state == "outside_releases":
        outside = tmp_path / "outside" / revision
        outside.mkdir(parents=True)
        current.unlink()
        current.symlink_to(outside)
    elif unsafe_state == "malformed_revision":
        malformed, _, _ = _write_operations_release(
            releases,
            "not-a-revision",
            "malformed",
        )
        current.unlink()
        current.symlink_to(malformed)
    elif unsafe_state == "mutable_release":
        release.chmod(0o775)
    elif unsafe_state == "wrong_owner_release":
        wrong_owner_paths = (release,)
    elif unsafe_state == "mutable_marker":
        marker.chmod(0o664)
    elif unsafe_state == "wrong_owner_marker":
        wrong_owner_paths = (marker,)
    elif unsafe_state == "mutable_script":
        operations.chmod(0o775)
    elif unsafe_state == "wrong_owner_script":
        wrong_owner_paths = (operations,)
    elif unsafe_state == "symlinked_script":
        operations.unlink()
        operations.symlink_to("/bin/sh")
    elif unsafe_state == "marker_mismatch":
        marker.chmod(0o644)
        marker.write_text(f"{'b' * 40}\n")
        marker.chmod(0o444)
    launcher = _write_test_operations_launcher(tmp_path, current, releases)
    trace = tmp_path / "launch.trace"

    result = _run_launcher(
        launcher,
        trace,
        "health",
        wrong_owner_paths=wrong_owner_paths,
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert result.stderr == "Cannot run active Ladle operations.\n"
    assert not trace.exists()
    assert revision not in result.stderr


def test_vps_health_covers_runtime_tls_backup_and_authoritative_revision() -> None:
    operations = OPERATIONS.read_text()

    for service in (
        "edge",
        "api",
        "worker",
        "worker-egress",
        "beat",
        "postgres",
        "redis",
        "minio",
    ):
        assert service in operations
    assert "caddy" not in operations
    assert "nginx -t" in operations
    assert "/health/ready" in operations
    assert "celery" in operations
    assert "inspect ping" in operations
    assert "pg_isready" in operations
    assert "redis-cli ping" in operations
    assert "/minio/health/live" in operations
    assert "openssl s_client" in operations
    assert "openssl x509 -checkend" in operations
    assert "backup is stale" in operations
    assert "/var/lib/ladle/deployment-state" in operations
    assert "/opt/ladle/current" in operations
    assert "STATUS=active" in operations
    assert "PHASE=complete" in operations
    assert ".ladle-revision" in operations
    assert "beat_stability_observations=3" in operations
    assert ".State.Restarting" in operations
    assert ".RestartCount" in operations


def test_operations_never_request_the_removed_ladle_caddy_service(
    tmp_path: Path,
) -> None:
    calls = tmp_path / "compose-calls"
    result = _run_operations_library(
        """
calls=$1
compose() {
    printf '%s\n' "$*" >>"$calls"
    case "$1 $2" in
        "ps -q") printf '%s\n' "$3" ;;
    esac
}
docker() { printf '%s\n' 'true|healthy'; }
beat_is_stable() { :; }
validate_runtime_paths() { runtime_paths_ready=true; }
load_authoritative_release() { :; }
check_nginx() { :; }
check_api() { :; }
check_worker() { :; }
check_postgres() { :; }
check_redis() { :; }
check_minio() { :; }
check_certificate() { :; }
check_backup_freshness() { :; }
check_caddy() {
    printf '%s\n' "legacy caddy health call" >>"$calls"
}
log_transition() { :; }
journalctl() { :; }
health_check
log_lines=20
show_logs
! grep -F caddy "$calls"
""",
        calls,
    )

    assert result.returncode == 0, result.stderr


def test_operations_requires_healthy_worker_egress_container() -> None:
    result = _run_operations_library(
        """
compose() { printf '%s\n' "$3"; }
docker() {
    for container_id do :; done
    if [ "$container_id" = worker-egress ] &&
        [ "$worker_egress_mode" = none ]; then
        printf '%s\n' 'true|none'
    else
        printf '%s\n' 'true|healthy'
    fi
}
beat_is_stable() { :; }
health_failures=
worker_egress_mode=healthy
check_containers
[ -z "$health_failures" ] || exit 1
health_failures=
worker_egress_mode=none
check_containers
printf '%s\n' "$health_failures"
"""
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "worker-egress container"


@pytest.mark.parametrize(
    ("mode", "expected_success"),
    (
        ("stable", True),
        ("identity_change", False),
        ("restart", False),
        ("exit", False),
    ),
)
def test_operations_beat_stability_is_bounded(
    tmp_path: Path,
    mode: str,
    expected_success: bool,
) -> None:
    counter = tmp_path / "beat-observations"
    counter.write_text("0")
    result = _run_operations_library(
        """
counter=$1
mode=$2
compose() {
    count=$(cat "$counter")
    count=$((count + 1))
    printf '%s\n' "$count" >"$counter"
    if [ "$mode" = identity_change ] && [ "$count" -ge 3 ]; then
        printf '%s\n' eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    else
        printf '%s\n' dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    fi
}
docker() {
    count=$(cat "$counter")
    case "$mode:$count" in
        restart:2) printf '%s\n' 'true false 1' ;;
        exit:2) printf '%s\n' 'false false 0' ;;
        *) printf '%s\n' 'true false 0' ;;
    esac
}
sleep() { :; }
beat_is_stable
""",
        counter,
        mode,
    )

    assert (result.returncode == 0) is expected_success, result.stderr
    observations = int(counter.read_text())
    assert 1 <= observations <= 4


def test_vps_operations_expose_bounded_status_logs_health_and_backup() -> None:
    operations = OPERATIONS.read_text()

    for command in ("status)", "logs)", "health)", "backup)"):
        assert command in operations
    assert "journalctl" in operations
    assert "--no-pager" in operations
    assert '-n "$log_lines"' in operations
    assert "docker compose" in operations
    assert 'logs --no-color --tail "$log_lines"' in operations
    assert '--env-file "$env_file"' in operations
    assert "--project-name ladle" in operations
    assert "/etc/ladle/ladle.env" in operations
    assert "LADLE_" not in operations.split("journalctl", maxsplit=1)[-1]
    assert "external notification" in operations


def test_vps_operations_timers_have_expected_schedules() -> None:
    health_timer = HEALTH_TIMER.read_text()
    backup_timer = BACKUP_TIMER.read_text()

    assert "OnBootSec=5min" in health_timer
    assert "OnUnitActiveSec=5min" in health_timer
    assert "Unit=ladle-health.service" in health_timer
    assert "OnCalendar=" in backup_timer
    assert "Persistent=true" in backup_timer
    assert "Unit=ladle-backup.service" in backup_timer

    for unit in (HEALTH_SERVICE, BACKUP_SERVICE):
        text = unit.read_text()
        assert "Type=oneshot" in text
        assert "User=root" in text
        assert "NoNewPrivileges=true" in text
        assert "ProtectSystem=strict" in text
        assert "PrivateTmp=true" in text
    assert "ExecStart=/usr/local/sbin/ladle-operations health" in (
        HEALTH_SERVICE.read_text()
    )
    assert "ExecStart=/usr/local/sbin/ladle-operations backup" in (
        BACKUP_SERVICE.read_text()
    )


def test_operations_installer_validates_exact_release_before_atomic_install() -> None:
    installer = INSTALL_OPERATIONS.read_text()

    assert "/opt/ladle/releases/$revision" in installer
    assert "/opt/ladle/current" not in installer
    assert ".ladle-revision" in installer
    assert "readlink -f" in installer
    assert "stat -c" in installer
    assert "! -user root -o -perm /022" in installer
    assert "systemd-analyze verify" in installer
    assert "mktemp" in installer
    assert "install -o root -g root" in installer
    assert "mv -f --" in installer
    assert "transactional_install_operations" in installer
    assert "rollback_operations_install" in installer
    assert (
        '"$transaction_source_directory/operations-launcher.sh"' in installer
    )
    assert (
        "operations_launcher_source="
        "$script_directory/operations-launcher.sh"
    ) in installer
    transaction = installer[installer.index("transactional_install_operations()") :]
    assert transaction.index("verify_staged_units") < transaction.index(
        "if ! systemctl daemon-reload"
    )
    assert "systemctl enable ladle-health.timer ladle-backup.timer" in installer
    assert "systemctl start ladle-backup.service" in installer
    assert "systemctl start ladle-backup.timer" in installer
    assert "systemctl start ladle-health.timer" in installer
    assert "systemctl disable --now ladle-health.timer ladle-backup.timer" in installer
    assert "/var/backups/ladle" in installer
    assert "/var/lib/ladle/operations" in installer


def test_operations_accept_the_immutable_revision_marker_from_push() -> None:
    push = PUSH.read_text()
    operations = OPERATIONS.read_text()
    installer = INSTALL_OPERATIONS.read_text()

    assert 'chmod 0444 "$incoming/.ladle-revision"' in push
    assert 'safe_regular_file "$revision_marker" 444' in operations
    assert '"0:444"' in installer


def test_backup_refuses_to_race_the_deployment_transaction() -> None:
    operations = OPERATIONS.read_text()
    backup = operations[operations.index("database_backup()") :]

    lock_path = "/var/lib/ladle/locks/deploy.lock"
    assert lock_path in operations
    assert "flock -n" in operations
    authority = backup.index("load_authoritative_release")
    lock = backup.index("acquire_deployment_lock")
    removal = backup.index("remove_incomplete_backup_pairs")
    assert authority < lock < removal
    assert backup.index("acquire_deployment_lock") < backup.index("pg_dump -Fc")
    assert lock_path in BACKUP_SERVICE.read_text()
    assert "/var/lock/ladle-deploy.lock" not in operations
    assert "/var/lock/ladle-deploy.lock" not in BACKUP_SERVICE.read_text()


def test_launcher_shared_lock_is_read_only_for_health_service_sandbox() -> None:
    launcher = OPERATIONS_LAUNCHER.read_text()
    health_service = HEALTH_SERVICE.read_text()

    assert "/var/lib/ladle/locks/authority.lock" in launcher
    assert "/var/lib/ladle/locks/deploy.lock" not in launcher
    assert 'exec 7<"$authority_lock"' in launcher
    assert 'exec 7<>"$authority_lock"' not in launcher
    assert "flock -s 7" in launcher
    assert "/var/lib/ladle/locks/deploy.lock" not in health_service
    assert "/var/lib/ladle/locks/authority.lock" not in health_service
    assert "TimeoutStartSec=2min" in health_service


def test_backup_uses_deploy_fd_with_inherited_authority_reader(
    tmp_path: Path,
) -> None:
    authority_lock = tmp_path / "authority.lock"
    authority_lock.touch()
    authority_lock.chmod(0o600)
    deployment_lock = tmp_path / "deploy.lock"
    deployment_lock.touch()
    deployment_lock.chmod(0o600)
    fake_flock = tmp_path / "flock"
    _write_fake_flock(fake_flock)

    result = _run_operations_library(
        """
authority_lock=$1
deployment_lock=$2
fake_flock=$3
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
flock() { "$fake_flock" "$@"; }
exec 7<"$authority_lock"
"$fake_flock" -s 7
acquire_deployment_lock
""",
        authority_lock,
        deployment_lock,
        fake_flock,
        timeout=5,
    )

    assert result.returncode == 0, result.stderr


def test_backup_fails_fast_and_releases_authority_for_waiting_deployment(
    tmp_path: Path,
) -> None:
    authority_lock = tmp_path / "authority.lock"
    authority_lock.touch()
    authority_lock.chmod(0o600)
    deployment_lock = tmp_path / "deploy.lock"
    deployment_lock.touch()
    deployment_lock.chmod(0o600)
    fake_flock = tmp_path / "flock"
    _write_fake_flock(fake_flock)
    backup_shared = tmp_path / "backup-shared"
    backup_continue = tmp_path / "backup-continue"
    deploy_lock_acquired = tmp_path / "deploy-lock-acquired"
    authority_attempted = tmp_path / "authority-attempted"
    authority_acquired = tmp_path / "authority-acquired"
    backup_process = subprocess.Popen(
        [
            "/bin/sh",
            "-c",
            """. "$1"; shift
authority_lock=$1
deployment_lock=$2
fake_flock=$3
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
flock() {
    "$fake_flock" "$@"
}
exec 7<"$authority_lock"
"$fake_flock" -s 7
: >"$BACKUP_SHARED"
attempt=0
while [ ! -e "$BACKUP_CONTINUE" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 500 ] || exit 1
    sleep 0.01
done
acquire_deployment_lock
""",
            "test",
            str(OPERATIONS),
            str(authority_lock),
            str(deployment_lock),
            str(fake_flock),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            **os.environ,
            "BACKUP_SHARED": str(backup_shared),
            "BACKUP_CONTINUE": str(backup_continue),
        },
        text=True,
    )
    deployment_process: subprocess.Popen[str] | None = None
    try:
        _wait_for_path(backup_shared, process=backup_process)
        deployment_process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                """
import fcntl
import pathlib
import sys

deploy_lock, authority_lock, deploy_acquired, attempted, acquired = map(
    pathlib.Path, sys.argv[1:]
)
with deploy_lock.open("r+") as deploy_descriptor:
    fcntl.flock(deploy_descriptor, fcntl.LOCK_EX)
    deploy_acquired.touch()
    with authority_lock.open("r+") as authority_descriptor:
        attempted.touch()
        fcntl.flock(authority_descriptor, fcntl.LOCK_EX)
        acquired.touch()
""",
                str(deployment_lock),
                str(authority_lock),
                str(deploy_lock_acquired),
                str(authority_attempted),
                str(authority_acquired),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        _wait_for_path(deploy_lock_acquired, process=deployment_process)
        _wait_for_path(authority_attempted, process=deployment_process)
        with pytest.raises(subprocess.TimeoutExpired):
            deployment_process.communicate(timeout=0.2)
        backup_continue.touch()
        _, backup_stderr = backup_process.communicate(timeout=5)
        assert backup_process.returncode != 0
        assert (
            "A deployment is running; backup was not started." in backup_stderr
        )
        _, deployment_stderr = deployment_process.communicate(timeout=5)
        assert deployment_process.returncode == 0, deployment_stderr
        assert authority_acquired.exists()
    finally:
        backup_continue.touch(exist_ok=True)
        if backup_process.poll() is None:
            backup_process.kill()
            backup_process.communicate(timeout=5)
        if deployment_process is not None and deployment_process.poll() is None:
            deployment_process.kill()
            deployment_process.communicate(timeout=5)


def test_operations_transition_log_deduplicates_and_records_recovery(
    tmp_path: Path,
) -> None:
    state = tmp_path / "state"
    state.mkdir()
    log = tmp_path / "operations.log"
    log.touch()

    result = _run_operations_library(
        """
operations_state=$1
operations_log=$2
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
acquire_transition_lock() { :; }
validate_runtime_paths() { runtime_paths_ready=true; }
load_authoritative_release() { :; }
check_containers() { :; }
check_nginx() { :; }
check_api() {
    [ "$health_mode" = healthy ] || append_failure "API readiness"
}
check_worker() { :; }
check_postgres() { :; }
check_redis() { :; }
check_minio() { :; }
check_certificate() { :; }
check_backup_freshness() { :; }
health_mode=failed
health_check || :
health_check || :
health_mode=healthy
health_check
""",
        state,
        log,
    )

    assert result.returncode == 0, result.stderr
    lines = log.read_text().splitlines()
    assert len(lines) == 2
    assert lines[0].endswith("health failed: API readiness")
    assert lines[1].endswith("health healthy: all checks passed")
    assert (state / "health.state").read_text() == "healthy\n"
    assert (state / "health.state").stat().st_mode & 0o777 == 0o600


def test_operations_transition_log_is_serialized_and_append_first(
    tmp_path: Path,
) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")
    (fake_bin / "date").write_text(
        """#!/bin/sh
if [ "${TRANSITION_DELAY:-}" = 1 ]; then
    : >"$TRANSITION_MARKER"
    sleep 1
fi
printf '%s\\n' "$TRANSITION_TIMESTAMP"
"""
    )
    (fake_bin / "date").chmod(0o755)
    state = tmp_path / "state"
    state.mkdir()
    log = tmp_path / "operations.log"
    log.touch()
    lock = tmp_path / "transition.lock"
    lock.touch(mode=0o600)
    marker = tmp_path / "first-date"
    runner = tmp_path / "transition-runner.sh"
    runner.write_text(
        f"""#!/bin/sh
set -eu
. "{OPERATIONS}"
PATH=$1:$PATH
operations_state=$2
operations_log=$3
transition_lock=$4
safe_regular_file() {{ [ -f "$1" ] && [ ! -L "$1" ]; }}
log_transition health "$5" "$6"
"""
    )
    runner.chmod(0o755)
    first_env = {
        **os.environ,
        "TRANSITION_DELAY": "1",
        "TRANSITION_MARKER": str(marker),
        "TRANSITION_TIMESTAMP": "2026-07-28T00:00:01Z",
    }
    second_env = {
        **os.environ,
        "TRANSITION_DELAY": "0",
        "TRANSITION_MARKER": str(marker),
        "TRANSITION_TIMESTAMP": "2026-07-28T00:00:02Z",
    }
    first = subprocess.Popen(
        [
            str(runner),
            str(fake_bin),
            str(state),
            str(log),
            str(lock),
            "failed",
            "first failure",
        ],
        env=first_env,
    )
    for _ in range(300):
        if marker.exists():
            break
        subprocess.run(["/bin/sleep", "0.01"], check=True)
    assert marker.exists()
    second = subprocess.Popen(
        [
            str(runner),
            str(fake_bin),
            str(state),
            str(log),
            str(lock),
            "healthy",
            "recovered",
        ],
        env=second_env,
    )

    assert first.wait(timeout=5) == 0
    assert second.wait(timeout=5) == 0
    transition_lines = [
        line.split(" ", maxsplit=1)[1] for line in log.read_text().splitlines()
    ]
    assert transition_lines == [
        "health failed: first failure",
        "health healthy: recovered",
    ]
    assert (state / "health.state").read_text() == "healthy\n"


def test_operations_transition_state_failure_retries_without_losing_log(
    tmp_path: Path,
) -> None:
    state = tmp_path / "state"
    state.mkdir()
    log = tmp_path / "operations.log"
    log.touch()
    result = _run_operations_library(
        """
operations_state=$1
operations_log=$2
acquire_transition_lock() { :; }
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
fail_state_write=true
mv() {
    if [ "$fail_state_write" = true ]; then
        fail_state_write=false
        return 1
    fi
    command mv "$@"
}
log_transition health failed "fixed failure" || :
log_transition health failed "fixed failure"
log_transition health failed "fixed failure"
""",
        state,
        log,
    )

    assert result.returncode == 0, result.stderr
    assert len(log.read_text().splitlines()) == 2
    assert (state / "health.state").read_text() == "failed\n"


def test_operations_transition_interruption_retries_without_losing_log(
    tmp_path: Path,
) -> None:
    state = tmp_path / "state"
    state.mkdir()
    log = tmp_path / "operations.log"
    log.touch()
    marker = tmp_path / "state-write"
    command = """
. "$1"
shift
operations_state=$1
operations_log=$2
marker=$3
acquire_transition_lock() { :; }
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
mktemp() {
    : >"$marker"
    sleep 30
    command mktemp "$@"
}
log_transition health failed "interrupted failure"
"""
    process = subprocess.Popen(
        [
            "/bin/sh",
            "-c",
            command,
            "test",
            str(OPERATIONS),
            str(state),
            str(log),
            str(marker),
        ],
        start_new_session=True,
    )
    for _ in range(300):
        if marker.exists():
            break
        subprocess.run(["/bin/sleep", "0.01"], check=True)
    assert marker.exists()
    os.killpg(process.pid, signal.SIGTERM)
    assert process.wait(timeout=5) != 0
    assert len(log.read_text().splitlines()) == 1
    assert not (state / "health.state").exists()

    retry = _run_operations_library(
        """
operations_state=$1
operations_log=$2
acquire_transition_lock() { :; }
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
log_transition health failed "interrupted failure"
log_transition health failed "interrupted failure"
""",
        state,
        log,
    )
    assert retry.returncode == 0, retry.stderr
    assert len(log.read_text().splitlines()) == 2
    assert (state / "health.state").read_text() == "failed\n"


def test_operations_deployment_lock_is_actually_contended(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_flock(fake_bin / "flock")
    lock = tmp_path / "deploy.lock"
    lock.touch(mode=0o600)
    marker = tmp_path / "held"
    holder = tmp_path / "holder.sh"
    holder.write_text(
        f"""#!/bin/sh
set -eu
. "{OPERATIONS}"
PATH=$1:$PATH
deployment_lock=$2
safe_regular_file() {{ [ -f "$1" ] && [ ! -L "$1" ]; }}
acquire_deployment_lock
printf '%s\\n' held >"$3"
sleep 1
"""
    )
    holder.chmod(0o755)
    process = subprocess.Popen(
        [str(holder), str(fake_bin), str(lock), str(marker)],
        env=os.environ,
    )
    for _ in range(100):
        if marker.exists():
            break
        subprocess.run(["/bin/sleep", "0.01"], check=True)
    assert marker.exists()

    contended = _run_operations_library(
        """
PATH=$1:$PATH
deployment_lock=$2
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
acquire_deployment_lock
""",
        fake_bin,
        lock,
    )
    assert contended.returncode != 0
    assert process.wait(timeout=5) == 0
    available = _run_operations_library(
        """
PATH=$1:$PATH
deployment_lock=$2
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
acquire_deployment_lock
""",
        fake_bin,
        lock,
    )
    assert available.returncode == 0, available.stderr


@pytest.mark.parametrize(
    ("failure", "published_pair"),
    (
        ("pg_dump", False),
        ("date", False),
        ("empty_dump", False),
        ("pg_restore", False),
        ("chmod_dump", False),
        ("digest_command", False),
        ("digest_shape", False),
        ("checksum_write", False),
        ("chmod_checksum", False),
        ("publish_dump", False),
        ("publish_checksum", False),
        ("sync", True),
        ("retention", True),
        ("stat", True),
        ("log", True),
    ),
)
def test_backup_failures_are_explicit_and_leave_no_orphans(
    tmp_path: Path,
    failure: str,
    published_pair: bool,
) -> None:
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    log = tmp_path / "transitions"
    result = _run_operations_library(
        """
failure=$1
backup_dir=$2
operations_state=$3
operations_log=$4
runtime_paths_ready=true
validate_runtime_paths() { runtime_paths_ready=true; }
acquire_deployment_lock() { :; }
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
load_authoritative_release() { :; }
check_postgres() { health_failures=; }
compose() {
    case "$*" in
        *"pg_dump -Fc"*)
            [ "$failure" != pg_dump ] || return 1
            [ "$failure" = empty_dump ] || command printf '%s' archive
            ;;
        *"pg_restore --list"*)
            cat >/dev/null
            [ "$failure" != pg_restore ]
            ;;
        *) return 1 ;;
    esac
}
df() {
    command printf '%s\n' \
        "Filesystem 1024-blocks Used Available Capacity Mounted" \
        "test 99999999 1 99999998 1% /"
}
date() {
    [ "$failure" != date ] || return 1
    command date "$@"
}
chmod() {
    case "$failure:$*" in
        chmod_dump:*".ladle-backup."*) return 1 ;;
        chmod_checksum:*".ladle-checksum."*) return 1 ;;
    esac
    command chmod "$@"
}
sha256sum() {
    [ "$failure" != digest_command ] || return 1
    if [ "$failure" = digest_shape ]; then
        command printf '%s  %s\n' abc "$1"
    else
        command printf '%064d  %s\n' 0 "$1"
    fi
}
printf() {
    if [ "$failure" = checksum_write ] && [ "$#" -eq 3 ]; then
        return 1
    fi
    command printf "$@"
}
mv() {
    case "$failure:$*" in
        publish_dump:*".ladle-backup."*) return 1 ;;
        publish_checksum:*".ladle-checksum."*) return 1 ;;
    esac
    command mv "$@"
}
sync() { [ "$failure" != sync ]; }
find() { [ "$failure" != retention ]; }
stat() {
    [ "$failure" != stat ] || return 1
    command printf '%s\n' 7
}
log_transition() {
    [ "$failure" != log ] || return 1
    command printf '%s %s %s\n' "$1" "$2" "$3" >>"$operations_log"
}
run_backup
""",
        failure,
        backup_dir,
        state,
        log,
    )

    assert result.returncode != 0
    assert "backup ready:" not in result.stdout
    assert "healthy" not in log.read_text() if log.exists() else True
    assert not list(backup_dir.glob(".ladle-*"))
    dumps = list(backup_dir.glob("ladle-*.dump"))
    checksums = list(backup_dir.glob("ladle-*.dump.sha256"))
    assert bool(dumps) is published_pair
    assert bool(checksums) is published_pair


def test_backup_success_requires_a_validated_complete_pair(tmp_path: Path) -> None:
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    log = tmp_path / "transitions"
    result = _run_operations_library(
        """
failure=none
backup_dir=$1
operations_state=$2
operations_log=$3
runtime_paths_ready=true
validate_runtime_paths() { runtime_paths_ready=true; }
acquire_deployment_lock() { :; }
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
load_authoritative_release() { :; }
check_postgres() { health_failures=; }
compose() {
    case "$*" in
        *"pg_dump -Fc"*) command printf '%s' archive ;;
        *"pg_restore --list"*) cat >/dev/null ;;
        *) return 1 ;;
    esac
}
df() {
    command printf '%s\n' \
        "Filesystem 1024-blocks Used Available Capacity Mounted" \
        "test 99999999 1 99999998 1% /"
}
sha256sum() { command printf '%064d  %s\n' 0 "$1"; }
sync() { :; }
find() { :; }
stat() { command printf '%s\n' 7; }
log_transition() {
    command printf '%s %s %s\n' "$1" "$2" "$3" >>"$operations_log"
}
run_backup
""",
        backup_dir,
        state,
        log,
    )

    assert result.returncode == 0, result.stderr
    assert "backup ready:" in result.stdout
    assert "backup healthy validated archive" in log.read_text()
    dumps = list(backup_dir.glob("ladle-*.dump"))
    checksums = list(backup_dir.glob("ladle-*.dump.sha256"))
    assert len(dumps) == len(checksums) == 1
    assert dumps[0].stat().st_mode & 0o777 == 0o600
    assert checksums[0].stat().st_mode & 0o777 == 0o600


def test_backup_signal_after_first_publish_removes_filesystem_orphan(
    tmp_path: Path,
) -> None:
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    result = _run_operations_library(
        """
backup_dir=$1
runtime_paths_ready=true
validate_runtime_paths() { runtime_paths_ready=true; }
acquire_deployment_lock() { :; }
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
remove_incomplete_backup_pairs() { :; }
load_authoritative_release() { :; }
check_postgres() { health_failures=; }
compose() {
    case "$*" in
        *"pg_dump -Fc"*) command printf '%s' archive ;;
        *"pg_restore --list"*) cat >/dev/null ;;
        *) return 1 ;;
    esac
}
df() {
    command printf '%s\n' \
        "Filesystem 1024-blocks Used Available Capacity Mounted" \
        "test 99999999 1 99999998 1% /"
}
sha256sum() { command printf '%064d  %s\n' 0 "$1"; }
mv() {
    command mv "$@"
    for destination do :; done
    case "${destination##*/}" in
        ladle-*.dump)
            kill -TERM $$
            ;;
    esac
}
run_backup
""",
        backup_dir,
    )

    assert result.returncode != 0
    assert not list(backup_dir.glob("ladle-*.dump"))
    assert not list(backup_dir.glob("ladle-*.dump.sha256"))
    assert not list(backup_dir.glob(".ladle-*"))


def test_backup_start_removes_incomplete_pairs_but_keeps_complete_pair(
    tmp_path: Path,
) -> None:
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    orphan_dump = backup_dir / "ladle-20260728-000001-1.dump"
    orphan_checksum = backup_dir / "ladle-20260728-000002-1.dump.sha256"
    complete_dump = backup_dir / "ladle-20260728-000003-1.dump"
    complete_checksum = Path(f"{complete_dump}.sha256")
    for path in (orphan_dump, orphan_checksum, complete_dump, complete_checksum):
        path.write_text(path.name)
        path.chmod(0o600)

    result = _run_operations_library(
        """
backup_dir=$1
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
remove_incomplete_backup_pairs
""",
        backup_dir,
    )

    assert result.returncode == 0, result.stderr
    assert not orphan_dump.exists()
    assert not orphan_checksum.exists()
    assert complete_dump.exists()
    assert complete_checksum.exists()


def test_backup_freshness_selects_older_valid_complete_pair(tmp_path: Path) -> None:
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    older_dump = backup_dir / "ladle-20260728-000001-1.dump"
    older_checksum = Path(f"{older_dump}.sha256")
    newest_orphan = backup_dir / "ladle-20260728-000002-1.dump"
    older_dump.write_text("validated archive")
    older_checksum.write_text(f"{'0' * 64}  {older_dump.name}\n")
    newest_orphan.write_text("orphan")
    for path in (older_dump, older_checksum, newest_orphan):
        path.chmod(0o600)

    result = _run_operations_library(
        """
backup_dir=$1
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
find() {
    printf '%s\n' \
        "200.0 $backup_dir/ladle-20260728-000002-1.dump" \
        "100.0 $backup_dir/ladle-20260728-000001-1.dump"
}
stat() {
    case "$*" in
        *000001*) printf '%s\n' 100 ;;
        *) printf '%s\n' 200 ;;
    esac
}
sha256sum() {
    case "$*" in *000001*) return 0 ;; *) return 1 ;; esac
}
latest_backup_path
""",
        backup_dir,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(older_dump)


@pytest.mark.parametrize(
    ("invalid_newest", "expected_hashes"),
    (
        (False, (35,)),
        (True, (35, 34)),
    ),
)
def test_backup_freshness_hashes_only_until_newest_valid_pair(
    tmp_path: Path,
    invalid_newest: bool,
    expected_hashes: tuple[int, ...],
) -> None:
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    for index in range(1, 36):
        dump = backup_dir / f"ladle-20260728-000001-{index}.dump"
        checksum = Path(f"{dump}.sha256")
        dump.write_text(f"archive {index}\n")
        checksum.write_text(f"{'0' * 64}  {dump.name}\n")
        dump.chmod(0o600)
        checksum.chmod(0o600)
    hash_log = tmp_path / "hashes"
    result = _run_operations_library(
        """
backup_dir=$1
hash_log=$2
invalid_newest=$3
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
find() {
    candidate_index=35
    while [ "$candidate_index" -ge 1 ]; do
        printf '%s.0 %s/ladle-20260728-000001-%s.dump\n' \
            "$candidate_index" "$backup_dir" "$candidate_index"
        candidate_index=$((candidate_index - 1))
    done
}
date() { printf '%s\n' 1000; }
stat() { printf '%s\n' 999; }
sha256sum() {
    for checksum_argument do :; done
    checksum_name=${checksum_argument##*/}
    checksum_index=${checksum_name##*-}
    checksum_index=${checksum_index%%.*}
    printf '%s\n' "$checksum_index" >>"$hash_log"
    if [ "$invalid_newest" = true ] && [ "$checksum_index" -eq 35 ]; then
        return 1
    fi
}
health_failures=
check_backup_freshness
[ -z "$health_failures" ]
""",
        backup_dir,
        hash_log,
        str(invalid_newest).lower(),
    )

    assert result.returncode == 0, result.stderr
    assert tuple(map(int, hash_log.read_text().splitlines())) == expected_hashes


def test_backup_retention_removes_complete_pair_together(tmp_path: Path) -> None:
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    dump = backup_dir / "ladle-20260101-000001-1.dump"
    checksum = Path(f"{dump}.sha256")
    dump.write_text("old archive")
    checksum.write_text(f"{'0' * 64}  {dump.name}\n")
    dump.chmod(0o600)
    checksum.chmod(0o600)

    result = _run_operations_library(
        """
backup_dir=$1
safe_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
find() { printf '%s\n' "$1"; }
retain_backup_pairs
""",
        backup_dir,
    )

    assert result.returncode == 0, result.stderr
    assert not dump.exists()
    assert not checksum.exists()


@pytest.mark.parametrize(
    "failure",
    ("stage", "verify", "swap", "daemon", "enable", "start"),
)
@pytest.mark.parametrize("preexisting", (False, True))
def test_operations_installer_rolls_back_every_failure(
    tmp_path: Path,
    failure: str,
    preexisting: bool,
) -> None:
    source = tmp_path / "source"
    source.mkdir()
    binary_source = source / "operations-launcher.sh"
    binary_source.write_text("#!/bin/sh\nprintf '%s\\n' new-launcher\n")
    binary_source.chmod(0o755)
    unit_names = (
        "ladle-health.service",
        "ladle-health.timer",
        "ladle-backup.service",
        "ladle-backup.timer",
    )
    for name in unit_names:
        (source / name).write_text(f"[Unit]\nDescription=new {name}\n")
    binary_dir = tmp_path / "sbin"
    unit_dir = tmp_path / "systemd"
    binary_dir.mkdir()
    unit_dir.mkdir()
    binary_target = binary_dir / "ladle-operations"
    targets = (binary_target, *(unit_dir / name for name in unit_names))
    if preexisting:
        for target in targets:
            target.write_text(f"old:{target.name}\n")
            target.chmod(0o755 if target == binary_target else 0o644)

    fake_bin = tmp_path / "bin"
    _write_operations_installer_fakes(fake_bin)
    fake_state = tmp_path / "systemctl.trace"
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={
            "FAIL_PHASE": failure,
            "FAKE_STATE": str(fake_state),
            "PREVIOUS_TIMERS_ACTIVE": (
                "1" if failure == "start" and preexisting else "0"
            ),
        },
    )

    assert result.returncode != 0
    for target in targets:
        if preexisting:
            assert target.read_text() == f"old:{target.name}\n"
        else:
            assert not target.exists()
    assert not list(binary_dir.glob(".ladle-*"))
    assert not list(unit_dir.glob(".ladle-*"))
    trace = fake_state.read_text() if fake_state.exists() else ""
    assert "Ladle health and backup timers installed" not in result.stdout
    if failure in {"enable", "start"}:
        assert "disable --now ladle-health.timer ladle-backup.timer" in trace
        assert trace.count("daemon-reload") >= 2
    if failure == "start" and preexisting:
        assert "enable ladle-health.timer" in trace
        assert "enable ladle-backup.timer" in trace
        assert trace.count("start ladle-health.timer") >= 1
        assert trace.count("start ladle-backup.timer") >= 1


def test_operations_installer_commits_the_whole_file_set_together(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source"
    source.mkdir()
    binary_source = source / "operations-launcher.sh"
    binary_source.write_text("#!/bin/sh\nprintf '%s\\n' new-launcher\n")
    binary_source.chmod(0o755)
    unit_names = (
        "ladle-health.service",
        "ladle-health.timer",
        "ladle-backup.service",
        "ladle-backup.timer",
    )
    for name in unit_names:
        (source / name).write_text(f"[Unit]\nDescription=new {name}\n")
    binary_dir = tmp_path / "sbin"
    unit_dir = tmp_path / "systemd"
    binary_dir.mkdir()
    unit_dir.mkdir()
    binary_target = binary_dir / "ladle-operations"
    fake_bin = tmp_path / "bin"
    _write_operations_installer_fakes(fake_bin)
    fake_state = tmp_path / "systemctl.trace"

    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={"FAIL_PHASE": "none", "FAKE_STATE": str(fake_state)},
    )

    assert result.returncode == 0, result.stderr
    assert binary_target.read_text() == binary_source.read_text()
    assert binary_target.stat().st_mode & 0o777 == 0o755
    for name in unit_names:
        target = unit_dir / name
        assert target.read_text() == (source / name).read_text()
        assert target.stat().st_mode & 0o777 == 0o644
    trace = fake_state.read_text()
    assert "daemon-reload" in trace
    assert "enable ladle-health.timer ladle-backup.timer" in trace
    initial_backup = trace.index("start ladle-backup.service")
    backup_timer = trace.index("start ladle-backup.timer")
    health_timer = trace.index("start ladle-health.timer")
    assert initial_backup < backup_timer < health_timer
    assert "start ladle-health.timer ladle-backup.timer" not in trace


def test_operations_refresh_classifies_absent_complete_and_unsafe_sets(
    tmp_path: Path,
) -> None:
    unit_names = (
        "ladle-health.service",
        "ladle-health.timer",
        "ladle-backup.service",
        "ladle-backup.timer",
    )

    def classify(root: Path) -> subprocess.CompletedProcess[str]:
        binary = root / "sbin" / "ladle-operations"
        units = root / "systemd"
        binary.parent.mkdir(parents=True, exist_ok=True)
        units.mkdir(exist_ok=True)
        return _run_installer_library(
            """
target_metadata_is_safe() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    case "$3" in
        755) [ -x "$1" ] ;;
        644) [ ! -x "$1" ] ;;
        *) return 1 ;;
    esac
}
installed_operations_state "$1" "$2" "$3"
""",
            binary,
            units,
            str(os.getuid()),
        )

    absent_root = tmp_path / "absent"
    absent = classify(absent_root)
    complete_root = tmp_path / "complete"
    complete_binary = complete_root / "sbin" / "ladle-operations"
    complete_binary.parent.mkdir(parents=True)
    complete_binary.write_text("old\n")
    complete_binary.chmod(0o755)
    complete_units = complete_root / "systemd"
    complete_units.mkdir()
    for name in unit_names:
        (complete_units / name).write_text("old\n")
        (complete_units / name).chmod(0o644)
    complete = classify(complete_root)
    partial_root = tmp_path / "partial"
    partial_binary = partial_root / "sbin" / "ladle-operations"
    partial_binary.parent.mkdir(parents=True)
    partial_binary.write_text("partial\n")
    partial_binary.chmod(0o755)
    partial = classify(partial_root)
    unsafe_root = tmp_path / "unsafe"
    unsafe_binary = unsafe_root / "sbin" / "ladle-operations"
    unsafe_binary.parent.mkdir(parents=True)
    unsafe_binary.write_text("unsafe\n")
    unsafe_binary.chmod(0o644)
    unsafe_units = unsafe_root / "systemd"
    unsafe_units.mkdir()
    for name in unit_names:
        (unsafe_units / name).write_text("old\n")
        (unsafe_units / name).chmod(0o644)
    unsafe = classify(unsafe_root)

    assert absent.returncode == 0
    assert absent.stdout == "absent\n"
    assert complete.returncode == 0
    assert complete.stdout == "complete\n"
    assert partial.returncode != 0
    assert unsafe.returncode != 0


def test_operations_refresh_replaces_files_without_touching_timer_state(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5" refresh
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={"FAIL_PHASE": "none", "FAKE_STATE": str(fake_state)},
    )

    assert result.returncode == 0, result.stderr
    for target in targets:
        source_name = (
            "operations-launcher.sh" if target == binary_target else target.name
        )
        assert target.read_text() == (source / source_name).read_text()
    assert fake_state.read_text().splitlines() == ["daemon-reload"]


def test_operations_refresh_rolls_back_files_when_reload_fails(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5" refresh
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={"FAIL_PHASE": "daemon", "FAKE_STATE": str(fake_state)},
    )

    assert result.returncode != 0
    for target in targets:
        assert target.read_text() == f"old:{target.name}\n"
    trace = fake_state.read_text()
    assert "enable " not in trace
    assert "start " not in trace
    assert "disable " not in trace


def test_refreshed_launcher_stays_bound_to_current_across_failed_activation(
    tmp_path: Path,
) -> None:
    releases = tmp_path / "releases"
    releases.mkdir()
    old_release, _, _ = _write_operations_release(
        releases,
        "a" * 40,
        "old",
    )
    new_release, _, _ = _write_operations_release(
        releases,
        "b" * 40,
        "new",
    )
    current = tmp_path / "current"
    current.symlink_to(old_release)
    test_launcher = _write_test_operations_launcher(tmp_path, current, releases)
    install_root = tmp_path / "install"
    install_root.mkdir()
    source, binary_target, unit_dir, _, fake_bin, fake_state = (
        _operations_installer_fixture(install_root, preexisting=True)
    )
    launcher_source = source / "operations-launcher.sh"
    launcher_source.write_text(test_launcher.read_text())
    launcher_source.chmod(0o755)
    for unit_source in (HEALTH_SERVICE, HEALTH_TIMER, BACKUP_SERVICE, BACKUP_TIMER):
        shutil.copyfile(unit_source, source / unit_source.name)

    refresh = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5" refresh
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={"FAIL_PHASE": "none", "FAKE_STATE": str(fake_state)},
    )
    failed_activation = _run_library_script(
        """
mv() { return 1; }
activate_release "$1" "$2"
""",
        new_release,
        current,
    )
    trace = tmp_path / "launch.trace"
    after_failure = _run_launcher(binary_target, trace, "health")
    successful_activation = _run_deployment_library(
        "activate_release",
        new_release,
        current,
    )
    after_success = _run_launcher(binary_target, trace, "backup")

    assert refresh.returncode == 0, refresh.stderr
    assert failed_activation.returncode != 0
    assert after_failure.returncode == 0, after_failure.stderr
    assert successful_activation.returncode == 0, successful_activation.stderr
    assert after_success.returncode == 0, after_success.stderr
    assert trace.read_text().splitlines() == [
        f"old:{old_release}:health",
        f"new:{new_release}:backup",
    ]
    assert fake_state.read_text().splitlines() == ["daemon-reload"]
    for installed_unit in unit_dir.iterdir():
        unit_text = installed_unit.read_text()
        assert "/usr/local/sbin/ladle-operations" in unit_text or (
            installed_unit.suffix == ".timer"
        )
        assert "/opt/ladle/releases/" not in unit_text
        assert "a" * 40 not in unit_text
        assert "b" * 40 not in unit_text


@pytest.mark.parametrize("preexisting", (False, True))
def test_operations_installer_rolls_back_when_initial_backup_fails(
    tmp_path: Path,
    preexisting: bool,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=preexisting)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={
            "FAIL_PHASE": "initial_backup",
            "FAKE_STATE": str(fake_state),
            "PREVIOUS_TIMERS_ACTIVE": "1" if preexisting else "0",
            "TIMERS_NOT_FOUND": "0" if preexisting else "1",
        },
    )

    assert result.returncode != 0
    for target in targets:
        if preexisting:
            assert target.read_text() == f"old:{target.name}\n"
        else:
            assert not target.exists()
    assert not list(binary_target.parent.glob(".ladle-*"))
    assert not list(unit_dir.glob(".ladle-*"))
    trace = fake_state.read_text()
    activation_trace = trace.split(
        "disable --now ladle-health.timer ladle-backup.timer",
        maxsplit=1,
    )[0]
    assert "start ladle-backup.service" in activation_trace
    assert "start ladle-backup.timer" not in activation_trace
    assert "start ladle-health.timer" not in activation_trace
    assert "disable --now ladle-health.timer ladle-backup.timer" in trace
    if preexisting:
        assert "enable ladle-health.timer" in trace
        assert "enable ladle-backup.timer" in trace
        assert "start ladle-health.timer" in trace
        assert "start ladle-backup.timer" in trace


def test_operations_installer_rejects_timer_query_error_before_live_swap(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={
            "FAIL_PHASE": "none",
            "FAKE_STATE": str(fake_state),
            "QUERY_FAILURE": "1",
        },
    )

    assert result.returncode != 0
    assert "Cannot safely snapshot prior Ladle timer state" in result.stderr
    for target in targets:
        assert target.read_text() == f"old:{target.name}\n"
    assert not list(binary_target.parent.glob(".ladle-*"))
    assert not list(unit_dir.glob(".ladle-*"))
    trace = fake_state.read_text()
    assert "daemon-reload" not in trace
    assert "\nenable " not in f"\n{trace}"
    assert "\nstart " not in f"\n{trace}"
    assert "\ndisable " not in f"\n{trace}"


def test_operations_installer_accepts_first_install_not_found_timer_state(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=False)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={
            "FAIL_PHASE": "none",
            "FAKE_STATE": str(fake_state),
            "TIMERS_NOT_FOUND": "1",
        },
    )

    assert result.returncode == 0, result.stderr
    trace = fake_state.read_text()
    assert trace.count("is-enabled") == 2
    assert "is-active" not in trace
    for target in targets:
        assert target.exists()
        assert "new" in target.read_text()


@pytest.mark.parametrize(
    "rollback_failure",
    ("disable", "reload", "enable", "start"),
)
def test_operations_installer_reports_timer_reconciliation_failure(
    tmp_path: Path,
    rollback_failure: str,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={
            "FAIL_PHASE": "start",
            "FAKE_STATE": str(fake_state),
            "PREVIOUS_TIMERS_ACTIVE": "1",
            "ROLLBACK_FAILURE": rollback_failure,
        },
    )

    assert result.returncode != 0
    assert (
        "rollback incomplete; timer state or loaded units require inspection"
        in result.stderr
    )
    assert "prior state restored" not in result.stderr
    for target in targets:
        assert target.read_text() == f"old:{target.name}\n"


@pytest.mark.parametrize("preexisting", (False, True))
def test_operations_installer_rolls_back_when_signaled_during_swap(
    tmp_path: Path,
    preexisting: bool,
) -> None:
    assert "trap '' HUP INT TERM" in INSTALL_OPERATIONS.read_text()
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=preexisting)
    )
    command = """
. "$1"
shift
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
"""
    process = subprocess.Popen(
        [
            "/bin/sh",
            "-c",
            command,
            "test",
            str(INSTALL_OPERATIONS),
            str(fake_bin),
            str(source),
            str(binary_target),
            str(unit_dir),
            str(os.getuid()),
        ],
        env={
            **os.environ,
            "FAIL_PHASE": "none",
            "FAKE_STATE": str(fake_state),
            "PAUSE_SWAP": "1",
        },
        start_new_session=True,
    )
    signal_marker = Path(f"{fake_state}.signal")
    for _ in range(300):
        if signal_marker.exists():
            break
        subprocess.run(["/bin/sleep", "0.01"], check=True)
    assert signal_marker.exists()

    os.killpg(process.pid, signal.SIGTERM)
    assert process.wait(timeout=10) != 0
    for target in targets:
        if preexisting:
            assert target.read_text() == f"old:{target.name}\n"
        else:
            assert not target.exists()
    assert not list(binary_target.parent.glob(".ladle-*"))
    assert not list(unit_dir.glob(".ladle-*"))
    assert "daemon-reload" in fake_state.read_text()


def test_operations_installer_cleanup_warning_does_not_undo_commit(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={
            "FAIL_PHASE": "cleanup",
            "FAKE_STATE": str(fake_state),
        },
    )

    assert result.returncode == 0, result.stderr
    assert "committed; stale rollback files require cleanup" in result.stderr
    for target in targets:
        assert "new" in target.read_text()
    trace = fake_state.read_text()
    assert "start ladle-backup.service" in trace
    assert "start ladle-backup.timer" in trace
    assert "start ladle-health.timer" in trace


def test_operations_installer_preserves_recovery_copy_when_restore_fails(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={"FAIL_PHASE": "restore", "FAKE_STATE": str(fake_state)},
    )

    assert result.returncode != 0
    assert "rollback incomplete" in result.stderr
    assert "root-only recovery files remain as .ladle-backup.*" in result.stderr
    assert "prior state restored" not in result.stderr
    assert "new-launcher" in binary_target.read_text()
    recovery = [
        *binary_target.parent.glob(".ladle-backup.*"),
        *unit_dir.glob(".ladle-backup.*"),
    ]
    assert recovery
    assert all(path.stat().st_mode & 0o777 in {0o644, 0o755} for path in recovery)
    assert not list(binary_target.parent.glob(".ladle-stage.*"))
    assert not list(unit_dir.glob(".ladle-stage.*"))
    assert any("old:ladle-operations" in path.read_text() for path in recovery)
    assert all(target.exists() for target in targets)


def test_operations_installer_reports_stage_cleanup_after_targets_restore(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={"FAIL_PHASE": "stage_cleanup", "FAKE_STATE": str(fake_state)},
    )

    assert result.returncode != 0
    assert "targets were restored" in result.stderr
    assert "stale root-only .ladle-stage.* artifacts may remain" in result.stderr
    assert "recovery files remain as .ladle-backup.*" not in result.stderr
    assert not [
        *binary_target.parent.glob(".ladle-backup.*"),
        *unit_dir.glob(".ladle-backup.*"),
    ]
    assert [
        *binary_target.parent.glob(".ladle-stage.*"),
        *unit_dir.glob(".ladle-stage.*"),
    ]
    for target in targets:
        assert target.read_text() == f"old:{target.name}\n"


def test_operations_installer_reports_first_install_target_removal_failure(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=False)
    )
    result = _run_installer_library(
        """
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
""",
        fake_bin,
        source,
        binary_target,
        unit_dir,
        str(os.getuid()),
        env={"FAIL_PHASE": "remove_new_target", "FAKE_STATE": str(fake_state)},
    )

    assert result.returncode != 0
    assert "mixed/new targets may remain and require root inspection" in result.stderr
    assert "recovery files remain as .ladle-backup.*" not in result.stderr
    assert "new-launcher" in binary_target.read_text()
    assert not [
        *binary_target.parent.glob(".ladle-backup.*"),
        *unit_dir.glob(".ladle-backup.*"),
    ]
    assert all(not target.exists() for target in targets if target != binary_target)


def test_operations_installer_committed_signal_exits_success_with_warning(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    command = """
. "$1"
shift
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
"""
    process = subprocess.Popen(
        [
            "/bin/sh",
            "-c",
            command,
            "test",
            str(INSTALL_OPERATIONS),
            str(fake_bin),
            str(source),
            str(binary_target),
            str(unit_dir),
            str(os.getuid()),
        ],
        env={
            **os.environ,
            "FAIL_PHASE": "commit_signal_cleanup",
            "FAKE_STATE": str(fake_state),
        },
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    cleanup_marker = Path(f"{fake_state}.committed-cleanup")
    for _ in range(300):
        if cleanup_marker.exists():
            break
        subprocess.run(["/bin/sleep", "0.01"], check=True)
    assert cleanup_marker.exists()

    os.killpg(process.pid, signal.SIGTERM)
    _, stderr = process.communicate(timeout=10)
    assert process.returncode == 0
    assert "committed; stale rollback files require cleanup" in stderr
    for target in targets:
        assert "new" in target.read_text()
    assert [
        *binary_target.parent.glob(".ladle-backup.*"),
        *unit_dir.glob(".ladle-backup.*"),
    ]


def test_operations_installer_ignores_second_signal_during_rollback(
    tmp_path: Path,
) -> None:
    source, binary_target, unit_dir, targets, fake_bin, fake_state = (
        _operations_installer_fixture(tmp_path, preexisting=True)
    )
    command = """
. "$1"
shift
PATH=$1:$PATH
transactional_install_operations "$2" "$3" "$4" "$5"
"""
    process = subprocess.Popen(
        [
            "/bin/sh",
            "-c",
            command,
            "test",
            str(INSTALL_OPERATIONS),
            str(fake_bin),
            str(source),
            str(binary_target),
            str(unit_dir),
            str(os.getuid()),
        ],
        env={
            **os.environ,
            "FAIL_PHASE": "none",
            "FAKE_STATE": str(fake_state),
            "PAUSE_SWAP": "1",
            "PAUSE_ROLLBACK": "1",
        },
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    signal_marker = Path(f"{fake_state}.signal")
    rollback_marker = Path(f"{fake_state}.rollback")
    for _ in range(300):
        if signal_marker.exists():
            break
        subprocess.run(["/bin/sleep", "0.01"], check=True)
    assert signal_marker.exists()
    os.killpg(process.pid, signal.SIGTERM)
    for _ in range(300):
        if rollback_marker.exists():
            break
        subprocess.run(["/bin/sleep", "0.01"], check=True)
    assert rollback_marker.exists()

    os.kill(process.pid, signal.SIGTERM)
    _, stderr = process.communicate(timeout=10)
    assert process.returncode != 0
    assert "prior state restored" in stderr
    assert "rollback incomplete" not in stderr
    for target in targets:
        assert target.read_text() == f"old:{target.name}\n"


GATEWAY_TEST_REVISION = "a" * 40
GATEWAY_TEST_HOSTNAME = "staging.example.test"
GATEWAY_TEST_SECRET = "gatewaySecret123"
LEGACY_CADDY_NAME = "ladle-caddy-1"
SHARED_GATEWAY_NAME = "platform-gateway-gateway-1"


def _write_gateway_fake_docker(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import signal
import sys
import time

state_path = os.environ["FAKE_DOCKER_STATE"]
trace_path = os.environ["FAKE_DOCKER_TRACE"]
with open(state_path) as source:
    state = json.load(source)
arguments = sys.argv[1:]
with open(trace_path, "a") as trace:
    trace.write(json.dumps(arguments) + "\\n")

def save():
    temporary = state_path + ".next"
    with open(temporary, "w") as target:
        json.dump(state, target)
    os.replace(temporary, state_path)

def container(target):
    if target in state.get("containers", {}):
        return state["containers"][target]
    for candidate in state.get("containers", {}).values():
        if candidate.get("id") == target:
            return candidate
    raise SystemExit(1)

if arguments[:1] == ["version"]:
    if state.get("docker_unavailable"):
        raise SystemExit(1)
    print("29.0.0")
elif arguments[:2] == ["network", "inspect"]:
    network = state.get("network")
    if network is None:
        raise SystemExit(1)
    template = arguments[arguments.index("--format") + 1]
    if ".Driver" in template:
        print(network["driver"])
        print(network["scope"])
        print(str(network["internal"]).lower())
        print(len(network["subnets"]))
        for subnet in network["subnets"]:
            print(subnet)
        print(network["label"])
    elif ".Containers" in template:
        for name in network["containers"]:
            print(state["containers"][name]["id"])
    else:
        raise SystemExit("unsupported network inspect format")
elif arguments[:2] == ["network", "create"]:
    expected = [
        "network", "create", "--driver", "bridge",
        "--subnet", "172.30.0.0/24",
        "--label", "com.ladle.platform.network=shared-edge-v1",
        "platform-edge",
    ]
    if arguments != expected:
        raise SystemExit("unsafe network create")
    state["network_create_calls"] = state.get("network_create_calls", 0) + 1
    mode = state.get("network_create_mode", "success")
    if mode in {"success", "race"}:
        state["network"] = {
            "driver": "bridge",
            "scope": "local",
            "internal": False,
            "subnets": ["172.30.0.0/24"],
            "label": "shared-edge-v1",
            "containers": [],
        }
    save()
    if mode == "success":
        print("platform-edge")
    else:
        raise SystemExit(1)
elif arguments[:1] == ["inspect"]:
    target = arguments[-1]
    item = container(target)
    template = arguments[arguments.index("--format") + 1]
    if ".Aliases" in template:
        for alias in item.get("aliases", []):
            print(alias)
    elif (
        "com.docker.compose.project" in template
        and ".State.Running" not in template
    ):
        print(item["project"])
        print(item["service"])
    elif "PortBindings" in template:
        health = item.get("health", "none")
        ports = item.get("ports", [])
        print(
            f'{str(item["running"]).lower()}|{health}|'
            f'{",".join(str(port) for port in ports)}'
        )
    elif ".State.Running" in template:
        print(
            f'{item["project"]}|{item["service"]}|'
            f'{str(item["running"]).lower()}|{item.get("health", "none")}'
        )
    else:
        raise SystemExit("unsupported container inspect format")
elif arguments[:1] == ["run"]:
    expected_tail = [
        "--rm", "--network", "platform-edge", "--entrypoint", "wget",
        state["gateway_image"], "-q", "-T", "5", "-O", "/dev/null",
        "http://ladle-edge:8082/health/ready",
    ]
    if arguments[1:] != expected_tail:
        raise SystemExit("unsafe readiness probe")
    if state.get("probe_failure"):
        raise SystemExit(1)
elif arguments[:1] == ["stop"]:
    target = arguments[-1]
    item = container(target)
    item["running"] = False
    save()
    if target == "ladle-caddy-1" and state.get("signal_during_stop"):
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(0.2)
        raise SystemExit(1)
    print(target)
elif arguments[:1] == ["start"]:
    target = arguments[-1]
    item = container(target)
    if target == "ladle-caddy-1" and state.get("legacy_start_failure"):
        raise SystemExit(1)
    if (
        target == "platform-gateway-gateway-1"
        and state.get("gateway_restore_failure")
    ):
        raise SystemExit(1)
    item["running"] = True
    if (
        target == "ladle-caddy-1"
        and state.get("legacy_health_failure")
    ):
        item["health"] = "unhealthy"
    elif target == "platform-gateway-gateway-1":
        item["health"] = "healthy"
    save()
    print(target)
elif arguments[:1] == ["compose"]:
    compose_file = arguments[arguments.index("-f") + 1]
    command_index = arguments.index("-f") + 2
    command = arguments[command_index:]
    if not compose_file.endswith("/docker-compose.yml"):
        raise SystemExit("unsafe compose file")
    if command == ["config", "--quiet"]:
        if state.get("config_failure"):
            raise SystemExit(1)
    elif command == [
        "run", "--rm", "--no-deps", "gateway", "caddy", "validate",
        "--config", "/etc/caddy/Caddyfile",
    ]:
        if state.get("caddy_validation_failure"):
            raise SystemExit(1)
    elif command == [
        "up", "-d", "--wait", "--wait-timeout", "120", "gateway"
    ]:
        shared = state["containers"].setdefault(
            "platform-gateway-gateway-1",
            {
                "id": "g" * 64,
                "project": "platform-gateway",
                "service": "gateway",
                "running": True,
                "health": "healthy",
                "ports": [80, 443, 443],
                "aliases": [],
            },
        )
        shared["running"] = True
        shared["health"] = (
            "unhealthy" if state.get("gateway_health_failure") else "healthy"
        )
        save()
        if state.get("signal_during_up"):
            os.kill(os.getppid(), signal.SIGTERM)
            time.sleep(0.2)
            raise SystemExit(1)
        if state.get("gateway_up_failure"):
            raise SystemExit(1)
    elif command == ["down", "--timeout", "20"]:
        shared = state["containers"].get("platform-gateway-gateway-1")
        if shared:
            shared["running"] = False
            shared["health"] = "none"
            save()
    else:
        raise SystemExit(f"unsupported compose command: {command!r}")
else:
    raise SystemExit(f"unsupported docker command: {arguments!r}")
"""
    )
    path.chmod(0o755)


def _write_gateway_fake_flock(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import fcntl
import os
import sys

arguments = sys.argv[1:]
shared = arguments[:1] == ["-s"]
descriptor = int(arguments[-1])
mode = "shared" if shared else "exclusive"
trace_path = os.environ["FAKE_FLOCK_TRACE"]
with open(trace_path, "a") as trace:
    trace.write(f"attempt {mode} {descriptor}\\n")
replacement = os.environ.get("FAKE_REPLACE_AUTHORITY_ON_FLOCK")
if replacement:
    temporary = replacement + ".replacement"
    with open(temporary, "w") as target:
        target.write("replacement\\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, replacement)
fcntl.flock(
    descriptor,
    fcntl.LOCK_SH if shared else fcntl.LOCK_EX,
)
with open(trace_path, "a") as trace:
    trace.write(f"acquired {mode} {descriptor}\\n")
"""
    )
    path.chmod(0o755)


def _write_gateway_fake_stat(path: Path) -> None:
    helper = path.with_name("stat-open-fd")
    helper.write_text(
        """#!/usr/bin/env python3
import os
import stat
import sys

metadata = os.fstat(int(sys.argv[1].rsplit("/", maxsplit=1)[1]))
print(
    f"{metadata.st_dev}:{metadata.st_ino}:"
    f"{metadata.st_uid}:{stat.S_IMODE(metadata.st_mode):o}"
)
"""
    )
    helper.chmod(0o755)
    path.write_text(
        f"""#!/bin/sh
for stat_target do :; done
case "$stat_target" in
    /dev/fd/*) exec {shlex.quote(str(helper))} "$stat_target" ;;
    *) exec /usr/bin/stat "$@" ;;
esac
"""
    )
    path.chmod(0o755)


def _gateway_default_state(
    *,
    network: dict[str, object] | bool | None = True,
    include_edge: bool = True,
    include_legacy: bool = True,
    include_gateway: bool = False,
) -> dict[str, object]:
    containers: dict[str, object] = {}
    network_containers: list[str] = []
    if include_edge:
        containers["ladle-edge-container"] = {
            "id": "e" * 64,
            "project": "ladle",
            "service": "edge",
            "running": True,
            "health": "healthy",
            "ports": [],
            "aliases": ["ladle-edge"],
        }
        network_containers.append("ladle-edge-container")
    if include_legacy:
        containers[LEGACY_CADDY_NAME] = {
            "id": "c" * 64,
            "project": "ladle",
            "service": "caddy",
            "running": True,
            "health": "healthy",
            "ports": [80, 443, 443],
            "aliases": [],
        }
    if include_gateway:
        containers[SHARED_GATEWAY_NAME] = {
            "id": "g" * 64,
            "project": "platform-gateway",
            "service": "gateway",
            "running": False,
            "health": "none",
            "ports": [80, 443, 443],
            "aliases": [],
        }
    if network is True:
        network = {
            "driver": "bridge",
            "scope": "local",
            "internal": False,
            "subnets": ["172.30.0.0/24"],
            "label": "shared-edge-v1",
            "containers": network_containers,
        }
    return {
        "network": network,
        "network_create_mode": "success",
        "containers": containers,
        "gateway_image": (
            "caddy:2.11.4-alpine@sha256:"
            "5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"
        ),
    }


def _gateway_harness(
    tmp_path: Path,
    *,
    state: dict[str, object] | None = None,
) -> dict[str, Path | dict[str, object]]:
    assert GATEWAY_MANAGE.exists(), "missing shared gateway manager"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_docker = fake_bin / "docker"
    _write_gateway_fake_docker(fake_docker)
    _write_gateway_fake_flock(fake_bin / "flock")
    _write_gateway_fake_stat(fake_bin / "stat")
    fake_find = fake_bin / "find"
    fake_find.write_text(
        """#!/bin/sh
[ "${FAKE_FIND_FAILURE:-0}" != 1 ] || exit 71
exec /usr/bin/find "$@"
"""
    )
    fake_find.chmod(0o755)
    fake_sleep = fake_bin / "sleep"
    fake_sleep.write_text("#!/bin/sh\nexit 0\n")
    fake_sleep.chmod(0o755)
    fake_getent = fake_bin / "getent"
    fake_getent.write_text(
        f"""#!/bin/sh
[ "$1:$2" = "group:ladle-secrets" ] || exit 1
printf '%s\\n' 'ladle-secrets:x:{os.getgid()}:'
"""
    )
    fake_getent.chmod(0o755)

    filesystem = tmp_path / "system"
    releases = filesystem / "opt" / "ladle" / "releases"
    release = releases / GATEWAY_TEST_REVISION
    release_backend = release / "Backend"
    shutil.copytree(BACKEND / "deploy", release_backend / "deploy")
    marker = release / ".ladle-revision"
    marker.write_text(f"{GATEWAY_TEST_REVISION}\n")
    marker.chmod(0o444)

    live_platform = filesystem / "opt" / "platform"
    platform_env_dir = filesystem / "etc" / "platform"
    app_env = filesystem / "etc" / "ladle" / "ladle.env"
    authority_lock = filesystem / "var" / "lib" / "ladle" / "locks" / (
        "authority.lock"
    )
    app_env.parent.mkdir(parents=True)
    app_env.write_text(
        "\n".join(
            (
                f"LADLE_PUBLIC_HOSTNAME={GATEWAY_TEST_HOSTNAME}",
                "UNRELATED_VALUE=preserved",
                f"LADLE_TUNNEL_ACCESS_KEY={GATEWAY_TEST_SECRET}",
                "",
            )
        )
    )
    app_env.chmod(0o640)
    authority_lock.parent.mkdir(parents=True)
    authority_lock.parent.chmod(0o700)

    manager = release_backend / "deploy" / "vps" / "gateway" / "manage.sh"
    rendered = manager.read_text()
    replacements = {
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin": (
            f"PATH={fake_bin}:/usr/local/sbin:/usr/local/bin:"
            "/usr/sbin:/usr/bin:/sbin:/bin"
        ),
        "/opt/ladle/releases": str(releases),
        "/opt/platform": str(live_platform),
        "/etc/platform": str(platform_env_dir),
        "/etc/ladle/ladle.env": str(app_env),
        "/var/lib/ladle/locks": str(authority_lock.parent),
        "root_uid=0": f"root_uid={os.getuid()}",
        "root_gid=0": f"root_gid={os.getgid()}",
    }
    for original, replacement in replacements.items():
        rendered = rendered.replace(original, replacement)
    manager.write_text(rendered)
    manager.chmod(0o755)

    state_file = tmp_path / "docker-state.json"
    state_file.write_text(
        json.dumps(state if state is not None else _gateway_default_state())
    )
    trace = tmp_path / "docker-trace.jsonl"
    flock_trace = tmp_path / "flock.trace"
    flock_trace.touch()
    return {
        "manager": manager,
        "release": release,
        "gateway_source": manager.parent,
        "live_gateway": live_platform / "gateway",
        "gateway_env": platform_env_dir / "gateway.env",
        "app_env": app_env,
        "authority_lock": authority_lock,
        "state_file": state_file,
        "trace": trace,
        "flock_trace": flock_trace,
        "fake_bin": fake_bin,
    }


def _run_gateway_manager(
    harness: dict[str, Path | dict[str, object]],
    command: str,
    *,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(harness["manager"]), command],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "FAKE_DOCKER_STATE": str(harness["state_file"]),
            "FAKE_DOCKER_TRACE": str(harness["trace"]),
            "FAKE_FLOCK_TRACE": str(harness["flock_trace"]),
            **(extra_env or {}),
        },
        text=True,
        timeout=10,
    )


def _popen_gateway_manager(
    harness: dict[str, Path | dict[str, object]],
    command: str,
) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [str(harness["manager"]), command],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            **os.environ,
            "FAKE_DOCKER_STATE": str(harness["state_file"]),
            "FAKE_DOCKER_TRACE": str(harness["trace"]),
            "FAKE_FLOCK_TRACE": str(harness["flock_trace"]),
        },
        text=True,
    )


def _start_gateway_lock_holder(
    lock: Path,
    *,
    shared: bool,
) -> subprocess.Popen[str]:
    holder = subprocess.Popen(
        [
            sys.executable,
            "-u",
            "-c",
            """
import fcntl
import sys

with open(sys.argv[1]) as lock:
    fcntl.flock(
        lock.fileno(),
        fcntl.LOCK_SH if sys.argv[2] == "shared" else fcntl.LOCK_EX,
    )
    print("locked", flush=True)
    sys.stdin.read()
""",
            str(lock),
            "shared" if shared else "exclusive",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert holder.stdout is not None
    assert holder.stdout.readline() == "locked\n"
    return holder


def _release_gateway_lock_holder(holder: subprocess.Popen[str]) -> None:
    assert holder.stdin is not None
    holder.stdin.close()
    assert holder.wait(timeout=5) == 0


def _wait_for_gateway_flock_trace(
    trace: Path,
    start: int,
    expected: str,
) -> bool:
    for _ in range(200):
        if expected in trace.read_text().splitlines()[start:]:
            return True
        time.sleep(0.01)
    return False


def _gateway_state(
    harness: dict[str, Path | dict[str, object]],
) -> dict[str, Any]:
    loaded = json.loads(Path(harness["state_file"]).read_text())
    assert isinstance(loaded, dict)
    return loaded


def _gateway_trace(
    harness: dict[str, Path | dict[str, object]],
) -> list[list[str]]:
    trace = Path(harness["trace"])
    if not trace.exists():
        return []
    return [json.loads(line) for line in trace.read_text().splitlines()]


def _prepare_gateway(
    harness: dict[str, Path | dict[str, object]],
) -> subprocess.CompletedProcess[str]:
    result = _run_gateway_manager(harness, "prepare")
    assert result.returncode == 0, result.stderr
    return result


def test_gateway_management_entrypoint_is_root_only_and_requires_one_command(
    tmp_path: Path,
) -> None:
    assert GATEWAY_MANAGE.exists()
    assert GATEWAY_MANAGE.stat().st_mode & stat.S_IXUSR
    harness = _gateway_harness(tmp_path)
    manager = Path(harness["manager"])

    nonroot_text = manager.read_text().replace(
        f"root_uid={os.getuid()}",
        f"root_uid={os.getuid() + 1}",
        1,
    )
    manager.write_text(nonroot_text)
    nonroot = _run_gateway_manager(harness, "status")
    assert nonroot.returncode != 0
    assert "root" in nonroot.stderr.casefold()

    manager.write_text(
        nonroot_text.replace(
            f"root_uid={os.getuid() + 1}",
            f"root_uid={os.getuid()}",
            1,
        )
    )
    missing = subprocess.run(
        [str(manager)],
        check=False,
        capture_output=True,
        env={
            **os.environ,
            "FAKE_DOCKER_STATE": str(harness["state_file"]),
            "FAKE_DOCKER_TRACE": str(harness["trace"]),
        },
        text=True,
    )
    invalid = _run_gateway_manager(harness, "destroy")
    assert missing.returncode != 0
    assert invalid.returncode != 0
    assert "prepare|activate|rollback|status" in missing.stderr
    assert "prepare|activate|rollback|status" in invalid.stderr


@pytest.mark.parametrize("shell", ("/bin/sh", "/bin/dash"))
def test_gateway_management_is_posix_shell_syntax(shell: str) -> None:
    if not Path(shell).exists():
        pytest.skip(f"{shell} is unavailable")
    result = subprocess.run(
        [shell, "-n", str(GATEWAY_MANAGE)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_gateway_management_prepare_extracts_only_required_values_atomically(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)

    result = _prepare_gateway(harness)

    gateway_env = Path(harness["gateway_env"])
    assert gateway_env.read_text() == (
        f"LADLE_PUBLIC_HOSTNAME={GATEWAY_TEST_HOSTNAME}\n"
        f"LADLE_TUNNEL_ACCESS_KEY={GATEWAY_TEST_SECRET}\n"
    )
    assert stat.S_IMODE(gateway_env.stat().st_mode) == 0o600
    assert gateway_env.stat().st_uid == os.getuid()
    assert Path(harness["authority_lock"]).exists()
    assert stat.S_IMODE(Path(harness["authority_lock"]).stat().st_mode) == 0o600
    assert GATEWAY_TEST_SECRET not in result.stdout
    assert GATEWAY_TEST_SECRET not in result.stderr
    serialized_trace = json.dumps(_gateway_trace(harness))
    assert GATEWAY_TEST_SECRET not in serialized_trace
    assert not list(gateway_env.parent.glob(".gateway.env.*"))

    commands = _gateway_trace(harness)
    assert any(command[-2:] == ["config", "--quiet"] for command in commands)
    assert any(
        command[-5:]
        == [
            "gateway",
            "caddy",
            "validate",
            "--config",
            "/etc/caddy/Caddyfile",
            ][-5:]
        for command in commands
    )
    forbidden = {"stop", "start", "up", "80:80", "443:443"}
    assert all(not forbidden.intersection(command) for command in commands)


@pytest.mark.parametrize(
    "unsafe_source",
    ("wrong-marker", "mutable-route", "symlink-asset", "symlink-entrypoint"),
)
def test_gateway_management_prepare_requires_exact_immutable_release(
    tmp_path: Path,
    unsafe_source: str,
) -> None:
    harness = _gateway_harness(tmp_path)
    source = Path(harness["gateway_source"])
    if unsafe_source == "wrong-marker":
        marker = Path(harness["release"]) / ".ladle-revision"
        marker.chmod(0o644)
        marker.write_text(f"{'b' * 40}\n")
        marker.chmod(0o444)
    elif unsafe_source == "mutable-route":
        (source / "routes" / "ladle.caddy").chmod(0o666)
    elif unsafe_source == "symlink-asset":
        route = source / "routes" / "ladle.caddy"
        route.unlink()
        route.symlink_to(GATEWAY_LADLE_ROUTE)
    else:
        manager = Path(harness["manager"])
        actual = manager.with_name("manage-real.sh")
        manager.rename(actual)
        manager.symlink_to(actual)

    result = _run_gateway_manager(harness, "prepare")

    assert result.returncode != 0
    assert not Path(harness["gateway_env"]).exists()
    assert not Path(harness["live_gateway"]).exists()


def test_gateway_management_prepare_rejects_release_traversal_failure(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)

    result = _run_gateway_manager(
        harness,
        "prepare",
        extra_env={"FAKE_FIND_FAILURE": "1"},
    )

    assert result.returncode != 0
    assert "travers" in result.stderr.casefold()
    assert not Path(harness["gateway_env"]).exists()
    assert not Path(harness["live_gateway"]).exists()


@pytest.mark.parametrize(
    "unsafe_environment",
    ("symlink", "wrong-mode", "duplicate", "shell-syntax", "bad-hostname"),
)
def test_gateway_management_prepare_rejects_unsafe_app_environment(
    tmp_path: Path,
    unsafe_environment: str,
) -> None:
    harness = _gateway_harness(tmp_path)
    app_env = Path(harness["app_env"])
    if unsafe_environment == "symlink":
        actual = app_env.with_name("actual.env")
        app_env.rename(actual)
        app_env.symlink_to(actual)
    elif unsafe_environment == "wrong-mode":
        app_env.chmod(0o644)
    elif unsafe_environment == "duplicate":
        with app_env.open("a") as target:
            target.write(f"LADLE_PUBLIC_HOSTNAME={GATEWAY_TEST_HOSTNAME}\n")
    elif unsafe_environment == "shell-syntax":
        app_env.write_text(
            "LADLE_PUBLIC_HOSTNAME=$(touch /tmp/gateway-owned)\n"
            f"LADLE_TUNNEL_ACCESS_KEY={GATEWAY_TEST_SECRET}\n"
        )
    else:
        app_env.write_text(
            "LADLE_PUBLIC_HOSTNAME=bad host\n"
            f"LADLE_TUNNEL_ACCESS_KEY={GATEWAY_TEST_SECRET}\n"
        )
    if unsafe_environment not in {"symlink", "wrong-mode"}:
        app_env.chmod(0o640)

    result = _run_gateway_manager(harness, "prepare")

    assert result.returncode != 0
    assert GATEWAY_TEST_SECRET not in result.stdout
    assert GATEWAY_TEST_SECRET not in result.stderr
    assert not Path(harness["gateway_env"]).exists()
    assert not Path("/tmp/gateway-owned").exists()


def test_gateway_management_prepare_is_idempotent_and_preserves_future_routes(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(
        tmp_path,
        state=_gateway_default_state(network=None),
    )
    state = _gateway_state(harness)
    state["network_create_mode"] = "success"
    Path(harness["state_file"]).write_text(json.dumps(state))

    first = _prepare_gateway(harness)
    future_route = Path(harness["live_gateway"]) / "routes" / "future.caddy"
    future_route.write_text("future.example.test { respond 204 }\n")
    future_route.chmod(0o644)
    second = _prepare_gateway(harness)

    assert first.stdout == second.stdout
    assert future_route.read_text() == "future.example.test { respond 204 }\n"
    assert _gateway_state(harness)["network_create_calls"] == 1


def test_gateway_management_prepare_waits_for_shared_authority_holder(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    authority_lock = Path(harness["authority_lock"])
    flock_trace = Path(harness["flock_trace"])
    flock_start = len(flock_trace.read_text().splitlines())
    holder = _start_gateway_lock_holder(authority_lock, shared=True)
    process = _popen_gateway_manager(harness, "prepare")
    try:
        attempted = _wait_for_gateway_flock_trace(
            flock_trace,
            flock_start,
            "attempt exclusive 7",
        )
        blocked = process.poll() is None
        app_env = Path(harness["app_env"])
        app_env.write_text(
            app_env.read_text().replace(
                GATEWAY_TEST_HOSTNAME,
                "final.example.test",
            )
        )
    finally:
        _release_gateway_lock_holder(holder)
    stdout, stderr = process.communicate(timeout=10)

    assert attempted
    assert blocked
    assert process.returncode == 0, stderr
    assert stdout == "Gateway prepared.\n"
    assert (
        "LADLE_PUBLIC_HOSTNAME=final.example.test\n"
        in Path(harness["gateway_env"]).read_text()
    )


@pytest.mark.parametrize("action", ("activate", "rollback"))
def test_gateway_management_handoff_waits_for_deploy_exclusive_authority(
    tmp_path: Path,
    action: str,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    if action == "rollback":
        activated = _run_gateway_manager(harness, "activate")
        assert activated.returncode == 0, activated.stderr
    trace_start = len(_gateway_trace(harness))
    flock_trace = Path(harness["flock_trace"])
    flock_start = len(flock_trace.read_text().splitlines())
    holder = _start_gateway_lock_holder(
        Path(harness["authority_lock"]),
        shared=False,
    )
    process = _popen_gateway_manager(harness, action)
    try:
        attempted = _wait_for_gateway_flock_trace(
            flock_trace,
            flock_start,
            "attempt exclusive 7",
        )
        blocked = process.poll() is None
        waiting_commands = _gateway_trace(harness)[trace_start:]
    finally:
        _release_gateway_lock_holder(holder)
    _, stderr = process.communicate(timeout=10)

    assert attempted
    assert blocked
    assert all(
        not {"start", "stop", "up", "down"}.intersection(command)
        for command in waiting_commands
    )
    assert process.returncode == 0, stderr


def test_gateway_management_rejects_authority_inode_replacement_on_acquire(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    trace_start = len(_gateway_trace(harness))

    result = _run_gateway_manager(
        harness,
        "prepare",
        extra_env={
            "FAKE_REPLACE_AUTHORITY_ON_FLOCK": str(
                harness["authority_lock"]
            )
        },
    )

    assert result.returncode != 0
    assert "authority" in result.stderr.casefold()
    commands = _gateway_trace(harness)[trace_start:]
    assert all(
        not {"start", "stop", "up", "down", "run", "create"}.intersection(
            command
        )
        for command in commands
    )


def test_gateway_management_status_shares_authority_lock_without_mutation(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    trace_start = len(_gateway_trace(harness))
    flock_trace = Path(harness["flock_trace"])
    flock_start = len(flock_trace.read_text().splitlines())
    shared_holder = _start_gateway_lock_holder(
        Path(harness["authority_lock"]),
        shared=True,
    )
    status = _popen_gateway_manager(harness, "status")
    try:
        _, shared_stderr = status.communicate(timeout=2)
    finally:
        _release_gateway_lock_holder(shared_holder)

    assert status.returncode == 0, shared_stderr
    assert flock_trace.read_text().splitlines()[flock_start:] == [
        "attempt shared 6",
        "acquired shared 6",
    ]
    status_commands = _gateway_trace(harness)[trace_start:]
    assert all(
        not {"start", "stop", "up", "down", "run", "create"}.intersection(
            command
        )
        for command in status_commands
    )

    exclusive_holder = _start_gateway_lock_holder(
        Path(harness["authority_lock"]),
        shared=False,
    )
    flock_start = len(flock_trace.read_text().splitlines())
    blocked_status = _popen_gateway_manager(harness, "status")
    try:
        attempted = _wait_for_gateway_flock_trace(
            flock_trace,
            flock_start,
            "attempt shared 6",
        )
        blocked = blocked_status.poll() is None
    finally:
        _release_gateway_lock_holder(exclusive_holder)
    _, exclusive_stderr = blocked_status.communicate(timeout=10)
    assert attempted
    assert blocked
    assert blocked_status.returncode == 0, exclusive_stderr


def test_gateway_management_prepare_rejects_unsafe_live_paths(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    live_gateway = Path(harness["live_gateway"])
    live_gateway.parent.mkdir(parents=True)
    actual = live_gateway.with_name("gateway-actual")
    actual.mkdir()
    live_gateway.symlink_to(actual)

    result = _run_gateway_manager(harness, "prepare")

    assert result.returncode != 0
    assert not Path(harness["gateway_env"]).exists()


def test_gateway_management_prepare_rejects_unsafe_future_route(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    routes = Path(harness["live_gateway"]) / "routes"
    unsafe_target = routes.parent / "unsafe-target.caddy"
    unsafe_target.write_text("unsafe.example.test { respond 204 }\n")
    (routes / "future.caddy").symlink_to(unsafe_target)

    result = _run_gateway_manager(harness, "prepare")

    assert result.returncode != 0
    assert (routes / "future.caddy").is_symlink()


@pytest.mark.parametrize("unsafe_state", ("symlink", "wrong-mode"))
def test_gateway_management_prepare_rejects_unsafe_existing_gateway_environment(
    tmp_path: Path,
    unsafe_state: str,
) -> None:
    harness = _gateway_harness(tmp_path)
    gateway_env = Path(harness["gateway_env"])
    gateway_env.parent.mkdir(parents=True)
    gateway_env.parent.chmod(0o700)
    actual = gateway_env
    if unsafe_state == "symlink":
        actual = gateway_env.with_name("gateway-actual.env")
    actual.write_text(
        f"LADLE_PUBLIC_HOSTNAME={GATEWAY_TEST_HOSTNAME}\n"
        f"LADLE_TUNNEL_ACCESS_KEY={GATEWAY_TEST_SECRET}\n"
    )
    actual.chmod(0o644 if unsafe_state == "wrong-mode" else 0o600)
    if unsafe_state == "symlink":
        gateway_env.symlink_to(actual)

    result = _run_gateway_manager(harness, "prepare")

    assert result.returncode != 0
    if unsafe_state == "symlink":
        assert gateway_env.is_symlink()
    else:
        assert stat.S_IMODE(gateway_env.stat().st_mode) == 0o644


def test_gateway_management_prepare_rejects_malformed_existing_network(
    tmp_path: Path,
) -> None:
    malformed = _valid_platform_network()
    malformed["subnets"] = ["172.29.0.0/24"]
    harness = _gateway_harness(
        tmp_path,
        state=_gateway_default_state(network=malformed),
    )

    result = _run_gateway_manager(harness, "prepare")

    assert result.returncode != 0
    assert _gateway_state(harness).get("network_create_calls", 0) == 0


@pytest.mark.parametrize("failure", ("config_failure", "caddy_validation_failure"))
def test_gateway_management_prepare_fails_closed_on_config_validation(
    tmp_path: Path,
    failure: str,
) -> None:
    state = _gateway_default_state()
    state[failure] = True
    harness = _gateway_harness(tmp_path, state=state)

    result = _run_gateway_manager(harness, "prepare")

    assert result.returncode != 0
    commands = _gateway_trace(harness)
    assert not any("stop" in command or "up" in command for command in commands)


@pytest.mark.parametrize("edge_state", ("missing", "foreign", "unreachable"))
def test_gateway_management_activate_rejects_untrusted_or_unreachable_edge(
    tmp_path: Path,
    edge_state: str,
) -> None:
    state = _gateway_default_state(include_edge=edge_state != "missing")
    if edge_state == "unreachable":
        state["probe_failure"] = True
    harness = _gateway_harness(tmp_path, state=state)
    _prepare_gateway(harness)
    if edge_state == "foreign":
        prepared_state = _gateway_state(harness)
        prepared_state["containers"]["ladle-edge-container"]["project"] = "foreign"
        Path(harness["state_file"]).write_text(json.dumps(prepared_state))

    result = _run_gateway_manager(harness, "activate")

    assert result.returncode != 0
    current = _gateway_state(harness)
    assert current["containers"][LEGACY_CADDY_NAME]["running"] is True
    assert SHARED_GATEWAY_NAME not in current["containers"]


def test_gateway_management_activate_rejects_foreign_legacy_container(
    tmp_path: Path,
) -> None:
    state = _gateway_default_state()
    state["containers"][LEGACY_CADDY_NAME]["service"] = "api"
    harness = _gateway_harness(tmp_path, state=state)
    _prepare_gateway(harness)

    result = _run_gateway_manager(harness, "activate")

    assert result.returncode != 0
    assert _gateway_state(harness)["containers"][LEGACY_CADDY_NAME]["running"]


def test_gateway_management_activate_swaps_only_listener_containers(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    before = _gateway_state(harness)["containers"]["ladle-edge-container"].copy()

    result = _run_gateway_manager(harness, "activate")

    assert result.returncode == 0, result.stderr
    state = _gateway_state(harness)
    assert state["containers"][LEGACY_CADDY_NAME]["running"] is False
    shared = state["containers"][SHARED_GATEWAY_NAME]
    assert shared["running"] is True
    assert shared["health"] == "healthy"
    assert shared["ports"] == [80, 443, 443]
    assert state["containers"]["ladle-edge-container"] == before
    commands = _gateway_trace(harness)
    stopped = [command[-1] for command in commands if command[:1] == ["stop"]]
    assert stopped == [LEGACY_CADDY_NAME]
    assert not any(
        service in json.dumps(commands)
        for service in ("postgres", "redis", "minio", "api", "worker", "beat")
    )
    assert GATEWAY_TEST_SECRET not in json.dumps(commands)
    assert GATEWAY_TEST_SECRET not in result.stdout + result.stderr


@pytest.mark.parametrize("failure", ("gateway_up_failure", "gateway_health_failure"))
def test_gateway_management_activate_failure_restores_legacy_listener(
    tmp_path: Path,
    failure: str,
) -> None:
    state = _gateway_default_state()
    state[failure] = True
    harness = _gateway_harness(tmp_path, state=state)
    _prepare_gateway(harness)

    result = _run_gateway_manager(harness, "activate")

    assert result.returncode != 0
    current = _gateway_state(harness)
    assert current["containers"][LEGACY_CADDY_NAME]["running"] is True
    shared = current["containers"].get(SHARED_GATEWAY_NAME)
    assert shared is None or shared["running"] is False
    trace = _gateway_trace(harness)
    assert any(command[-2:] == ["--timeout", "20"] for command in trace)
    assert ["start", LEGACY_CADDY_NAME] in trace


def test_gateway_management_activation_recovery_avoids_unhealthy_legacy_ports(
    tmp_path: Path,
) -> None:
    state = _gateway_default_state()
    state["gateway_up_failure"] = True
    state["legacy_health_failure"] = True
    harness = _gateway_harness(tmp_path, state=state)
    _prepare_gateway(harness)

    result = _run_gateway_manager(harness, "activate")

    assert result.returncode != 0
    current = _gateway_state(harness)
    assert current["containers"][LEGACY_CADDY_NAME]["running"] is False
    assert current["containers"][SHARED_GATEWAY_NAME]["running"] is True
    trace = _gateway_trace(harness)
    legacy_start = trace.index(["start", LEGACY_CADDY_NAME])
    legacy_stop = trace.index(
        ["stop", "--time", "30", LEGACY_CADDY_NAME],
        legacy_start,
    )
    shared_start = trace.index(["start", SHARED_GATEWAY_NAME], legacy_stop)
    assert legacy_start < legacy_stop < shared_start


@pytest.mark.parametrize(
    "signal_point",
    ("signal_during_stop", "signal_during_up"),
)
def test_gateway_management_activate_signal_restores_legacy_listener(
    tmp_path: Path,
    signal_point: str,
) -> None:
    state = _gateway_default_state()
    state[signal_point] = True
    harness = _gateway_harness(tmp_path, state=state)
    _prepare_gateway(harness)

    result = _run_gateway_manager(harness, "activate")

    assert result.returncode != 0
    current = _gateway_state(harness)
    assert current["containers"][LEGACY_CADDY_NAME]["running"] is True
    shared = current["containers"].get(SHARED_GATEWAY_NAME)
    assert shared is None or shared["running"] is False


def test_gateway_management_rollback_restores_preserved_legacy_listener(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    activated = _run_gateway_manager(harness, "activate")
    assert activated.returncode == 0, activated.stderr

    result = _run_gateway_manager(harness, "rollback")

    assert result.returncode == 0, result.stderr
    state = _gateway_state(harness)
    assert state["containers"][SHARED_GATEWAY_NAME]["running"] is False
    assert state["containers"][LEGACY_CADDY_NAME]["running"] is True
    trace = _gateway_trace(harness)
    shared_stop = trace.index(["stop", "--time", "30", SHARED_GATEWAY_NAME])
    legacy_start = trace.index(["start", LEGACY_CADDY_NAME], shared_stop)
    assert shared_stop < legacy_start


def test_gateway_management_rollback_failure_restores_shared_listener(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    activated = _run_gateway_manager(harness, "activate")
    assert activated.returncode == 0, activated.stderr
    state = _gateway_state(harness)
    state["legacy_start_failure"] = True
    Path(harness["state_file"]).write_text(json.dumps(state))

    result = _run_gateway_manager(harness, "rollback")

    assert result.returncode != 0
    current = _gateway_state(harness)
    assert current["containers"][LEGACY_CADDY_NAME]["running"] is False
    assert current["containers"][SHARED_GATEWAY_NAME]["running"] is True
    assert current["containers"][SHARED_GATEWAY_NAME]["health"] == "healthy"


def test_gateway_management_rollback_stops_unhealthy_legacy_before_shared(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    activated = _run_gateway_manager(harness, "activate")
    assert activated.returncode == 0, activated.stderr
    state = _gateway_state(harness)
    state["legacy_health_failure"] = True
    Path(harness["state_file"]).write_text(json.dumps(state))
    trace_start = len(_gateway_trace(harness))

    result = _run_gateway_manager(harness, "rollback")

    assert result.returncode != 0
    current = _gateway_state(harness)
    assert current["containers"][LEGACY_CADDY_NAME]["running"] is False
    assert current["containers"][SHARED_GATEWAY_NAME]["running"] is True
    recovery = _gateway_trace(harness)[trace_start:]
    legacy_start = recovery.index(["start", LEGACY_CADDY_NAME])
    legacy_stop = recovery.index(
        ["stop", "--time", "30", LEGACY_CADDY_NAME],
        legacy_start,
    )
    shared_start = recovery.index(
        ["start", SHARED_GATEWAY_NAME],
        legacy_stop,
    )
    assert legacy_start < legacy_stop < shared_start
    assert "shared gateway was restored" in result.stderr.casefold()


def test_gateway_management_reports_listener_risk_when_shared_restore_fails(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    activated = _run_gateway_manager(harness, "activate")
    assert activated.returncode == 0, activated.stderr
    state = _gateway_state(harness)
    state["legacy_health_failure"] = True
    state["gateway_restore_failure"] = True
    Path(harness["state_file"]).write_text(json.dumps(state))

    result = _run_gateway_manager(harness, "rollback")

    assert result.returncode != 0
    assert "both-listeners risk" in result.stderr.casefold()
    current = _gateway_state(harness)
    assert current["containers"][LEGACY_CADDY_NAME]["running"] is False
    assert current["containers"][SHARED_GATEWAY_NAME]["running"] is False


def test_gateway_management_status_is_read_only_and_rejects_inconsistency(
    tmp_path: Path,
) -> None:
    harness = _gateway_harness(tmp_path)
    _prepare_gateway(harness)
    activated = _run_gateway_manager(harness, "activate")
    assert activated.returncode == 0, activated.stderr
    trace_before = _gateway_trace(harness)

    active = _run_gateway_manager(harness, "status")

    assert active.returncode == 0, active.stderr
    assert active.stdout.splitlines() == [
        "prepared=yes",
        "active=yes",
        "gateway=running",
        "gateway_health=healthy",
        "legacy=stopped",
        "legacy_health=none",
    ]
    assert GATEWAY_TEST_SECRET not in active.stdout + active.stderr
    status_trace = _gateway_trace(harness)[len(trace_before) :]
    assert all(
        not {"start", "stop", "up", "down", "run", "create"}.intersection(
            command
        )
        for command in status_trace
    )

    state = _gateway_state(harness)
    state["containers"][LEGACY_CADDY_NAME]["running"] = True
    Path(harness["state_file"]).write_text(json.dumps(state))
    inconsistent = _run_gateway_manager(harness, "status")
    assert inconsistent.returncode != 0
    assert "prepared=yes" in inconsistent.stdout
