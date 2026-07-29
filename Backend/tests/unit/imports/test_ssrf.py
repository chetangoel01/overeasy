from collections.abc import Sequence
from dataclasses import dataclass

import httpx
import pytest

from ladle.infrastructure.dns import (
    PinnedHTTPClient,
    PinnedRedirectResolver,
    UnsafeNetworkTarget,
    validate_external_target,
    validate_public_target,
)


@dataclass
class FakeDNS:
    values: dict[str, Sequence[str]]

    def resolve(self, hostname: str) -> Sequence[str]:
        return self.values[hostname]


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",
        "10.0.0.1",
        "169.254.169.254",
        "172.16.0.1",
        "192.168.1.1",
        "0.0.0.0",
        "224.0.0.1",
        "::1",
        "fc00::1",
        "fe80::1",
        "::ffff:127.0.0.1",
        "::ffff:169.254.169.254",
    ],
)
def test_private_reserved_and_metadata_addresses_are_rejected(address: str) -> None:
    dns = FakeDNS({"www.youtube.com": [address]})

    with pytest.raises(UnsafeNetworkTarget):
        validate_public_target("https://www.youtube.com/watch?v=abc", dns=dns)


def test_mixed_public_and_private_dns_answer_is_rejected() -> None:
    dns = FakeDNS({"www.youtube.com": ["93.184.216.34", "127.0.0.1"]})

    with pytest.raises(UnsafeNetworkTarget):
        validate_public_target("https://www.youtube.com/watch?v=abc", dns=dns)


@pytest.mark.parametrize(
    "url",
    [
        "http://93.184.216.34/recipe",
        "https://93.184.216.34:8443/recipe",
        "file:///etc/passwd",
        "https://127.0.0.1/admin",
        "https://169.254.169.254/latest/meta-data/",
        "https://[::ffff:127.0.0.1]/admin",
        "https://[64:ff9b::a9fe:a9fe]/latest/meta-data/",
        "https://[64:ff9b:1::a9fe:a9fe]/latest/meta-data/",
    ],
)
def test_external_fetch_restricts_scheme_port_and_cloud_targets(url: str) -> None:
    with pytest.raises(UnsafeNetworkTarget):
        validate_external_target(url, dns=FakeDNS({}))


def test_external_fetch_pins_the_validated_address_against_dns_rebinding() -> None:
    requests: list[httpx.Request] = []
    dns = FakeDNS({"assets.example": ["93.184.216.34"]})

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        dns.values["assets.example"] = ["169.254.169.254"]
        return httpx.Response(200, text="safe")

    client = PinnedHTTPClient(
        dns=dns,
        client=httpx.Client(transport=httpx.MockTransport(respond)),
    )

    response = client.get("https://assets.example/recipe", max_bytes=1024)

    assert response.text == "safe"
    assert requests[0].url.host == "93.184.216.34"
    assert requests[0].headers["host"] == "assets.example"
    assert requests[0].extensions["sni_hostname"] == b"assets.example"


def test_external_fetch_revalidates_redirects_and_rejects_mixed_dns() -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(
            302,
            headers={"location": "https://cdn.example/asset"},
        )

    client = PinnedHTTPClient(
        dns=FakeDNS(
            {
                "creator.example": ["93.184.216.34"],
                "cdn.example": ["93.184.216.35", "10.0.0.9"],
            }
        ),
        client=httpx.Client(transport=httpx.MockTransport(respond)),
    )

    with pytest.raises(UnsafeNetworkTarget):
        client.get("https://creator.example/recipe", max_bytes=1024)

    assert len(requests) == 1


def test_external_fetch_drops_credentials_on_cross_host_redirect() -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.headers["host"] == "media.example":
            return httpx.Response(
                302,
                headers={"location": "https://cdn.example/asset"},
            )
        return httpx.Response(200, content=b"media")

    client = PinnedHTTPClient(
        dns=FakeDNS(
            {
                "media.example": ["93.184.216.34"],
                "cdn.example": ["93.184.216.35"],
            }
        ),
        client=httpx.Client(transport=httpx.MockTransport(respond)),
    )

    client.get(
        "https://media.example/video",
        headers={
            "Authorization": "Bearer short-lived",
            "Cookie": "tt_chain_token=public",
        },
        max_bytes=1024,
    )

    assert requests[0].headers["authorization"] == "Bearer short-lived"
    assert requests[0].headers["cookie"] == "tt_chain_token=public"
    assert "authorization" not in requests[1].headers
    assert "cookie" not in requests[1].headers


def test_external_fetch_rejects_response_over_its_byte_limit() -> None:
    client = PinnedHTTPClient(
        dns=FakeDNS({"assets.example": ["93.184.216.34"]}),
        client=httpx.Client(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(200, content=b"x" * 1_025)
            )
        ),
    )

    with pytest.raises(UnsafeNetworkTarget, match="exceeded"):
        client.get("https://assets.example/large", max_bytes=1_024)


def test_redirect_resolver_pins_ip_and_revalidates_every_hop() -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.headers["host"] == "vm.tiktok.com":
            return httpx.Response(
                302,
                headers={
                    "location": (
                        "https://www.tiktok.com/@chef/video/"
                        "7481234567890123456?tracking=1"
                    )
                },
            )
        return httpx.Response(200)

    dns = FakeDNS(
        {
            "vm.tiktok.com": ["93.184.216.34"],
            "www.tiktok.com": ["93.184.216.35"],
        }
    )
    resolver = PinnedRedirectResolver(
        dns=dns,
        client=httpx.Client(transport=httpx.MockTransport(respond)),
        maximum_redirects=3,
    )

    resolved = resolver.resolve("https://vm.tiktok.com/ZMshort/")

    assert resolved == (
        "https://www.tiktok.com/@chef/video/7481234567890123456?tracking=1"
    )
    assert [request.url.host for request in requests] == [
        "93.184.216.34",
        "93.184.216.35",
    ]
    assert [request.headers["host"] for request in requests] == [
        "vm.tiktok.com",
        "www.tiktok.com",
    ]
    assert requests[0].extensions["sni_hostname"] == b"vm.tiktok.com"


def test_redirect_to_non_allowlisted_host_is_rejected_before_request() -> None:
    calls = 0

    def respond(_: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(
            302,
            headers={"location": "https://attacker.example/steal"},
        )

    resolver = PinnedRedirectResolver(
        dns=FakeDNS({"vm.tiktok.com": ["93.184.216.34"]}),
        client=httpx.Client(transport=httpx.MockTransport(respond)),
    )

    with pytest.raises(UnsafeNetworkTarget):
        resolver.resolve("https://vm.tiktok.com/ZMshort/")

    assert calls == 1
