"""Find creator-authored written recipes without trusting search snippets."""

import json
import logging
import re
from typing import Protocol
from urllib.parse import unquote, urlsplit
from uuid import UUID

import httpx
from pydantic import Field, ValidationError

from ladle.acquisition.coverage import has_instructions, has_quantities
from ladle.acquisition.errors import (
    MalformedProviderResponse,
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
)
from ladle.acquisition.free.links import (
    LinkFetcher,
    UnsafeURL,
    belongs_to_creator,
    dish_terms,
)
from ladle.acquisition.models import AcquiredVideoContext, LinkedDocument
from ladle.contracts.common import WireModel

LOGGER = logging.getLogger(__name__)

_MINIMUM_DOCUMENT_CHARACTERS = 200
_DISH_STOP_WORDS = {
    "best",
    "easy",
    "food",
    "full",
    "make",
    "recipe",
    "this",
    "with",
}


class SearchCandidate(WireModel):
    url: str = Field(pattern=r"^https?://", max_length=2_048)
    title: str = Field(max_length=1_000)
    snippet: str = Field(max_length=8_000)


class RecipeSearchClient(Protocol):
    def search(
        self,
        queries: list[str],
        *,
        job_id: UUID,
    ) -> list[SearchCandidate]: ...


class OpenRouterRecipeSearchClient:
    """Bounded OpenRouter web-search client that returns citation metadata."""

    def __init__(
        self,
        *,
        http: httpx.Client,
        api_key: str,
        base_url: str,
        model_id: str,
        maximum_queries: int = 3,
        maximum_results: int = 6,
    ) -> None:
        if maximum_queries < 1 or maximum_results < 1:
            raise ValueError("search bounds must be positive")
        self._http = http
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._model_id = model_id
        self._maximum_queries = maximum_queries
        self._maximum_results = maximum_results

    def search(
        self,
        queries: list[str],
        *,
        job_id: UUID,
    ) -> list[SearchCandidate]:
        del job_id
        results: list[SearchCandidate] = []
        seen: set[str] = set()
        for query in queries[: self._maximum_queries]:
            for candidate in self._search_once(query):
                key = candidate.url.casefold()
                if key in seen:
                    continue
                seen.add(key)
                results.append(candidate)
                if len(results) >= self._maximum_results:
                    return results
        return results

    def _search_once(self, query: str) -> list[SearchCandidate]:
        payload = {
            "model": self._model_id,
            "temperature": 0,
            "tool_choice": "required",
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "Search public written pages for the exact query and "
                        "return grounded cited sources."
                    ),
                },
                {"role": "user", "content": query},
            ],
            "tools": [
                {
                    "type": "openrouter:web_search",
                    "parameters": {
                        "engine": "exa",
                        "max_results": self._maximum_results,
                        "max_total_results": self._maximum_results,
                        "max_characters": 2_000,
                    },
                }
            ],
        }
        try:
            response = self._http.post(
                f"{self._base_url}/chat/completions",
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "X-Title": "Overeasy",
                },
                json=payload,
            )
        except httpx.HTTPError as error:
            raise ProviderTransientError("creator search unavailable") from error
        if response.status_code in (401, 403):
            raise ProviderAuthenticationError("creator search authentication failed")
        if response.status_code in (402, 429):
            raise ProviderQuotaError("creator search quota unavailable")
        if response.status_code >= 400:
            raise ProviderTransientError(
                f"creator search failed with HTTP {response.status_code}"
            )

        try:
            data = response.json()
            message = data["choices"][0]["message"]
            annotations = message.get("annotations") or []
        except (json.JSONDecodeError, LookupError, TypeError) as error:
            raise MalformedProviderResponse(
                "creator search returned an unreadable response"
            ) from error
        if not isinstance(annotations, list):
            raise MalformedProviderResponse(
                "creator search returned invalid citation annotations"
            )
        return self._candidates(annotations)

    @staticmethod
    def _candidates(annotations: list[object]) -> list[SearchCandidate]:
        candidates: list[SearchCandidate] = []
        for annotation in annotations:
            if (
                not isinstance(annotation, dict)
                or annotation.get("type") != "url_citation"
            ):
                continue
            citation = annotation.get("url_citation")
            if not isinstance(citation, dict):
                continue
            try:
                candidates.append(
                    SearchCandidate(
                        url=citation.get("url", ""),
                        title=citation.get("title", ""),
                        snippet=citation.get("content", ""),
                    )
                )
            except ValidationError:
                continue
        return candidates


