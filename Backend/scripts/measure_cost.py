"""What one import actually costs, measured rather than quoted.

Every paid call in the pipeline goes through an OpenAI-compatible endpoint
that will report its own cost when asked, so this runs the real stages over a
cached context and reads the price back instead of multiplying list rates by
guessed token counts.

    python scripts/measure_cost.py            # every cached source
    python scripts/measure_cost.py --only Cx8

Acquisition rungs that are free stay free and are reported as zero; the point
of the ladder is that most imports never reach the priced ones.
"""

import argparse
import base64
import json
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ladle.acquisition.audio import MediaAudioSource
from ladle.acquisition.free.ytdlp import YtDlpClient
from ladle.acquisition.models import AcquiredVideoContext
from ladle.config import Settings
from ladle.extraction.models import RecipeExtraction
from ladle.extraction.prompt import SYSTEM_PROMPT, build_user_prompt

CACHE = Path(__file__).resolve().parent.parent / ".eval-cache"


@dataclass
class Measured:
    name: str
    costs: dict[str, float] = field(default_factory=dict)
    detail: dict[str, str] = field(default_factory=dict)

    @property
    def total(self) -> float:
        return sum(self.costs.values())


def _api_key(settings: Settings) -> str:
    if settings.openrouter_api_key is None:
        raise RuntimeError("OPENROUTER_API_KEY is required to measure provider cost")
    return settings.openrouter_api_key.get_secret_value()


def _post(settings: Settings, payload: dict[str, Any]) -> dict[str, Any]:
    payload = {**payload, "usage": {"include": True}}
    response = httpx.post(
        f"{str(settings.openrouter_base_url).rstrip('/')}/chat/completions",
        headers={"Authorization": f"Bearer {_api_key(settings)}"},
        json=payload,
        timeout=180,
    )
    response.raise_for_status()
    return dict(response.json())


def extraction_cost(settings: Settings, context: AcquiredVideoContext) -> Measured:
    schema = RecipeExtraction.model_json_schema()
    body = _post(
        settings,
        {
            "model": settings.openrouter_model_id,
            "max_tokens": settings.openrouter_max_tokens,
            "temperature": 0,
            "provider": {"require_parameters": True},
            "messages": [
                {
                    "role": "system",
                    "content": (
                        f"{SYSTEM_PROMPT}\n\nRespond with a single JSON object "
                        "that validates against this JSON Schema. Emit no prose "
                        f"and no code fences.\n{json.dumps(schema)}"
                    ),
                },
                {"role": "user", "content": build_user_prompt(context)},
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "recipe_extraction",
                    "strict": True,
                    "schema": schema,
                },
            },
        },
    )
    usage = body.get("usage") or {}
    measured = Measured(name="extraction")
    measured.costs["extraction"] = float(usage.get("cost") or 0)
    measured.detail["extraction"] = (
        f"{usage.get('prompt_tokens')} in / {usage.get('completion_tokens')} out"
    )
    return measured


def media_costs(settings: Settings, context: AcquiredVideoContext) -> Measured:
    """Measure the text pipeline's audio-to-transcript rung."""

    measured = Measured(name="media")
    ytdlp = YtDlpClient(
        binary=settings.ytdlp_binary_path,
        cookies_file=settings.ytdlp_cookies_file,
    )
    media = ytdlp.metadata(context.source.canonical_url)
    source = MediaAudioSource(
        http=httpx.Client(timeout=180, trust_env=False),
    )
    with tempfile.TemporaryDirectory() as folder:
        work_dir = Path(folder)
        audio = source.audio(
            context.source,
            media_url=media.audio_url or media.media_url,
            work_dir=work_dir,
        )
        if audio is not None:
            response = httpx.post(
                f"{str(settings.openrouter_base_url).rstrip('/')}/audio/transcriptions",
                headers={"Authorization": f"Bearer {_api_key(settings)}"},
                json={
                    "model": settings.transcription_model_id,
                    "input_audio": {
                        "data": base64.b64encode(audio.read_bytes()).decode("ascii"),
                        "format": "mp3",
                    },
                    "response_format": "verbose_json",
                    "timestamp_granularities": ["word", "segment"],
                    "temperature": 0,
                },
                timeout=300,
            )
            if response.status_code < 400:
                usage = response.json().get("usage") or {}
                measured.costs["transcription"] = float(usage.get("cost") or 0)
                seconds = usage.get("seconds", 0)
                measured.detail["transcription"] = f"{seconds:.0f}s audio"

    return measured


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default=None)
    arguments = parser.parse_args()
    settings = Settings()

    rows: list[tuple[str, Measured, Measured]] = []
    for path in sorted(CACHE.glob("*.json")):
        if arguments.only and arguments.only not in path.stem:
            continue
        context = AcquiredVideoContext.model_validate_json(path.read_text())
        print(f"measuring {path.stem} ...", flush=True)
        rows.append(
            (
                path.stem,
                extraction_cost(settings, context),
                media_costs(settings, context),
            )
        )

    print(f"\n{'source':<24} {'extract':>10} {'transcribe':>11} {'total':>10}")
    print("-" * 70)
    totals: dict[str, float] = {}
    for name, extraction, media in rows:
        line = {**extraction.costs, **media.costs}
        for key, value in line.items():
            totals[key] = totals.get(key, 0) + value
        print(
            f"{name:<24} ${line.get('extraction', 0):>9.5f} "
            f"${line.get('transcription', 0):>10.5f} "
            f"${sum(line.values()):>9.5f}"
        )
    if rows:
        count = len(rows)
        print("-" * 70)
        print(
            f"{'MEAN PER IMPORT':<24} ${totals.get('extraction', 0) / count:>9.5f} "
            f"${totals.get('transcription', 0) / count:>10.5f} "
            f"${totals.get('frameAnalysis', 0) / count:>9.5f} "
            f"${sum(totals.values()) / count:>9.5f}"
        )
        print(
            "\nEvery import pays extraction. Transcription and frames are only "
            "reached\nwhen the free rungs come up short, so a real mix costs "
            "less than the mean\nof a corpus deliberately full of hard cases."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
