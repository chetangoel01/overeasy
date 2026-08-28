"""Reprocess preserved live recipes through Gemini normalization and USDA only."""

from __future__ import annotations

import argparse
import getpass
import json
import re
import time
import uuid
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx

from ladle.acquisition.models import (
    AcquiredVideoContext,
    LinkedDocument,
    SourceVideoDescriptor,
    TextEvidence,
    VisualEvidence,
)
from ladle.config import Settings
from ladle.contracts.recipes import RecipeReviewStatus
from ladle.imports.source_identity import SourceIdentityParser
from ladle.nutrition.calculator import (
    NutritionCalculationUnavailable,
    NutritionCalculator,
)
from ladle.nutrition.normalization import (
    NutritionNormalization,
    NutritionNormalizationClient,
    NutritionNormalizationResponse,
    OpenRouterNutritionNormalizationClient,
    RecipeNutritionNormalizer,
)
from ladle.nutrition.service import RecipeNutritionService
from ladle.nutrition.usda import USDAClient
from ladle.recipes.template_clone import RecipeTemplate

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".eval-cache/live-imports/2026-08-24-gemini-3.7-corrected-results.json"
OUTPUT = ROOT / ".eval-cache/live-imports/2026-08-24-nutrition-first-results.json"
RESULTS_HTML = ROOT / "tools/pipeline-results.html"


class CapturingClient:
    def __init__(self, client: NutritionNormalizationClient) -> None:
        self._client = client
        self.response: NutritionNormalizationResponse | None = None

    def normalize(self, **kwargs: Any) -> NutritionNormalizationResponse:
        self.response = self._client.normalize(**kwargs)
        return self.response


class SavedClient:
    def __init__(self, response: NutritionNormalizationResponse) -> None:
        self._response = response

    def normalize(self, **_kwargs: Any) -> NutritionNormalizationResponse:
        return self._response


def _secret(environment: str, prompt: str) -> str:
    import os

    value = os.getenv(environment, "") or getpass.getpass(prompt).strip()
    if not value:
        raise SystemExit(f"{environment} is required")
    return value


def _source(url: str) -> SourceVideoDescriptor:
    identity = SourceIdentityParser().parse(url)
    return SourceVideoDescriptor(
        source_video_id=uuid.uuid5(uuid.NAMESPACE_URL, identity.canonical_url),
        platform=identity.platform.value,
        platform_video_id=identity.platform_video_id,
        canonical_url=identity.canonical_url,
        source_revision="preserved-nutrition-v1",
    )


def _context(row: dict[str, Any]) -> AcquiredVideoContext:
    evidence = row["evidence"]
    return AcquiredVideoContext(
        source=_source(row["sourceURL"]),
        is_public=True,
        title=evidence["title"],
        description=evidence["description"],
        creator_name=evidence["creatorName"],
        transcript=[
            TextEvidence.model_validate(value) for value in evidence["transcript"]
        ],
        linked_documents=[
            LinkedDocument.model_validate(value)
            for value in evidence["linkedDocuments"]
        ],
        visual_observations=[
            VisualEvidence.model_validate(value)
            for value in evidence["visualObservations"]
        ],
        diagnostics=row["acquisitionDiagnostics"],
    )


def _write(results: list[dict[str, Any]]) -> None:
    OUTPUT.write_text(json.dumps(results, indent=2) + "\n")


def _update_html() -> None:
    nutrition_rows: list[dict[str, Any]] = json.loads(OUTPUT.read_text())
    extraction_rows: list[dict[str, Any]] = json.loads(SOURCE.read_text())
    extraction_by_url = {value["sourceURL"]: value for value in extraction_rows}
    records = []
    for value in sorted(nutrition_rows, key=lambda row: row["position"]):
        extraction = extraction_by_url[value["sourceURL"]]
        known_cost = Decimal(extraction["usage"]["reportedTotalCostUSD"]) + Decimal(
            value["usage"]["normalizationCostUSD"]
        )
        records.append(
            {
                "sourceURL": value["sourceURL"],
                "modelID": value["modelID"],
                "processSeconds": extraction["processingSeconds"],
                "knownCostUSD": str(known_cost),
                "recipe": value["recipe"],
            }
        )
    html = RESULTS_HTML.read_text()
    payload = json.dumps(records, separators=(",", ":"))

    def replace_data(match: re.Match[str]) -> str:
        return match.group(1) + payload + match.group(2)

    html, replacements = re.subn(
        r'(<script id="pipeline-results-data" type="application/json">).*?(</script>)',
        replace_data,
        html,
        count=1,
        flags=re.DOTALL,
    )
    if replacements != 1:
        raise RuntimeError("results HTML data marker is missing or duplicated")
    RESULTS_HTML.write_text(html)