class SparseTextEnricher:
    """Turn search citations into one independently verified creator page."""

    def __init__(
        self,
        *,
        search: RecipeSearchClient,
        fetcher: LinkFetcher,
        maximum_queries: int = 3,
        maximum_candidates: int = 6,
        minimum_document_characters: int = _MINIMUM_DOCUMENT_CHARACTERS,
    ) -> None:
        if minimum_document_characters < 1:
            raise ValueError("minimum document length must be positive")
        if maximum_queries < 1 or maximum_candidates < 1:
            raise ValueError("search bounds must be positive")
        self._search = search
        self._fetcher = fetcher
        self._maximum_queries = maximum_queries
        self._maximum_candidates = maximum_candidates
        self._minimum_document_characters = minimum_document_characters

    def enrich(
        self,
        context: AcquiredVideoContext,
        *,
        job_id: UUID,
    ) -> list[LinkedDocument]:
        source_terms = _identity_terms(context.title or "")
        candidates = self._search.search(
            _queries(context, limit=self._maximum_queries),
            job_id=job_id,
        )
        for candidate in candidates[: self._maximum_candidates]:
            if not _owned_candidate(candidate.url, context):
                continue
            if not _matches_dish(
                f"{candidate.title} {unquote(urlsplit(candidate.url).path)}",
                source_terms,
            ):
                continue
            try:
                text = self._fetcher.fetch_text(candidate.url)
            except (UnsafeURL, OSError, httpx.HTTPError) as error:
                LOGGER.info(
                    "Creator search page fetch refused for %s: %s",
                    candidate.url,
                    error,
                )
                continue
            if not self._valid_page(text, source_terms):
                continue
            return [
                LinkedDocument(
                    url=candidate.url,
                    text=text,
                    provenance="creatorSearch",
                )
            ]
        return []

    def _valid_page(self, text: str, source_terms: set[str]) -> bool:
        return (
            len(text) >= self._minimum_document_characters
            and has_quantities(text)
            and has_instructions(text)
            and _matches_dish(text, source_terms)
        )


def _queries(context: AcquiredVideoContext, *, limit: int) -> list[str]:
    creator = (context.creator_name or "").strip()
    title = (context.title or "").strip()
    identity = context.source.platform_video_id
    values = [
        f'"{creator}" "{title}" written recipe ingredients method',
        f'"{creator}" "{identity}" recipe',
        f'"{context.source.canonical_url}" recipe',
    ]
    unique: list[str] = []
    for value in values:
        normalized = re.sub(r'""\s*', "", value).strip()
        if normalized and normalized not in unique:
            unique.append(normalized)
    return unique[:limit]


def _identity_terms(value: str) -> set[str]:
    return {
        term
        for term in dish_terms(value)
        if term not in _DISH_STOP_WORDS and len(term) > 2
    }


def _matches_dish(value: str, source_terms: set[str]) -> bool:
    if not source_terms:
        return True
    overlap = source_terms & _identity_terms(value)
    required = 1 if len(source_terms) == 1 else 2
    return len(overlap) >= required


def _owned_candidate(url: str, context: AcquiredVideoContext) -> bool:
    return belongs_to_creator(url, context.creator_name) or _same_canonical_post(
        url,
        context,
    )


def _same_canonical_post(url: str, context: AcquiredVideoContext) -> bool:
    try:
        candidate = urlsplit(url)
        canonical = urlsplit(context.source.canonical_url)
    except ValueError:
        return False
    candidate_host = (candidate.hostname or "").casefold().removeprefix("www.")
    canonical_host = (canonical.hostname or "").casefold().removeprefix("www.")
    if candidate_host != canonical_host:
        return False
    identity = context.source.platform_video_id.casefold()
    return len(identity) >= 5 and identity in unquote(url).casefold()
