import os
import subprocess
import time
from collections.abc import Iterator
from contextlib import contextmanager
from uuid import uuid4

import httpx
import pytest

pytestmark = [
    pytest.mark.chaos,
    pytest.mark.skipif(
        os.getenv("LADLE_RUN_CHAOS") != "1",
        reason="set LADLE_RUN_CHAOS=1 in an isolated Docker environment",
    ),
]

PROJECT = "ladle-chaos-recovery"
BASE_URL = "http://127.0.0.1:42112"
COMPOSE_FILES = (
    "docker-compose.yml",
    "deploy/chaos/docker-compose.chaos.yml",
)
CHAOS_ENVIRONMENT = {
    **os.environ,
    "LADLE_WORKER_PROVIDER_MODE": "fake",
    "LADLE_FAKE_PROVIDER_DELAY_SECONDS": "8",
}


@contextmanager
def stack() -> Iterator[None]:
    _compose("up", "-d", "--build")
    try:
        _wait_ready()
        yield
    finally:
        _compose("down", "--volumes", "--remove-orphans")


def test_sigkill_worker_redelivers_import_to_a_replacement() -> None:
    with stack(), httpx.Client(timeout=10) as client:
        token, job_id = _submit(client, "SIGKILL")
        _wait_stage(job_id, "extracting")

        _compose("kill", "-s", "SIGKILL", "worker")
        _compose("up", "-d", "worker")

        _wait_terminal(client, token, job_id)


def test_broker_outage_during_work_terminates_deterministically() -> None:
    with stack(), httpx.Client(timeout=10) as client:
        token, job_id = _submit(client, "broker_outage")
        _wait_stage(job_id, "extracting")

        _compose("stop", "redis")
        time.sleep(10)
        _compose("start", "redis")
        _compose("restart", "worker", "beat")

        _wait_terminal(client, token, job_id)


def _submit(client: httpx.Client, suffix: str) -> tuple[str, str]:
    guest = client.post(
        f"{BASE_URL}/v1/auth/guest",
        json={"installationID": f"chaos-{suffix}-{uuid4()}", "attestation": None},
    )
    assert guest.status_code == 201
    token = str(guest.json()["accessToken"])
    job_id = str(uuid4())
    accepted = client.post(
        f"{BASE_URL}/v1/imports",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "jobID": job_id,
            "sourceURL": f"https://youtu.be/{job_id[:11]}",
        },
    )
    assert accepted.status_code == 202
    return token, job_id


def _wait_ready() -> None:
    with httpx.Client(timeout=3) as client:
        for _ in range(120):
            try:
                if client.get(f"{BASE_URL}/health/ready").status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            time.sleep(1)
    raise AssertionError("Compose stack did not become ready")


def _wait_stage(job_id: str, stage: str) -> None:
    for _ in range(60):
        result = subprocess.run(
            [
                "docker",
                "compose",
                *[item for path in COMPOSE_FILES for item in ("-f", path)],
                "-p",
                PROJECT,
                "exec",
                "-T",
                "postgres",
                "psql",
                "-U",
                "ladle",
                "-d",
                "ladle",
                "-Atc",
                f"SELECT stage FROM import_jobs WHERE id = '{job_id}'",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        if result.stdout.strip() == stage:
            return
        time.sleep(0.25)
    raise AssertionError(f"job never reached {stage}")


def _wait_terminal(client: httpx.Client, token: str, job_id: str) -> None:
    for _ in range(180):
        response = client.get(
            f"{BASE_URL}/v1/imports/{job_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
        if response.status_code == 200:
            status = response.json()["status"]
            if status in {"ready", "needsReview"}:
                return
            if status == "failed":
                raise AssertionError(f"job failed: {response.json()}")
        time.sleep(1)
    raise AssertionError("job did not terminate after infrastructure recovery")


def _compose(*arguments: str) -> None:
    files = [item for path in COMPOSE_FILES for item in ("-f", path)]
    subprocess.run(
        ["docker", "compose", *files, "-p", PROJECT, *arguments],
        check=True,
        env=CHAOS_ENVIRONMENT,
    )
