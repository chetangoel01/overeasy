import random
import re
import time
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


def test_redirect_to_an_overlong_relative_location_is_refused() -> None:
    # httpx joins a relative Location itself inside send(), and the joined
    # URL can exceed its 65,535-character cap even though the location alone
    # does not — surfacing as a bare InvalidURL, which is not an HTTPError.
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(302, headers={"location": "a" * 65_530})

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


def test_unclosed_scriptish_soup_is_processed_in_linear_time() -> None:
    # 100 KB of opening tags that never close. The lazy backreference regex
    # backtracked quadratically over this — about seven seconds here and the
    # better part of an hour at the 2 MB response cap, all inside a single
    # uninterruptible re.sub call on the worker's only thread.
    fetcher = fetcher_returning("<svg>" * 20_000)

    started = time.perf_counter()
    text = fetcher.fetch_text("https://example.com/recipe")
    assert time.perf_counter() - started < 1.0
    assert text == ""


def test_unclosed_angle_bracket_soup_is_processed_in_linear_time() -> None:
    # The tag stripper had the same quadratic shape: with no ">" anywhere,
    # "<[^>]+>" re-scanned to end-of-string from every "<".
    fetcher = fetcher_returning("<a" * 75_000)

    started = time.perf_counter()
    fetcher.fetch_text("https://example.com/recipe")
    assert time.perf_counter() - started < 1.0


