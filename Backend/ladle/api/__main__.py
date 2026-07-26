"""Run the API using the hosting platform's PORT contract."""

import os
from collections.abc import Mapping

import uvicorn


def port_from_environment(environment: Mapping[str, str]) -> int:
    raw = environment.get("PORT", "4111")
    try:
        port = int(raw)
    except ValueError as error:
        raise ValueError("PORT must be an integer from 1 through 65535") from error
    if not 1 <= port <= 65_535:
        raise ValueError("PORT must be an integer from 1 through 65535")
    return port


def main() -> None:
    uvicorn.run(
        "ladle.api.app:app",
        host="0.0.0.0",
        port=port_from_environment(os.environ),
        proxy_headers=True,
    )


if __name__ == "__main__":
    main()
