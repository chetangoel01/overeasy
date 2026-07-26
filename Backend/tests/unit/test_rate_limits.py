from datetime import timedelta

from fastapi import Request

from ladle.api.rate_limits import ClientIPResolver, RateLimitPolicies
from ladle.config import Settings


def request(
    *,
    peer: str,
    forwarded_for: str | None = None,
) -> Request:
    headers: list[tuple[bytes, bytes]] = []
    if forwarded_for is not None:
        headers.append((b"x-forwarded-for", forwarded_for.encode()))
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "headers": headers,
            "client": (peer, 1234),
        }
    )


def test_client_ip_uses_forwarded_chain_only_from_a_trusted_proxy() -> None:
    resolver = ClientIPResolver("10.0.0.0/8, 2001:db8:abcd::/48")

    assert (
        resolver.resolve(
            request(peer="198.51.100.10", forwarded_for="203.0.113.7")
        )
        == "198.51.100.10"
    )
    assert (
        resolver.resolve(
            request(
                peer="10.0.0.5",
                forwarded_for="203.0.113.7, 10.0.0.4",
            )
        )
        == "203.0.113.7"
    )


def test_requested_endpoint_policies_cover_every_abuse_dimension() -> None:
    policies = RateLimitPolicies.from_settings(Settings())

    assert {check.bucket for check in policies.guest("ip", "installation")} == {
        "guest:ip",
        "guest:installation",
    }
    assert {check.bucket for check in policies.refresh("ip", "installation")} == {
        "refresh:ip",
        "refresh:installation",
    }
    assert {check.bucket for check in policies.apple("ip", "user")} == {
        "apple:ip",
        "apple:user",
    }
    assert {
        check.bucket
        for check in policies.import_request("submit", "ip", "installation", "user")
    } == {
        "import-submit:ip",
        "import-submit:installation",
        "import-submit:user",
    }
    assert {
        check.bucket
        for check in policies.import_request("retry", "ip", "installation", "user")
    } == {
        "import-retry:ip",
        "import-retry:installation",
        "import-retry:user",
    }
    assert policies.recipe_mutation("user")[0].period == timedelta(minutes=1)
    assert policies.sync_poll("user")[0].bucket == "sync:user"
    assert policies.global_request()[0].bucket == "global"