def test_scriptish_opens_missing_their_bracket_grow_linearly() -> None:
    # "<svg" repeated, with no ">" anywhere in the body. Every candidate open
    # makes the greedy [^>]*> consume to end-of-string and fail — once per
    # candidate, quadratic — all inside a single .search() C call that
    # returns None, so a linearly-advancing Python loop around it never even
    # iterates. Measured on the regex loop: 0.87 s at 100 KB, 3.48 s at
    # 200 KB, 13.78 s at 400 KB — 4x per doubling, ~6 minutes at the 2 MB
    # response cap.
    def best_of_three(characters: int) -> float:
        fetcher = fetcher_returning("<svg" * (characters // 4))
        best = float("inf")
        for _ in range(3):
            started = time.perf_counter()
            fetcher.fetch_text("https://example.com/recipe")
            elapsed = time.perf_counter() - started
            assert elapsed < 1.0, f"{characters:,} chars took {elapsed:.2f}s"
            best = min(best, elapsed)
        return best

    smallest = best_of_three(100_000)
    best_of_three(200_000)
    largest = best_of_three(400_000)

    # Linear growth at most quadruples the time over a quadrupled input; the
    # quadratic regex sixteenfolded it. The floor keeps timer noise on a
    # sub-10ms smallest from deciding the ratio.
    assert largest < 8 * max(smallest, 0.01), f"{smallest=:.4f}s {largest=:.4f}s"


@pytest.mark.parametrize(
    "name", ["script", "style", "noscript", "svg", "iframe", "head"]
)
def test_every_scriptish_name_unclosed_and_bracketless_is_linear(name: str) -> None:
    # Each of the six names as an opening-tag prefix with no ">" to finish
    # it. With no ">" there is no tag to strip, so the body must also pass
    # through untouched, exactly as the original regexes left it.
    unit = f"<{name}"
    soup = unit * (200_000 // len(unit))
    fetcher = fetcher_returning(soup)

    started = time.perf_counter()
    text = fetcher.fetch_text("https://example.com/recipe")
    elapsed = time.perf_counter() - started

    assert elapsed < 1.0, f"{unit} soup took {elapsed:.2f}s"
    assert text == soup[: links._MAX_DOCUMENT_CHARACTERS]


def test_closed_blocks_followed_by_bracketless_soup_stay_linear() -> None:
    # Closed scriptish blocks are stripped as before, and the bracketless
    # soup after them cannot send the scan quadratic mid-document.
    body = "<script>secret()</script>Keep this. " * 200 + "<svg" * 40_000
    fetcher = fetcher_returning(body)

    started = time.perf_counter()
    text = fetcher.fetch_text("https://example.com/recipe")
    elapsed = time.perf_counter() - started

    assert elapsed < 1.0, f"mixed body took {elapsed:.2f}s"
    assert "secret" not in text
    assert "Keep this." in text
    assert "<svg<svg" in text


def test_one_giant_unclosed_tag_prefix_passes_through() -> None:
    # A single candidate open and never a ">": nothing is a tag, so the body
    # passes through whole, up to the document cap.
    body = "<svg" + "x" * 100_000
    fetcher = fetcher_returning(body)

    started = time.perf_counter()
    text = fetcher.fetch_text("https://example.com/recipe")

    assert time.perf_counter() - started < 1.0
    assert text == body[: links._MAX_DOCUMENT_CHARACTERS]


def test_scriptish_soup_at_the_full_response_cap_is_processed_quickly() -> None:
    # The exact attack body: 2,000,000 bytes — the response cap, the most a
    # fetch can hand _readable — of "<svg" prefixes. On the quadratic regex
    # this size extrapolates to ~6 minutes of uninterruptible CPU.
    body = "<svg" * (links._MAX_RESPONSE_BYTES // 4)
    fetcher = fetcher_returning(body)

    started = time.perf_counter()
    text = fetcher.fetch_text("https://example.com/recipe")

    assert time.perf_counter() - started < 1.5
    assert text == body[: links._MAX_DOCUMENT_CHARACTERS]


def test_scanner_matches_the_original_regex_on_3000_randomized_soups() -> None:
    # The oracle is the pre-356aa66 implementation itself -- the lazy
    # backreference regex both reworks replaced, byte-for-byte from
    # `git show 356aa66^:Backend/ladle/acquisition/free/links.py` -- NOT a
    # copy of either reworked loop. The previous oracle was such a copy: it
    # performed the same close-table lookup and raised the same KeyError on
    # U+0131/U+0130 tag names, so on exactly the inputs that crashed, the
    # comparison never ran. An oracle that shares a bug cannot detect it.
    # Inputs stay small here, so the oracle's quadratic worst case stays
    # microseconds -- never lift it out of this test.
    original = re.compile(
        r"(?is)<(script|style|noscript|svg|iframe|head)[^>]*>.*?</\1>",
    )

    # One deliberate, documented divergence: HTML tag names are
    # ASCII-case-insensitive, and the scanner now matches them ASCII-only,
    # while the original's Unicode (?i) folded U+0130/U+0131/U+017F into
    # ASCII "i"/"s" -- and only half-way, because literals and backreferences
    # fold through different tables: <scr{U+0130}pt>x</script> was stripped,
    # <{U+0131}frame>x</iframe> was not. The scanner now treats all three
    # codepoints as ordinary text, the way a browser does. The oracle sees
    # them masked as private-use characters -- inert bytes, exactly how the
    # ASCII scanner treats them -- and the mask is inverted on the way out.
    # The mask is an input transform only: on soups without the three
    # codepoints it is the identity and the comparison is against the
    # original verbatim. A reintroduced Unicode fold strips what the masked
    # oracle keeps, and a reintroduced KeyError raises out of the left-hand
    # side; either fails this test.
    mask = str.maketrans({0x130: "\ue000", 0x131: "\ue001", 0x17F: "\ue002"})
    unmask = str.maketrans({0xE000: "\u0130", 0xE001: "\u0131", 0xE002: "\u017f"})

    tokens = [
        "<svg",
        "<svg>",
        "</svg>",
        "<script",
        "<script>",
        "</script>",
        "<SCRIPT type=module>",
        "</SCRIPT>",
        # U+017F LONG S folds to "s" under Unicode (?i) and also casefolds
        # to "s". U+0131 DOTLESS I and U+0130 DOTTED CAPITAL I fold to "i"
        # but casefold AWAY from it -- the only two codepoints in Unicode
        # that do, and the KeyError of the second rework.
        "<\u017fcript>",
        "</\u017fcript>",
        "<\u0131frame>",
        "</\u0131frame>",
        "<\u0130frame>",
        "</\u0130frame>",
        "<scr\u0131pt>",
        "</scr\u0131pt>",
        "<scr\u0130pt>",
        "<noscr\u0130pt>",
        "<style>",
        "</style",
        "<noscript>",
        "</noscript>",
        "<iframe src=x>",
        "<head>",
        "</head>",
        "<header>",  # matches as "head" plus attribute junk, as it always did
        "<svgx>",
        "<p>",
        "</p>",
        "<a href=x>",
        "<",
        ">",
        "</",
        "<>",
        "text",
        " ",
        "recipe &amp; notes",
        "x",
    ]
    rng = random.Random(0)
    for _ in range(3_000):
        soup = "".join(rng.choice(tokens) for _ in range(rng.randrange(0, 40)))
        expected = original.sub(" ", soup.translate(mask)).translate(unmask)
        assert links._without_scriptish(soup) == expected


@pytest.mark.parametrize("name", ["script", "noscript", "iframe"])
@pytest.mark.parametrize("dot", ["\u0131", "\u0130"], ids=["dotless-i", "dotted-I"])
def test_turkish_i_tag_names_cannot_crash_the_fetch(name: str, dot: str) -> None:
    # U+0131 and U+0130 match ASCII "i" under Python's Unicode (?i) but
    # casefold away from it (U+0131 to itself, U+0130 to "i" plus a
    # combining dot), so the opener matched while the casefolded name
    # missed every close-table key: _without_scriptish raised KeyError, and
    # _fetch_all catches only (UnsafeURL, OSError, httpx.HTTPError), so one
    # hostile page killed the whole import. HTML tag names are
    # ASCII-case-insensitive, so these are not scriptish tags at all: a
    # browser renders their content, and now so does the scanner.
    tag = name.replace("i", dot, 1)
    fetcher = fetcher_returning(f"<p>Add 2 cups orzo</p><{tag}>between</{tag}>")

    text = fetcher.fetch_text("https://example.com/recipe")

    assert "Add 2 cups orzo" in text
    assert "between" in text


def test_long_s_script_is_ordinary_text_not_a_script_block() -> None:
    # U+017F LONG S folds to "s" under Unicode (?i) and casefolds to "s",
    # so it never crashed -- but a browser does not treat <(U+017F)cript>
    # as a script tag either (HTML tag names are ASCII-case-insensitive):
    # it renders the content. The ASCII-only matcher now agrees with the
    # browser instead of hiding text a reader would see.
    fetcher = fetcher_returning("<p>Stir well.</p><\u017fcript>shown()</\u017fcript>")

    text = fetcher.fetch_text("https://example.com/recipe")

    assert "Stir well." in text
    assert "shown()" in text


def test_scriptish_open_inside_anothers_junk_is_still_stripped() -> None:
    # "<svg" never completes here -- its ">" belongs to the <script> tag --
    # but the original regex retried at every index, found the <script>
    # block starting inside the junk, and stripped it. The reworked loops
    # resumed after the ">" and let the script body leak into readable
    # text. The scan now steps past an incomplete candidate by one name,
    # exactly like the regex engine.
    fetcher = fetcher_returning("<svg<script>evil()</script><p>Whisk.</p>")

    text = fetcher.fetch_text("https://example.com/recipe")

    assert "evil" not in text
    assert "Whisk." in text


def test_a_matched_name_missing_its_close_entry_degrades_not_raises(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Belt and braces for the invariant the crash violated: nothing the
    # opener matches may ever miss the close table. If the two drift again,
    # the tag is left for _without_tags like any unclosed tag -- degrade
    # the document, never kill the import.
    monkeypatch.setattr(links, "_SCRIPTISH_NAME", re.compile(r"(?ai)<(video|script)"))

    stripped = links._without_scriptish("<video>v()</video><script>s()</script>")

    assert stripped == "<video>v()</video> "


def test_many_candidates_sharing_one_distant_bracket_stay_linear() -> None:
    # All six names open back to back and share the single ">" that ends
    # the block, so the scan revisits candidates inside earlier candidates'
    # junk. The shared ">" must be found once per block, not once per
    # candidate, and each name's failed close search must run once in
    # total.
    block = "<svg<iframe<script<style<noscript<head>"
    soup = block * (200_000 // len(block))
    fetcher = fetcher_returning(soup)

    started = time.perf_counter()
    text = fetcher.fetch_text("https://example.com/recipe")
    elapsed = time.perf_counter() - started

    assert elapsed < 1.0, f"shared-bracket soup took {elapsed:.2f}s"
    assert text == ""


def test_readable_keeps_text_after_an_unclosed_script() -> None:
    fetcher = fetcher_returning("<p>Add 2 cups orzo</p><script>var x = 1")

    assert "Add 2 cups orzo" in fetcher.fetch_text("https://example.com/recipe")


def test_readable_strips_scriptish_blocks_case_insensitively() -> None:
    fetcher = fetcher_returning(
        "<p>Stir well.</p><SCRIPT type=module>secret()</SCRIPT><p>Serve.</p>"
        "<style>p{color:red}</style><svg><path d='M0 0'/></svg>Done"
    )

    text = fetcher.fetch_text("https://example.com/recipe")

    assert "Stir well." in text
    assert "Serve." in text
    assert "Done" in text
    assert "secret" not in text
    assert "color" not in text
    assert "M0 0" not in text


def test_readable_resumes_scanning_after_a_closed_block() -> None:
    fetcher = fetcher_returning("<style>a<svg>b</style>keep<p>me</p></svg>")

    assert fetcher.fetch_text("https://example.com/recipe") == "keep me"


def test_fetch_text_of_an_empty_body_is_empty() -> None:
    assert fetcher_returning("").fetch_text("https://example.com/recipe") == ""


def test_response_at_the_byte_cap_is_kept_and_one_over_is_refused() -> None:
    def serving(body: str) -> SafeLinkFetcher:
        def handler(request: httpx.Request) -> httpx.Response:
            del request
            return httpx.Response(200, text=body, headers={"content-type": "text/html"})

        return SafeLinkFetcher(
            http=httpx.Client(transport=httpx.MockTransport(handler)),
            dns=FakeDNS({}),
            max_response_bytes=10,
        )

    assert serving("x" * 10).fetch_text("https://example.com/r") == "x" * 10

    with pytest.raises(UnsafeURL):
        serving("x" * 11).fetch_text("https://example.com/r")


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
