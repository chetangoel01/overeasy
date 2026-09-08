"""Read TestFlight tester feedback from App Store Connect.

The same feedback is in Xcode's Organizer, but reaching it there means driving
the Organizer's window with accessibility scripting, which needs a trusted
terminal and a screen to look at. This asks App Store Connect directly, so the
check runs anywhere — over ssh, from a cron job, from an agent session with no
UI permissions at all.

    python3 Tools/release/feedback.py [--since 2026-09-04] [--json]

Credentials come from `.private/asc.env` or from the environment, which wins
when both have a value. They are the same three the upload script uses:

    LADLE_ASC_KEY_ID      the key's ten-character identifier
    LADLE_ASC_ISSUER_ID   the issuer UUID shown above the key list. Leave it
                          unset for an individual key, which has no issuer.
    LADLE_ASC_KEY_PATH    path to AuthKey_<KEY_ID>.p8
                          (default: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8)

Nothing is imported that is not in the standard library: the ES256 signature
App Store Connect wants is made by shelling out to openssl and converting its
DER output to the raw pair the JWT spec asks for. A release machine has openssl
and may not have PyJWT.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# Overeasy's Apple ID, as App Store Connect calls the app.
APP_ID = "6804500781"
API = "https://api.appstoreconnect.apple.com/v1"

ROOT = Path(__file__).resolve().parents[2]
# Credentials may sit in the environment, as the upload script wants them, or
# in this file, which `.gitignore` already keeps out of the repository. The
# environment wins, so a one-off run can override what is on disk.
ENV_FILE = ROOT / ".private" / "asc.env"

# The two things a tester can send. Apple keeps them in separate collections
# because a crash carries a log and a screenshot carries an image, but for
# triage they are one list of "someone told us something".
KINDS = ("betaFeedbackScreenshotSubmissions", "betaFeedbackCrashSubmissions")


def stored_credentials() -> dict[str, str]:
    """Read `.private/asc.env`, if it is there. KEY=VALUE lines, # for a comment."""
    if not ENV_FILE.is_file():
        return {}
    values = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        values[name.strip()] = value.strip().strip("'\"")
    return values


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """Turn openssl's DER ECDSA signature into the 64-byte R||S a JWT carries."""
    if der[0] != 0x30:
        raise SystemExit("openssl did not return a DER sequence")
    # Skip the sequence header, then read two INTEGERs.
    index = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7F) - 1
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise SystemExit("malformed signature from openssl")
        length = der[index + 1]
        value = der[index + 2 : index + 2 + length]
        # DER pads a leading 0x00 onto integers whose top bit is set; the JWT
        # form is a fixed 32 bytes, so strip that and left-pad instead.
        parts.append(value.lstrip(b"\x00").rjust(32, b"\x00"))
        index += 2 + length
    return b"".join(parts)


def token(key_id: str, issuer_id: str, key_path: Path) -> str:
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {
        "iat": now,
        # Apple rejects anything longer than twenty minutes.
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    # Two kinds of key, two different tokens. A team key is issued by an
    # organisation and names it in `iss`; an individual key belongs to one
    # person, has no issuer at all, and says so with `sub`. Sending the wrong
    # shape gets the same unhelpful 401 as a bad signature.
    payload.update({"iss": issuer_id} if issuer_id else {"sub": "user"})
    signing_input = ".".join(
        b64(json.dumps(part, separators=(",", ":")).encode())
        for part in (header, payload)
    )
    signed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=signing_input.encode(),
        capture_output=True,
    )
    if signed.returncode != 0:
        raise SystemExit(f"openssl could not sign with {key_path}: {signed.stderr.decode().strip()}")
    return f"{signing_input}.{b64(der_to_raw(signed.stdout))}"


def get(path: str, bearer: str, **params: str) -> dict:
    url = f"{API}/{path}"
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        try:
            detail = "; ".join(
                e.get("detail", e.get("title", "")) for e in json.loads(body).get("errors", [])
            )
        except json.JSONDecodeError:
            detail = body[:400]
        raise SystemExit(f"App Store Connect said {error.code} for {path}: {detail}")


