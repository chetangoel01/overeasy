from collections.abc import Sequence
from dataclasses import dataclass

import httpx
import pytest

from ladle.acquisition.free import links
from ladle.acquisition.free.links import (
    SafeLinkFetcher,
    UnsafeURL,
    caption_links,
    dish_terms,
    substack_candidates,
)

SITEMAP = """<?xml version="1.0"?>
<urlset>
  <url><loc>https://mishkamakesfood.substack.com/p/creamy-lemon-chickpeas-w-basil-and</loc></url>
  <url><loc>https://mishkamakesfood.substack.com/p/sheet-pan-salmon</loc></url>
  <url><loc>https://mishkamakesfood.substack.com/about</loc></url>
</urlset>
"""


@dataclass
class FakeDNS:
    values: dict[str, Sequence[str]]

    def resolve(self, hostname: str) -> Sequence[str]:
        return self.values.get(hostname, ["93.184.216.34"])


def fetcher_returning(body: str, *, content_type: str = "text/html") -> SafeLinkFetcher:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.host == "93.184.216.34"
        return httpx.Response(200, text=body, headers={"content-type": content_type})

    return SafeLinkFetcher(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        dns=FakeDNS({}),
    )


class Recorder:
    def __init__(self, body: str) -> None:
        self.body = body
        self.urls: list[str] = []

    def fetch_raw(self, url: str) -> str:
        self.urls.append(url)
        return self.body

    def fetch_text(self, url: str) -> str:
        return self.fetch_raw(url)


def test_caption_links_keeps_creator_sites_and_drops_social() -> None:
    caption = (
        "Full recipe at https://mishkamakesfood.substack.com/p/chickpeas "
        "follow me on https://www.instagram.com/mishka and mysite.com/recipe"
    )

    assert caption_links(caption) == [
        "https://mishkamakesfood.substack.com/p/chickpeas",
        "https://mysite.com/recipe",
    ]


def test_caption_links_ignore_non_http_schemes() -> None:
    assert caption_links("mailto:chef@example.com and file:///etc/passwd") == []


def test_dish_terms_drop_promo_tail_and_hashtags() -> None:
    terms = dish_terms(
        "Feta and Spinach Rice Paper Rolls full written recipe link in bio #airfryer"
    )

    assert "feta" in terms
    assert "spinach" in terms
    assert "bio" not in terms
    assert "airfryer" not in terms


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1/admin",
        "http://localhost/admin",
        "http://169.254.169.254/latest/meta-data/",
        "http://10.0.0.5/internal",
        "http://192.168.1.1/router",
        "http://[::1]/admin",
    ],
)
def test_private_addresses_are_refused(url: str) -> None:
    fetcher = fetcher_returning("<html>secret</html>")

    with pytest.raises(UnsafeURL):
        fetcher.fetch_raw(url)


def test_non_http_scheme_is_refused() -> None:
    fetcher = fetcher_returning("<html>x</html>")

    with pytest.raises(UnsafeURL):
        fetcher.fetch_raw("file:///etc/passwd")


def test_redirect_into_private_space_is_refused() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.headers["host"] == "example.com":
            return httpx.Response(302, headers={"location": "http://169.254.169.254/"})
        return httpx.Response(
            200, text="metadata", headers={"content-type": "text/html"}
        )

    fetcher = SafeLinkFetcher(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        dns=FakeDNS({}),
    )

    with pytest.raises(UnsafeURL):
        fetcher.fetch_raw("https://example.com/recipe")


def test_redirect_loop_is_bounded() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(302, headers={"location": "https://example.com/next"})

    fetcher = SafeLinkFetcher(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        dns=FakeDNS({}),
        max_redirects=2,
    )

    with pytest.raises(UnsafeURL):
        fetcher.fetch_raw("https://example.com/start")


def test_caption_links_drop_urls_with_malformed_ports() -> None:
    caption = (
        "recipe at https://evil.example.com:abc/recipe "
        "backup https://good.example.com/recipe"
    )

    assert caption_links(caption) == ["https://good.example.com/recipe"]


def test_caption_links_keep_valid_explicit_ports() -> None:
    # A parseable port is not caption parsing's concern: the fetcher refuses
    # anything but 443 when the request is actually made.
    assert caption_links("see https://mysite.example.com:8443/recipe") == [
        "https://mysite.example.com:8443/recipe"
    ]


