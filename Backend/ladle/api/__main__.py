"""Run the API using the hosting platform's PORT contract."""

import logging
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
    # Root gets a handler before the application is imported so the request log
    # is visible in development. Production replaces it with the JSON formatter
    # inside create_app, which runs after this.
    logging.basicConfig(format="%(levelname)s: %(name)s %(message)s", level="INFO")
    uvicorn.run(
        "ladle.api.app:app",
        host="0.0.0.0",
        port=port_from_environment(os.environ),
        proxy_headers=True,
        # Uvicorn's access line carries the raw request target, which for the
        # one-time /ops handoff contains the dashboard token. That line is not
        # JSON either, so dropping it also makes the production log stream
        # uniform. The request middleware already logs method, route template,
        # status, duration, and request ID — without the query string.
        access_log=False,
    )


if __name__ == "__main__":
    main()