def collect(kind: str, bearer: str, limit: int) -> list[dict]:
    """One collection, newest first.

    `sort` and `include` are asked for optimistically. Apple adds and removes
    what a collection will sort and include, and a rejected parameter should
    cost the caller a plainer answer rather than no answer at all.
    """
    attempts = (
        {"limit": str(limit), "sort": "-createdDate", "include": "tester,build"},
        {"limit": str(limit), "sort": "-createdDate"},
        {"limit": str(limit)},
    )
    for params in attempts:
        try:
            payload = get(f"apps/{APP_ID}/{kind}", bearer, **params)
        except SystemExit as failure:
            if "400" not in str(failure):
                raise
            continue
        included = {(i["type"], i["id"]): i for i in payload.get("included", [])}
        items = []
        for item in payload.get("data", []):
            record = dict(item.get("attributes", {}))
            record["_kind"] = kind
            record["_id"] = item.get("id")
            for name, relationship in (item.get("relationships") or {}).items():
                data = (relationship or {}).get("data")
                if not data:
                    continue
                linked = included.get((data["type"], data["id"]))
                if linked:
                    record[f"_{name}"] = linked.get("attributes", {})
            items.append(record)
        return items
    raise SystemExit(f"App Store Connect rejected every form of the {kind} request")


def when(item: dict) -> str:
    for key in ("createdDate", "timestamp", "submittedDate"):
        if item.get(key):
            return str(item[key])
    return ""


def instant(item: dict) -> datetime | None:
    """The submission time as a moment, not a string.

    Apple timestamps in UTC and a cook lives somewhere. Comparing the date
    halves of the two strings drops an evening's feedback whenever the local
    day and the UTC day disagree, which for New York is every evening.
    """
    text = when(item)
    if not text:
        return None
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def show(item: dict) -> None:
    tester = item.get("_tester") or {}
    who = item.get("email") or tester.get("email") or "anonymous"
    name = " ".join(filter(None, (tester.get("firstName"), tester.get("lastName"))))
    build = (item.get("_build") or {}).get("version") or item.get("buildNumber") or "?"
    device = item.get("deviceModel") or item.get("devicePlatform") or "?"
    os_version = item.get("osVersion") or "?"
    heading = f"{when(item)}  {name or who}  {device}  iOS {os_version}  build {build}"
    print(heading)
    print("-" * len(heading))
    comment = (item.get("comment") or item.get("feedbackText") or "").strip()
    print(comment if comment else "(no comment — see the crash log)")
    extras = [
        f"kind: {item['_kind'].replace('betaFeedback', '').replace('Submissions', '').lower()}",
        f"id: {item.get('_id')}",
    ]
    if item.get("screenshots") or item.get("imageCount"):
        extras.append("has a screenshot")
    if item.get("crashLog") or item.get("_kind").endswith("CrashSubmissions"):
        extras.append("has a crash log")
    print(f"[{', '.join(extras)}]")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--since",
        help="only feedback submitted on or after this local date, e.g. 2026-09-04",
    )
    parser.add_argument("--limit", type=int, default=50, help="how many per collection")
    parser.add_argument("--json", action="store_true", help="print the raw records instead")
    arguments = parser.parse_args()

    credentials = {**stored_credentials(), **os.environ}
    key_id = credentials.get("LADLE_ASC_KEY_ID")
    issuer_id = credentials.get("LADLE_ASC_ISSUER_ID")
    if not key_id:
        raise SystemExit("set LADLE_ASC_KEY_ID (see the module docstring)")
    key_path = Path(
        credentials.get("LADLE_ASC_KEY_PATH")
        or Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    )
    if not key_path.is_file():
        raise SystemExit(f"no API key at {key_path}")

    bearer = token(key_id, issuer_id, key_path)
    items: list[dict] = []
    answered = 0
    for kind in KINDS:
        # One collection failing must not throw away the other. Crashes and
        # screenshots are separate endpoints with separate permissions, and a
        # tester's written note is worth reading even when the crash list is
        # unreadable.
        try:
            items.extend(collect(kind, bearer, arguments.limit))
            answered += 1
        except SystemExit as failure:
            print(f"warning: {failure}", file=sys.stderr)
    # "No feedback" is a claim about the app. If nothing answered, the only
    # honest thing to report is that we never found out.
    if not answered:
        raise SystemExit("no collection could be read; nothing can be said about feedback")
    if arguments.since:
        # A date on the command line means a local date, starting at local
        # midnight. Anything without a timestamp is kept rather than guessed at.
        start = datetime.fromisoformat(arguments.since).astimezone()
        items = [i for i in items if (instant(i) or start) >= start]
    items.sort(key=when, reverse=True)

    if arguments.json:
        json.dump(items, sys.stdout, indent=2)
        print()
        return

    if not items:
        print("No feedback" + (f" since {arguments.since}" if arguments.since else "") + ".")
        return
    print(f"{len(items)} submission(s), newest first\n")
    for item in items:
        show(item)


if __name__ == "__main__":
    main()