def _audit_evidence(fdc_evidence: str, result: dict[str, Any]) -> str:
    confidence_value = (Decimal(result["servingsConfidence"]) * 100).normalize()
    values = [
        fdc_evidence,
        f"Serving estimate confidence: {confidence_value:f}%",
    ]
    if result["servingsRationale"]:
        values.append(f"Yield rationale: {result['servingsRationale']}")
    if result["assumptions"]:
        assumptions = "; ".join(value.rstrip(". ") for value in result["assumptions"])
        values.append("Assumptions: " + assumptions)
    return ". ".join(value.rstrip(". ") for value in values) + "."


def _refresh_evidence() -> None:
    results: list[dict[str, Any]] = json.loads(OUTPUT.read_text())
    for result in results:
        nutrition = result["recipe"].get("nutrition")
        if nutrition is None:
            continue
        fdc_evidence = nutrition["evidence"].split(
            ". Serving estimate confidence:",
            1,
        )[0]
        nutrition["evidence"] = _audit_evidence(fdc_evidence, result)
    _write(results)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--retry-normalization-blockers", action="store_true")
    parser.add_argument("--recover-saved-normalizations", action="store_true")
    parser.add_argument("--recalculate-usda", action="store_true")
    parser.add_argument("--update-html", action="store_true")
    parser.add_argument("--refresh-evidence", action="store_true")
    args = parser.parse_args()
    if args.refresh_evidence:
        _refresh_evidence()
        return 0
    if args.update_html:
        _update_html()
        return 0
    settings = Settings(
        openrouter_api_key=(
            None
            if args.recover_saved_normalizations or args.recalculate_usda
            else _secret("LADLE_OPENROUTER_API_KEY", "OpenRouter key: ")
        ),
        usda_api_key=_secret("LADLE_USDA_API_KEY", "USDA key: "),
        _env_file=None,
    )
    assert settings.usda_api_key is not None
    rows: list[dict[str, Any]] = json.loads(SOURCE.read_text())
    results: list[dict[str, Any]] = (
        json.loads(OUTPUT.read_text()) if OUTPUT.exists() else []
    )
    saved = {
        value["sourceURL"]: value
        for value in results
        if value.get("rawNormalization") is not None
    }
    if args.retry_normalization_blockers:
        results = [
            value
            for value in results
            if "normalizationUnavailable" not in (value.get("blocker") or "")
        ]
        _write(results)
    if args.recover_saved_normalizations:
        results = [value for value in results if value["sourceURL"] not in saved]
        _write(results)
    completed = {value["sourceURL"] for value in results}
    http = httpx.Client(
        timeout=settings.openrouter_timeout_seconds,
        trust_env=False,
    )
    calculator = NutritionCalculator(
        USDAClient(
            http=httpx.Client(timeout=settings.usda_timeout_seconds, trust_env=False),
            api_key=settings.usda_api_key.get_secret_value(),
            base_url=str(settings.usda_base_url),
            maximum_candidates=settings.usda_maximum_candidates,
        )
    )

    if args.recalculate_usda:
        for position, result in enumerate(results, start=1):
            template = RecipeTemplate.model_validate(result["recipe"])
            try:
                nutrition = calculator.calculate_required(template)
            except NutritionCalculationUnavailable as error:
                blocker = error.code
                if error.ingredient_index is not None:
                    blocker += f" at ingredient {error.ingredient_index}"
                if error.ingredient_name is not None:
                    blocker += f" ({error.ingredient_name})"
                result["blocker"] = blocker
            else:
                nutrition = nutrition.model_copy(
                    update={
                        "evidence": _audit_evidence(
                            nutrition.evidence or "USDA FoodData Central",
                            result,
                        )
                    }
                )
                uncertainties = [
                    value
                    for value in template.uncertainties
                    if value.field != "nutrition"
                ]
                template = template.model_copy(
                    update={
                        "nutrition": nutrition,
                        "uncertainties": uncertainties,
                        "review_status": (
                            RecipeReviewStatus.READY
                            if not uncertainties
                            else template.review_status
                        ),
                    }
                )
                result["recipe"] = template.model_dump(mode="json")
                result["blocker"] = None
            status = (
                "nutrition ready" if result["blocker"] is None else result["blocker"]
            )
            print(
                f"[{position}/{len(results)}] {result['title']}: {status}",
                flush=True,
            )
            _write(results)
        return 0

    for position, row in enumerate(rows, start=1):
        if row["sourceURL"] in completed:
            print(f"[{position}/5] preserved {row['recipe']['title']}", flush=True)
            continue
        context = _context(row)
        saved_row = saved.get(row["sourceURL"])
        if args.recover_saved_normalizations and saved_row is not None:
            saved_usage = saved_row["usage"]
            client: NutritionNormalizationClient = SavedClient(
                NutritionNormalizationResponse(
                    parsed_output=NutritionNormalization.model_validate(
                        saved_row["rawNormalization"]
                    ),
                    input_tokens=saved_usage["normalizationInputTokens"],
                    output_tokens=saved_usage["normalizationOutputTokens"],
                    cost_usd=Decimal(saved_usage["normalizationCostUSD"]),
                )
            )
        else:
            assert settings.openrouter_api_key is not None
            client = OpenRouterNutritionNormalizationClient(
                http=http,
                api_key=settings.openrouter_api_key.get_secret_value(),
                base_url=str(settings.openrouter_base_url),
            )
        capture = CapturingClient(client)
        service = RecipeNutritionService(
            normalizer=RecipeNutritionNormalizer(
                client=capture,
                model_id=settings.nutrition_normalization_model_id,
                max_tokens=settings.nutrition_normalization_max_tokens,
            ),
            calculator=calculator,
        )
        template = RecipeTemplate.model_validate(row["recipe"])
        started = time.perf_counter()
        enriched = service.enrich(
            template,
            context=context,
            job_id=uuid.uuid5(uuid.NAMESPACE_URL, f"nutrition:{row['sourceURL']}"),
        )
        normalization = capture.response.parsed_output if capture.response else None
        nutrition_blocker = next(
            (
                value.reason
                for value in enriched.uncertainties
                if value.field == "nutrition"
            ),
            None,
        )
        result = {
            "position": position,
            "sourceURL": row["sourceURL"],
            "modelID": settings.nutrition_normalization_model_id,
            "title": enriched.title,
            "originalServings": str(template.servings),
            "originalServingsBasis": template.servings_basis,
            "normalizedServings": str(enriched.servings),
            "normalizedServingsBasis": enriched.servings_basis,
            "servingsConfidence": (
                str(normalization.servings_confidence) if normalization else None
            ),
            "servingsRationale": (
                normalization.servings_rationale if normalization else None
            ),
            "assumptions": normalization.assumptions if normalization else [],
            "rawNormalization": (
                normalization.model_dump(mode="json") if normalization else None
            ),
            "blocker": nutrition_blocker,
            "recipe": enriched.model_dump(mode="json"),
            "processingSeconds": round(time.perf_counter() - started, 3),
            "usage": {
                "normalizationInputTokens": (
                    capture.response.input_tokens if capture.response else 0
                ),
                "normalizationOutputTokens": (
                    capture.response.output_tokens if capture.response else 0
                ),
                "normalizationCostUSD": (
                    str(capture.response.cost_usd)
                    if capture.response and capture.response.cost_usd is not None
                    else None
                ),
            },
        }
        results.append(result)
        _write(results)
        status = "nutrition ready" if enriched.nutrition else nutrition_blocker
        print(f"[{position}/5] {enriched.title}: {status}", flush=True)

    cost = sum(
        (
            Decimal(value["usage"]["normalizationCostUSD"])
            for value in results
            if value["usage"]["normalizationCostUSD"] is not None
        ),
        Decimal(0),
    )
    print(f"normalization cost=${cost}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