def test_malformed_port_is_refused_like_any_other_unsafe_target() -> None:
    fetcher = fetcher_returning("<html>x</html>")

    with pytest.raises(UnsafeURL):
        fetcher.fetch_text("https://evil.example.com:abc/recipe")


def test_scheme_less_url_is_refused() -> None:
    fetcher = fetcher_returning("<html>x</html>")

    with pytest.raises(UnsafeURL):
        fetcher.fetch_raw("evil.example.com/recipe")


def test_redirect_to_an_overlong_url_is_refused() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(
            302, headers={"location": "https://example.com/" + "a" * 70_000}
        )

    fetcher = SafeLinkFetcher(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        dns=FakeDNS({}),
    )

    with pytest.raises(UnsafeURL):
        fetcher.fetch_raw("https://example.com/recipe")


def test_host_that_resolves_to_nothing_is_refused() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request should be made for an unresolvable host")

    fetcher = SafeLinkFetcher(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        dns=FakeDNS({"ghost.example.com": []}),
    )

    with pytest.raises(UnsafeURL):
        fetcher.fetch_raw("https://ghost.example.com/recipe")


def test_fetch_text_strips_markup_and_scripts() -> None:
    fetcher = fetcher_returning(
        "<html><head><title>t</title></head><body>"
        "<script>alert('x')</script><p>Add 2 cups&nbsp;orzo</p></body></html>"
    )

    text = fetcher.fetch_text("https://example.com/recipe")

    assert "alert" not in text
    assert "Add 2 cups orzo" in text


def test_substack_candidates_match_creator_subdomain_by_slug() -> None:
    recorder = Recorder(SITEMAP)

    posts = substack_candidates(
        "mishkamakesfood", "Creamy Garlic-Lemon Chickpeas", fetcher=recorder
    )

    assert posts == [
        "https://mishkamakesfood.substack.com/p/creamy-lemon-chickpeas-w-basil-and"
    ]
    assert recorder.urls == ["https://mishkamakesfood.substack.com/sitemap.xml"]


def test_substack_candidates_return_only_the_best_match() -> None:
    near_miss = SITEMAP.replace(
        "<url><loc>https://mishkamakesfood.substack.com/p/sheet-pan-salmon</loc></url>",
        "<url><loc>https://mishkamakesfood.substack.com/p/creamy-calabrian-chickpeas"
        "</loc></url>",
    )
    recorder = Recorder(near_miss)

    posts = substack_candidates(
        "mishkamakesfood", "Creamy Garlic-Lemon Chickpeas", fetcher=recorder
    )

    # The calabrian post also overlaps on "creamy" and "chickpeas"; attaching it
    # would feed the extractor a different recipe by the same creator.
    assert posts == [
        "https://mishkamakesfood.substack.com/p/creamy-lemon-chickpeas-w-basil-and"
    ]


def test_substack_candidates_reject_weak_slug_overlap() -> None:
    recorder = Recorder(SITEMAP)

    assert (
        substack_candidates("mishkamakesfood", "Beef Wellington", fetcher=recorder)
        == []
    )


def test_substack_candidates_need_a_handle() -> None:
    recorder = Recorder(SITEMAP)

    assert substack_candidates("", "Creamy Lemon Chickpeas", fetcher=recorder) == []
    assert recorder.urls == []


@pytest.mark.parametrize(
    ("url", "creator", "expected"),
    [
        ("https://justinesnacks.com/gochujang", "justine_snacks", True),
        ("https://www.justinesnacks.com/x", "Justine Snacks", True),
        ("https://mishkamakesfood.substack.com/p/a", "mishkamakesfood", True),
        ("https://sponsor.example.com/deal", "justine_snacks", False),
        ("https://hellofresh.com/offer", "mishkamakesfood", False),
        # Too short to mean anything: a three-letter handle matches the web.
        ("https://abc.com/x", "abc", False),
        ("https://anything.com/x", None, False),
    ],
)
def test_creator_owned_links_are_told_from_sponsor_links(
    url: str, creator: str | None, expected: bool
) -> None:
    assert links.belongs_to_creator(url, creator) is expected
