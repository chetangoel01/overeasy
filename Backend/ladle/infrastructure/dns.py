import ipaddress
import socket
from collections.abc import Mapping, Sequence
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
        "vt.tiktok.com",
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

    addresses = _public_addresses(hostname, dns=dns)

    return ValidatedNetworkTarget(
        url=url,
        hostname=hostname,
        addresses=addresses,
    )


def validate_external_target(
    url: str,
    *,
    dns: DNSResolver,
) -> ValidatedNetworkTarget:
    """Validate an attacker- or provider-controlled outbound HTTPS target."""

    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError as error:
        raise UnsafeNetworkTarget("invalid URL") from error
    try:
        hostname = (
            parsed.hostname.encode("idna").decode("ascii").casefold()
            if parsed.hostname
            else None
        )
    except UnicodeError as error:
        raise UnsafeNetworkTarget("invalid hostname") from error
    if (
        parsed.scheme.casefold() != "https"
        or hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or port not in (None, 443)
    ):
        raise UnsafeNetworkTarget("only public HTTPS targets on port 443 are allowed")
    return ValidatedNetworkTarget(
        url=url,
        hostname=hostname,
        addresses=_public_addresses(hostname, dns=dns),
    )


def _public_addresses(hostname: str, *, dns: DNSResolver) -> tuple[str, ...]:
    try:
        literal = ipaddress.ip_address(hostname)
    except ValueError:
        addresses = tuple(dict.fromkeys(dns.resolve(hostname)))
    else:
        addresses = (str(literal),)
    if not addresses:
        raise UnsafeNetworkTarget("DNS returned no addresses")
    parsed_addresses: list[ipaddress.IPv4Address | ipaddress.IPv6Address] = []
    try:
        for value in addresses:
            address = ipaddress.ip_address(value)
            if isinstance(address, ipaddress.IPv6Address):
                address = address.ipv4_mapped or address
            parsed_addresses.append(address)
    except ValueError as error:
        raise UnsafeNetworkTarget("DNS returned an invalid address") from error
    if not all(
        address.is_global
        and not address.is_multicast
        and not address.is_reserved
        and not address.is_loopback
        and not address.is_link_local
        and not address.is_unspecified
        and not address.is_private
        for address in parsed_addresses
    ):
        raise UnsafeNetworkTarget("DNS returned a non-public address")
    return addresses


class PinnedHTTPClient:
    """Bounded GET client that connects only to the IPs it validated."""

    def __init__(
        self,
        *,
        dns: DNSResolver,
        client: httpx.Client,
        maximum_redirects: int = 3,
    ) -> None:
        self._dns = dns
        self._client = client
        self._maximum_redirects = maximum_redirects

    def get(
        self,
        url: str,
        *,
        params: Mapping[str, str] | None = None,
        headers: Mapping[str, str] | None = None,
        max_bytes: int,
    ) -> httpx.Response:
        if max_bytes <= 0:
            raise ValueError("max_bytes must be positive")
        current = str(
            httpx.URL(url) if params is None else httpx.URL(url, params=params)
        )
        current_headers = dict(headers or {})
        for redirect_count in range(self._maximum_redirects + 1):
            target = validate_external_target(current, dns=self._dns)
            response = self._request_pinned(
                target,
                headers=current_headers,
                max_bytes=max_bytes,
            )
            if not response.is_redirect:
                return response
            location = response.headers.get("location")
            if location is None or redirect_count == self._maximum_redirects:
                raise UnsafeNetworkTarget("invalid or excessive redirects")
            destination = urljoin(current, location)
            if urlsplit(destination).hostname != target.hostname:
                current_headers = {
                    name: value
                    for name, value in current_headers.items()
                    if name.casefold() not in {"authorization", "cookie"}
                }
            current = destination
        raise UnsafeNetworkTarget("excessive redirects")

    def _request_pinned(
        self,
        target: ValidatedNetworkTarget,
        *,
        headers: Mapping[str, str] | None,
        max_bytes: int,
    ) -> httpx.Response:
        last_error: httpx.HTTPError | None = None
        for address in target.addresses:
            pinned_url = httpx.URL(target.url).copy_with(host=address)
            request_headers = dict(headers or {})
            request_headers["host"] = target.hostname
            request = self._client.build_request(
                "GET",
                pinned_url,
                headers=request_headers,
                extensions={"sni_hostname": target.hostname.encode("ascii")},
            )
            response: httpx.Response | None = None
            try:
                response = self._client.send(
                    request,
                    follow_redirects=False,
                    stream=True,
                )
                content = bytearray()
                for chunk in response.iter_bytes():
                    content.extend(chunk)
                    if len(content) > max_bytes:
                        raise UnsafeNetworkTarget(
                            f"response exceeded {max_bytes} bytes"
                        )
                decoded_headers = httpx.Headers(
                    [
                        (name, value)
                        for name, value in response.headers.multi_items()
                        if name.casefold() not in {"content-encoding", "content-length"}
                    ]
                )
                return httpx.Response(
                    status_code=response.status_code,
                    headers=decoded_headers,
                    content=bytes(content),
                    request=request,
                    extensions=response.extensions,
                )
            except UnsafeNetworkTarget:
                raise
            except httpx.HTTPError as error:
                last_error = error
            finally:
                if response is not None:
                    response.close()
        raise UnsafeNetworkTarget(
            "could not connect to validated target"
        ) from last_error


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
