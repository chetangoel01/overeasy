from collections.abc import Sequence
from dataclasses import dataclass

import httpx
import pytest

from ladle.infrastructure.dns import (
    PinnedRedirectResolver,
    UnsafeNetworkTarget,
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
