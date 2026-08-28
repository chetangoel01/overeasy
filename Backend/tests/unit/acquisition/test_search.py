import json
from dataclasses import dataclass, field
from uuid import UUID, uuid4

import httpx
import pytest

from ladle.acquisition.errors import ProviderTransientError
from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor
from ladle.acquisition.search import (
    OpenRouterRecipeSearchClient,
    SearchCandidate,
    SparseTextEnricher,
)


def context(
    *,
    creator_name: str = "justine_snacks",
    title: str = "Creamy Lemon Chickpeas",
) -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="instagram",
            platform_video_id="recipe-reel",
            canonical_url="https://www.instagram.com/reel/recipe-reel",
            source_revision="1",
        ),
        is_public=True,
        title=title,
        description="Full written recipe in my bio.",
        creator_name=creator_name,
    )


def recipe_page(*, ingredient: str = "2 cans chickpeas") -> str:
    return (
        "Creamy Lemon Chickpeas by justine_snacks. "
        f"Ingredients: {ingredient}, 1 tablespoon olive oil, and 1 lemon. "
        "Method: drain the chickpeas, add the oil, simmer for ten minutes, "
        "then stir in the lemon and serve. "
        "These written preparation notes belong to the complete creator recipe. "
        "Store leftovers chilled and reheat gently."
    )


@dataclass
class Search:
    candidates: list[SearchCandidate]
    queries: list[str] = field(default_factory=list)
    job_ids: list[UUID] = field(default_factory=list)

    def search(
        self,
        queries: list[str],
        *,
        job_id: UUID,
    ) -> list[SearchCandidate]:
        self.queries = queries
        self.job_ids.append(job_id)
        return self.candidates


@dataclass
class Fetcher:
    pages: dict[str, str]
    calls: list[str] = field(default_factory=list)

    def fetch_text(self, url: str) -> str:
        self.calls.append(url)
        return self.pages.get(url, "")

    def fetch_raw(self, url: str) -> str:
        raise AssertionError(f"raw fetch is not allowed for search candidates: {url}")


def candidate(url: str, title: str, snippet: str = "") -> SearchCandidate:
    return SearchCandidate(url=url, title=title, snippet=snippet)


def test_enricher_queries_identity_and_accepts_only_matching_creator_recipe() -> None:
    generic = "https://other-food-blog.example/creamy-lemon-chickpeas"
    wrong_dish = "https://justinesnacks.com/crispy-potato-salad"
    thin = "https://justinesnacks.com/creamy-lemon-chickpeas-preview"
    creator_recipe = "https://justinesnacks.com/creamy-lemon-chickpeas"
    search = Search(
        [
            candidate(generic, "Creamy Lemon Chickpeas Recipe"),
            candidate(wrong_dish, "Crispy Potato Salad"),
            candidate(thin, "Creamy Lemon Chickpeas Preview"),
            candidate(creator_recipe, "Creamy Lemon Chickpeas"),
        ]
    )
    fetcher = Fetcher(
        {
            generic: recipe_page(),
            wrong_dish: recipe_page(ingredient="2 pounds potatoes"),
            thin: "2 cans chickpeas. Simmer.",
            creator_recipe: recipe_page(),
        }
    )
    enricher = SparseTextEnricher(
        search=search,
        fetcher=fetcher,
        maximum_queries=3,
        maximum_candidates=6,
    )
    job_id = uuid4()

    documents = enricher.enrich(context(), job_id=job_id)

    assert search.job_ids == [job_id]
    assert 1 < len(search.queries) <= 3
    assert any("justine_snacks" in query for query in search.queries)
    assert any("Creamy Lemon Chickpeas" in query for query in search.queries)
    assert any("recipe-reel" in query for query in search.queries)
    assert fetcher.calls == [thin, creator_recipe]
    assert [document.url for document in documents] == [creator_recipe]
    assert documents[0].provenance == "creatorSearch"


def test_search_snippet_is_never_used_without_independent_page_fetch() -> None:
    url = "https://justinesnacks.com/creamy-lemon-chickpeas"
    search = Search([candidate(url, "Creamy Lemon Chickpeas", snippet=recipe_page())])
    fetcher = Fetcher({url: ""})

    documents = SparseTextEnricher(search=search, fetcher=fetcher).enrich(
        context(),
        job_id=uuid4(),
    )

    assert documents == []
    assert fetcher.calls == [url]


@pytest.mark.parametrize(
    "page",
    [
        "2 cans chickpeas. " * 20,
        "Drain the chickpeas and simmer until tender. " * 20,
        "2 cans chickpeas. Simmer.",
    ],
    ids=["no-method", "no-quantity", "thin"],
)
def test_search_rejects_non_recipe_pages(page: str) -> None:
    url = "https://justinesnacks.com/creamy-lemon-chickpeas"
    search = Search([candidate(url, "Creamy Lemon Chickpeas")])

    documents = SparseTextEnricher(
        search=search,
        fetcher=Fetcher({url: page}),
    ).enrich(context(), job_id=uuid4())

    assert documents == []


def test_exact_canonical_post_is_an_independently_validated_owner() -> None:
    url = "https://www.instagram.com/reel/recipe-reel/?utm_source=search"
    search = Search([candidate(url, "Creamy Lemon Chickpeas")])

    documents = SparseTextEnricher(
        search=search,
        fetcher=Fetcher({url: recipe_page()}),
    ).enrich(context(creator_name="CJ"), job_id=uuid4())

    assert [document.url for document in documents] == [url]


def test_openrouter_search_forces_text_tool_and_parses_url_citations() -> None:
    requests: list[dict] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(json.loads(request.content))
        query = requests[-1]["messages"][1]["content"]
        slug = "one" if "first query" in query else "two"
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": "Search complete.",
                            "annotations": [
                                {
                                    "type": "url_citation",
                                    "url_citation": {
                                        "url": f"https://creator.example/{slug}",
                                        "title": f"Recipe {slug}",
                                        "content": f"snippet {slug}",
                                        "start_index": 0,
                                        "end_index": 8,
                                    },
                                }
                            ],
                        }
                    }
                ]
            },
        )

    client = OpenRouterRecipeSearchClient(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        api_key="search-key",
        base_url="https://openrouter.test/api/v1",
        model_id="google/gemini-3.6-flash",
        maximum_queries=2,
        maximum_results=4,
    )

    results = client.search(["first query", "second query", "ignored"], job_id=uuid4())

    assert [result.url for result in results] == [
        "https://creator.example/one",
        "https://creator.example/two",
    ]
    assert [result.snippet for result in results] == ["snippet one", "snippet two"]
    assert len(requests) == 2
    for payload in requests:
        assert payload["tool_choice"] == "required"
        assert payload["tools"] == [
            {
                "type": "openrouter:web_search",
                "parameters": {
                    "engine": "exa",
                    "max_results": 4,
                    "max_total_results": 4,
                    "max_characters": 2000,
                },
            }
        ]
        assert "image" not in json.dumps(payload).casefold()
        assert "video" not in json.dumps(payload).casefold()


def test_openrouter_search_maps_provider_failure_without_leaking_key() -> None:
    client = OpenRouterRecipeSearchClient(
        http=httpx.Client(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(503, json={"error": "down"})
            )
        ),
        api_key="never-log-me",
        base_url="https://openrouter.test/api/v1",
        model_id="model",
    )

    with pytest.raises(ProviderTransientError) as error:
        client.search(["query"], job_id=uuid4())

    assert "never-log-me" not in str(error.value)
