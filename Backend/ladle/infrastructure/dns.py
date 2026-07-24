import ipaddress
import socket
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol
from urllib.parse import urljoin, urlsplit

import httpx

ALLOWED_SOCIAL_HOSTS = frozenset(
    {
        "instagram.com",
        "m.tiktok.com",
        "m.youtube.com",
        "tiktok.com",
        "vm.tiktok.com",
        "www.instagram.com",
        "www.tiktok.com",
        "www.youtube.com",
        "youtu.be",
        "youtube.com",
    }
)


class UnsafeNetworkTarget(Exception):
    pass


class DNSResolver(Protocol):
    def resolve(self, hostname: str) -> Sequence[str]: ...


class SystemDNSResolver:
    def resolve(self, hostname: str) -> Sequence[str]:
        try:
            answers = socket.getaddrinfo(
                hostname,
                443,
                type=socket.SOCK_STREAM,
            )
        except socket.gaierror as error:
            raise UnsafeNetworkTarget("DNS resolution failed") from error
        return tuple(dict.fromkeys(str(answer[4][0]) for answer in answers))


@dataclass(frozen=True)
class ValidatedNetworkTarget:
    url: str
    hostname: str
    addresses: tuple[str, ...]


def validate_public_target(
    url: str,
    *,
    dns: DNSResolver,
) -> ValidatedNetworkTarget:
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError as error:
        raise UnsafeNetworkTarget("invalid URL") from error

    hostname = parsed.hostname.casefold() if parsed.hostname else None
    if (
        parsed.scheme.casefold() != "https"
        or hostname not in ALLOWED_SOCIAL_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or port not in (None, 443)
    ):
        raise UnsafeNetworkTarget("URL is outside the public social allowlist")

    addresses = tuple(dict.fromkeys(dns.resolve(hostname)))
    if not addresses:
        raise UnsafeNetworkTarget("DNS returned no addresses")
    try:
        parsed_addresses = tuple(ipaddress.ip_address(value) for value in addresses)
    except ValueError as error:
        raise UnsafeNetworkTarget("DNS returned an invalid address") from error
    if not all(
        address.is_global
        and not address.is_multicast
        and not address.is_reserved
        and not address.is_loopback
        and not address.is_link_local
        and not address.is_unspecified
        for address in parsed_addresses
    ):
        raise UnsafeNetworkTarget("DNS returned a non-public address")

    return ValidatedNetworkTarget(
        url=url,
        hostname=hostname,
        addresses=addresses,
    )


class PinnedRedirectResolver:
    def __init__(
        self,
        *,
        dns: DNSResolver,
        client: httpx.Client,
        maximum_redirects: int = 5,
    ) -> None:
        self._dns = dns
        self._client = client
        self._maximum_redirects = maximum_redirects

    def resolve(self, url: str) -> str:
        current = url
        for redirect_count in range(self._maximum_redirects + 1):
            target = validate_public_target(current, dns=self._dns)
            response = self._request_pinned(target)
            if response.is_redirect:
                location = response.headers.get("location")
                if location is None or redirect_count == self._maximum_redirects:
                    raise UnsafeNetworkTarget("invalid or excessive redirects")
                current = urljoin(current, location)
                continue
            return current
        raise UnsafeNetworkTarget("excessive redirects")

    def _request_pinned(
        self,
        target: ValidatedNetworkTarget,
    ) -> httpx.Response:
        last_error: httpx.HTTPError | None = None
        for address in target.addresses:
            pinned_url = httpx.URL(target.url).copy_with(host=address)
            request = self._client.build_request(
                "HEAD",
                pinned_url,
                headers={"host": target.hostname},
                extensions={"sni_hostname": target.hostname.encode("ascii")},
            )
            try:
                return self._client.send(request, follow_redirects=False)
            except httpx.HTTPError as error:
                last_error = error
        raise UnsafeNetworkTarget(
            "could not connect to validated target"
        ) from last_error
